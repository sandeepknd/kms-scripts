#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# test-defrag-ab-direct.sh
#
# Modified version using DIRECT etcdctl put instead of ConfigMap creates
# for more precise etcd write blocking measurement
#
# Usage:
#   ./test-defrag-ab-direct.sh --label baseline
#   ./test-defrag-ab-direct.sh --label with-pr
#   ./test-defrag-ab-direct.sh --compare <baseline.json> <with-pr.json>
# =============================================================================

ETCD_NS="openshift-etcd"

LABEL=""
PROBE_INTERVAL="0.05"
WRITE_INTERVAL="0.1"
THRESHOLD_MS=500
COMPARE_MODE=false
COMPARE_FILE_A=""
COMPARE_FILE_B=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${BOLD}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }

CLEANUP_PIDS=()
CLEANUP_FILES=()

cleanup() {
    log "Cleaning up..."
    for pid in "${CLEANUP_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    for f in "${CLEANUP_FILES[@]}"; do
        rm -f "$f" 2>/dev/null || true
    done
}

usage() {
    cat <<'EOF'
Usage:
  test-defrag-ab-direct.sh --label <name> [options]
  test-defrag-ab-direct.sh --compare <file_a.json> <file_b.json>

Run mode options:
  --label <name>          Tag for this run (e.g. "baseline", "with-pr")
  --probe-interval <sec>  Seconds between gRPC probes (default: 0.05)
  --write-interval <sec>  Seconds between direct etcd writes (default: 0.1)
  --threshold <ms>        Latency threshold for "degraded" (default: 500)

Compare mode:
  --compare <a> <b>       Compare two result JSON files side-by-side

Examples:
  ./test-defrag-ab-direct.sh --label baseline
  ./test-defrag-ab-direct.sh --label with-pr --threshold 300
  ./test-defrag-ab-direct.sh --compare /tmp/defrag-test-baseline-*.json /tmp/defrag-test-with-pr-*.json
EOF
    exit 0
}

# ─── Argument parsing ────────────────────────────────────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --label)
                LABEL="$2"; shift 2 ;;
            --probe-interval)
                PROBE_INTERVAL="$2"; shift 2 ;;
            --write-interval)
                WRITE_INTERVAL="$2"; shift 2 ;;
            --threshold)
                THRESHOLD_MS="$2"; shift 2 ;;
            --compare)
                COMPARE_MODE=true
                COMPARE_FILE_A="$2"
                COMPARE_FILE_B="$3"
                shift 3 ;;
            --help|-h)
                usage ;;
            *)
                fail "Unknown flag: $1"; usage ;;
        esac
    done

    if $COMPARE_MODE; then
        if [[ -z "$COMPARE_FILE_A" || -z "$COMPARE_FILE_B" ]]; then
            fail "--compare requires two file arguments"; exit 1
        fi
        if [[ ! -f "$COMPARE_FILE_A" ]]; then
            fail "File not found: $COMPARE_FILE_A"; exit 1
        fi
        if [[ ! -f "$COMPARE_FILE_B" ]]; then
            fail "File not found: $COMPARE_FILE_B"; exit 1
        fi
    else
        if [[ -z "$LABEL" ]]; then
            fail "--label is required in run mode"; echo; usage
        fi
    fi
}

# ─── Helpers ─────────────────────────────────────────────────────────────────

get_etcd_pods() {
    oc get pods -n "$ETCD_NS" -l app=etcd -o jsonpath='{.items[*].metadata.name}'
}

get_pod_ip() {
    local pod=$1
    oc get pod -n "$ETCD_NS" "$pod" -o jsonpath='{.status.podIP}'
}

get_cluster_status() {
    local pod=$1
    oc exec -n "$ETCD_NS" "$pod" -c etcdctl -- \
        etcdctl endpoint status -w json --cluster 2>/dev/null
}

get_leader_ip() {
    local cluster_status=$1
    echo "$cluster_status" | jq -r '
        (.[0].Status.leader) as $lid |
        .[] | select(.Status.header.member_id == $lid) |
        .Endpoint' | sed 's|https://\([^:]*\):.*|\1|'
}

get_db_size() {
    local pod=$1
    local pod_ip
    pod_ip=$(get_pod_ip "$pod")
    oc exec -n "$ETCD_NS" "$pod" -c etcdctl -- \
        env -u ETCDCTL_ENDPOINTS etcdctl endpoint status -w json \
        --endpoints="https://${pod_ip}:2379" 2>/dev/null \
        | jq -r '.[0].Status.dbSize'
}

human_bytes() {
    local bytes=$1
    if (( bytes >= 1073741824 )); then
        echo "$(echo "scale=2; $bytes/1073741824" | bc) GiB"
    elif (( bytes >= 1048576 )); then
        echo "$(echo "scale=2; $bytes/1048576" | bc) MiB"
    else
        echo "${bytes} B"
    fi
}

millis_now() {
    perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'
}

# ─── Prerequisites ───────────────────────────────────────────────────────────

check_prereqs() {
    log "Checking prerequisites..."

    for cmd in oc jq bc perl; do
        if ! command -v "$cmd" &>/dev/null; then
            fail "$cmd not found in PATH"; exit 1
        fi
    done

    if ! oc whoami &>/dev/null; then
        fail "Not logged into an OCP cluster. Run 'oc login' first."; exit 1
    fi
    ok "Logged into cluster: $(oc whoami --show-server)"
}

# ─── Phase 1: Capture metadata ──────────────────────────────────────────────

capture_metadata() {
    log "Capturing cluster metadata..."

    CLUSTER_URL=$(oc whoami --show-server)
    CLUSTER_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")

    read -ra ALL_PODS <<< "$(get_etcd_pods)"
    if [[ ${#ALL_PODS[@]} -eq 0 ]]; then
        fail "No etcd pods found"; exit 1
    fi
    ok "Found ${#ALL_PODS[@]} etcd pods: ${ALL_PODS[*]}"

    ETCD_IMAGE=$(oc get pod -n "$ETCD_NS" "${ALL_PODS[0]}" \
        -o jsonpath='{.spec.containers[?(@.name=="etcd")].image}' 2>/dev/null || echo "unknown")
    ok "etcd image: $ETCD_IMAGE"

    local cluster_status
    cluster_status=$(get_cluster_status "${ALL_PODS[0]}")
    local leader_ip
    leader_ip=$(get_leader_ip "$cluster_status")
    log "Leader IP: $leader_ip"

    LEADER_POD=""
    NON_LEADER_PODS=()
    declare -gA POD_IPS
    declare -gA MEMBER_ROLES

    for pod in "${ALL_PODS[@]}"; do
        local pod_ip
        pod_ip=$(get_pod_ip "$pod")
        POD_IPS[$pod]=$pod_ip
        if [[ "$pod_ip" == "$leader_ip" ]]; then
            LEADER_POD=$pod
            MEMBER_ROLES[$pod]="leader"
        else
            NON_LEADER_PODS+=("$pod")
            MEMBER_ROLES[$pod]="follower"
        fi
    done

    ok "Leader: $LEADER_POD"
    ok "Followers: ${NON_LEADER_PODS[*]}"

    for pod in "${ALL_PODS[@]}"; do
        local size
        size=$(get_db_size "$pod")
        log "  $pod DB size: $(human_bytes "$size")"
    done
}

# ─── Phase 2: Defrag with probes ────────────────────────────────────────────

start_grpc_probe() {
    local pod=$1
    local probe_log=$2
    local interval=$3
    local pod_ip=$4

    oc exec -n "$ETCD_NS" "$pod" -c etcdctl -- env -u ETCDCTL_ENDPOINTS bash -c "
while true; do
    start_ns=\$(date +%s%N)
    if etcdctl get /defrag-probe --consistency=s \
        --endpoints=https://${pod_ip}:2379 \
        --command-timeout=10s >/dev/null 2>&1; then
        status=ok
    else
        status=fail
    fi
    end_ns=\$(date +%s%N)
    echo \"\$(( start_ns / 1000000 )) \$(( end_ns / 1000000 )) \$status \$(( (end_ns - start_ns) / 1000000 ))\"
    sleep $interval
done
" > "$probe_log" 2>/dev/null &
    echo $!
}

# MODIFIED: Direct etcdctl put with round-robin across all pods
background_writer() {
    local all_pods_str=$1  # Space-separated list of all pod names
    local results_file=$2
    local interval=$3
    local i=0

    # Convert space-separated string to array
    read -ra pods_array <<< "$all_pods_str"
    local num_pods=${#pods_array[@]}

    while true; do
        local start_ms end_ms duration_ms
        start_ms=$(millis_now)

        # Round-robin across all etcd pods to distribute load
        local target_pod="${pods_array[$((i % num_pods))]}"

        # Direct etcdctl put with 5s timeout (aggressive to show failures clearly)
        # Use timeout command to enforce at shell level too
        if timeout 7s oc exec -n "$ETCD_NS" "$target_pod" -c etcd -- \
            etcdctl put "/test/defrag-write-${i}" "value-${i}-$(date +%s%N)" \
            --command-timeout=5s \
            >/dev/null 2>&1; then
            end_ms=$(millis_now)
            duration_ms=$((end_ms - start_ms))
            echo "${start_ms} ${end_ms} ok ${duration_ms} ${target_pod}" >> "$results_file"
        else
            end_ms=$(millis_now)
            duration_ms=$((end_ms - start_ms))
            echo "${start_ms} ${end_ms} fail ${duration_ms} ${target_pod}" >> "$results_file"
        fi

        i=$((i + 1))
        sleep "$interval"
    done
}

defrag_with_probes() {
    log "Phase 2: Defrag with gRPC probes and direct etcd writes..."

    local write_log
    write_log=$(mktemp /tmp/defrag-writes.XXXXXX)
    CLEANUP_FILES+=("$write_log")

    # Round-robin writes across ALL pods to avoid bias when any single pod is defragged
    # This ensures writes continue hitting healthy members during each member's defrag
    local all_pods_str="${ALL_PODS[*]}"
    background_writer "$all_pods_str" "$write_log" "$WRITE_INTERVAL" &
    local writer_pid=$!
    CLEANUP_PIDS+=("$writer_pid")
    log "Background etcd writer started (PID=$writer_pid, interval=${WRITE_INTERVAL}s, round-robin across ${#ALL_PODS[@]} pods)"

    # Defrag order: non-leaders first, leader last
    ORDERED_PODS=("${NON_LEADER_PODS[@]}" "$LEADER_POD")

    declare -gA DEFRAG_DURATION
    declare -gA DB_SIZE_BEFORE
    declare -gA DB_SIZE_AFTER
    declare -gA PROBE_LOG_FILES

    for pod in "${ORDERED_PODS[@]}"; do
        log "─── Defragging $pod (${MEMBER_ROLES[$pod]}) ───"

        DB_SIZE_BEFORE[$pod]=$(get_db_size "$pod")
        log "  DB size before: $(human_bytes "${DB_SIZE_BEFORE[$pod]}")"

        local probe_log
        probe_log=$(mktemp /tmp/defrag-probe-${pod}.XXXXXX)
        PROBE_LOG_FILES[$pod]=$probe_log
        CLEANUP_FILES+=("$probe_log")

        local pod_ip="${POD_IPS[$pod]}"

        local probe_pid
        probe_pid=$(start_grpc_probe "$pod" "$probe_log" "$PROBE_INTERVAL" "$pod_ip")
        CLEANUP_PIDS+=("$probe_pid")
        log "  gRPC probe started (PID=$probe_pid, interval=${PROBE_INTERVAL}s, endpoint=${pod_ip})"

        log "  Waiting 5s for baseline probe measurements..."
        sleep 5

        log "  Triggering defrag on local member (${pod_ip})..."
        local defrag_start defrag_end dur
        defrag_start=$(date +%s)

        if oc exec -n "$ETCD_NS" "$pod" -c etcdctl -- \
            env -u ETCDCTL_ENDPOINTS etcdctl defrag \
            --endpoints="https://${pod_ip}:2379" --command-timeout=300s 2>&1; then
            defrag_end=$(date +%s)
            dur=$((defrag_end - defrag_start))
            DEFRAG_DURATION[$pod]=$dur
            ok "  $pod defragged in ${dur}s"
        else
            defrag_end=$(date +%s)
            dur=$((defrag_end - defrag_start))
            DEFRAG_DURATION[$pod]=$dur
            fail "  $pod defrag failed after ${dur}s"
        fi

        log "  Waiting 5s for recovery baseline..."
        sleep 5

        kill "$probe_pid" 2>/dev/null || true
        wait "$probe_pid" 2>/dev/null || true
        log "  gRPC probe stopped ($(wc -l < "$probe_log") samples collected)"

        DB_SIZE_AFTER[$pod]=$(get_db_size "$pod")
        log "  DB size after: $(human_bytes "${DB_SIZE_AFTER[$pod]}")"

        if [[ "$pod" != "${ORDERED_PODS[-1]}" ]]; then
            log "  Waiting 60s for member recovery before next defrag..."
            sleep 60
        fi
    done

    kill "$writer_pid" 2>/dev/null || true
    wait "$writer_pid" 2>/dev/null || true
    log "Background writer stopped ($(wc -l < "$write_log") writes)"

    WRITE_LOG_FILE=$write_log
}

# ─── Phase 3: Analyze and save ──────────────────────────────────────────────

analyze_probe_log() {
    local probe_log=$1
    local threshold=$2
    local probe_interval_ms
    probe_interval_ms=$(echo "$PROBE_INTERVAL * 1000" | bc | cut -d. -f1)
    local gap_tolerance_ms=$(( probe_interval_ms * 3 + probe_interval_ms ))

    if [[ ! -s "$probe_log" ]]; then
        echo '{}'
        return
    fi

    jq -R -s --argjson threshold "$threshold" --argjson gap_tol "$gap_tolerance_ms" '
    [split("\n")[] | select(length > 0) | split(" ") |
     select(length >= 4) |
     {start_ms: (.[0] | tonumber), end_ms: (.[1] | tonumber),
      status: .[2], latency_ms: (.[3] | tonumber)}] |

    . as $probes |
    length as $total |

    [.[] | select(.status == "fail" or .latency_ms > $threshold)] as $degraded |

    ($degraded | if length == 0 then []
     else
       reduce .[] as $p (
         {windows: [], current: null};
         if .current == null then
           .current = {start: $p.start_ms, end: $p.end_ms}
         elif ($p.start_ms - .current.end) <= $gap_tol then
           .current.end = $p.end_ms
         else
           .windows += [.current] |
           .current = {start: $p.start_ms, end: $p.end_ms}
         end
       ) | .windows + (if .current then [.current] else [] end)
     end) as $windows |

    ($windows | if length == 0 then {start: 0, end: 0, duration: 0}
     else [.[] | . + {duration: (.end - .start)}] | sort_by(-.duration) | .[0]
     end) as $longest |

    ([$windows[] | (.end - .start)] | if length == 0 then 0 else add end) as $total_disrupted |

    [$probes[].latency_ms] | sort as $sorted |
    ($sorted | length) as $n |

    {
      longest_window_ms: $longest.duration,
      longest_window_start_ms: $longest.start,
      longest_window_end_ms: $longest.end,
      total_disrupted_ms: $total_disrupted,
      window_count: ($windows | length),
      probes_total: $total,
      probes_failed: ([$probes[] | select(.status == "fail")] | length),
      probes_degraded: ($degraded | length),
      failure_rate_pct: (([$probes[] | select(.status == "fail")] | length) * 100.0 / (if $total == 0 then 1 else $total end)),
      latency: {
        min_ms: ($sorted | first // 0),
        p50_ms: ($sorted[($n * 50 / 100)] // 0),
        p95_ms: ($sorted[($n * 95 / 100)] // 0),
        p99_ms: ($sorted[($n * 99 / 100)] // 0),
        max_ms: ($sorted | last // 0),
        avg_ms: (if $n == 0 then 0 else ([$probes[].latency_ms] | add) / $n | round end)
      }
    }
    ' < "$probe_log"
}

analyze_write_log() {
    local write_log=$1

    if [[ ! -s "$write_log" ]]; then
        echo '{"total":0,"succeeded":0,"failed":0,"success_rate_pct":100,"latency":{"min_ms":0,"p50_ms":0,"p95_ms":0,"p99_ms":0,"max_ms":0,"avg_ms":0}}'
        return
    fi

    jq -R -s '
    [split("\n")[] | select(length > 0) | split(" ") |
     select(length >= 4) |
     {start_ms: (.[0] | tonumber), end_ms: (.[1] | tonumber),
      status: .[2], latency_ms: (.[3] | tonumber), target_pod: (.[4] // "unknown")}] |

    length as $total |
    [.[] | select(.status == "ok")] | length as $ok |
    ($total - $ok) as $failed |

    [.[].latency_ms] | sort as $sorted |
    ($sorted | length) as $n |

    {
      total: $total,
      succeeded: $ok,
      failed: $failed,
      success_rate_pct: (if $total == 0 then 100 else ($ok * 100.0 / $total) end),
      latency: {
        min_ms: ($sorted | first // 0),
        p50_ms: ($sorted[($n * 50 / 100)] // 0),
        p95_ms: ($sorted[($n * 95 / 100)] // 0),
        p99_ms: ($sorted[($n * 99 / 100)] // 0),
        max_ms: ($sorted | last // 0),
        avg_ms: (if $n == 0 then 0 else (add / $n) | round end)
      }
    }
    ' < "$write_log"
}

save_results() {
    log "Analyzing results..."

    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Build members array (WITHOUT full probe logs to avoid ARG_MAX)
    local members_json="[]"
    for pod in "${ORDERED_PODS[@]}"; do
        local disruption_json
        disruption_json=$(analyze_probe_log "${PROBE_LOG_FILES[$pod]}" "$THRESHOLD_MS")

        members_json=$(echo "$members_json" | jq \
            --arg pod "$pod" \
            --arg role "${MEMBER_ROLES[$pod]}" \
            --argjson dur "${DEFRAG_DURATION[$pod]}" \
            --argjson db_before "${DB_SIZE_BEFORE[$pod]}" \
            --argjson db_after "${DB_SIZE_AFTER[$pod]}" \
            --argjson disruption "$disruption_json" \
            '. + [{
                pod: $pod,
                role: $role,
                defrag_duration_s: $dur,
                db_size_before: $db_before,
                db_size_after: $db_after,
                grpc_disruption: $disruption
            }]')
    done

    local writes_json
    writes_json=$(analyze_write_log "$WRITE_LOG_FILE")

    local output_file="/tmp/defrag-test-direct-${LABEL}-$(date +%Y%m%d-%H%M%S).json"

    # Create JSON without raw logs (they're too big for command line args)
    jq -n \
        --arg label "$LABEL" \
        --arg timestamp "$timestamp" \
        --arg cluster "$CLUSTER_URL" \
        --arg cluster_version "$CLUSTER_VERSION" \
        --arg etcd_image "$ETCD_IMAGE" \
        --argjson probe_interval "$PROBE_INTERVAL" \
        --argjson write_interval "$WRITE_INTERVAL" \
        --argjson threshold "$THRESHOLD_MS" \
        --argjson members "$members_json" \
        --argjson etcd_writes "$writes_json" \
        '{
            metadata: {
                label: $label,
                timestamp: $timestamp,
                cluster: $cluster,
                cluster_version: $cluster_version,
                etcd_image: $etcd_image,
                probe_interval_s: $probe_interval,
                write_interval_s: $write_interval,
                threshold_ms: $threshold,
                write_method: "direct_etcdctl_put"
            },
            members: $members,
            etcd_writes: $etcd_writes
        }' > "$output_file"

    ok "Results saved to: $output_file"
    OUTPUT_FILE=$output_file
}

print_summary() {
    echo
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}              DEFRAG DISRUPTION TEST RESULTS                  ${NC}"
    echo -e "${BOLD}              Label: ${LABEL} (Direct etcdctl)               ${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo

    echo -e "${BOLD}Cluster:${NC}         $CLUSTER_URL"
    echo -e "${BOLD}Version:${NC}         $CLUSTER_VERSION"
    echo -e "${BOLD}etcd image:${NC}      $ETCD_IMAGE"
    echo -e "${BOLD}Probe interval:${NC}  ${PROBE_INTERVAL}s"
    echo -e "${BOLD}Write interval:${NC}  ${WRITE_INTERVAL}s"
    echo -e "${BOLD}Threshold:${NC}       ${THRESHOLD_MS}ms"
    echo

    echo -e "${BOLD}─── gRPC Disruption per Member ─────────────────────────────${NC}"
    for pod in "${ORDERED_PODS[@]}"; do
        local disruption
        disruption=$(jq ".members[] | select(.pod == \"$pod\") | .grpc_disruption" < "$OUTPUT_FILE")

        local window_ms total_ms probes_total probes_failed p99 max_lat
        window_ms=$(echo "$disruption" | jq '.longest_window_ms')
        total_ms=$(echo "$disruption" | jq '.total_disrupted_ms')
        probes_total=$(echo "$disruption" | jq '.probes_total')
        probes_failed=$(echo "$disruption" | jq '.probes_failed')
        p99=$(echo "$disruption" | jq '.latency.p99_ms')
        max_lat=$(echo "$disruption" | jq '.latency.max_ms')

        echo
        echo -e "  ${BOLD}$pod${NC} (${MEMBER_ROLES[$pod]})"
        echo "    Defrag duration:     ${DEFRAG_DURATION[$pod]}s"
        echo "    Disruption window:   ${window_ms}ms"
        echo "    Total disrupted:     ${total_ms}ms"
        echo "    Probes failed:       ${probes_failed}/${probes_total}"
        echo "    Probe p99 latency:   ${p99}ms"
        echo "    Probe max latency:   ${max_lat}ms"
        echo "    DB before:           $(human_bytes "${DB_SIZE_BEFORE[$pod]}")"
        echo "    DB after:            $(human_bytes "${DB_SIZE_AFTER[$pod]}")"
        echo "    Reclaimed:           $(human_bytes $(( ${DB_SIZE_BEFORE[$pod]} - ${DB_SIZE_AFTER[$pod]} )))"
    done

    echo
    echo -e "${BOLD}─── Direct etcd Write Availability ────────────────────────${NC}"
    local writes
    writes=$(jq '.etcd_writes' < "$OUTPUT_FILE")
    echo "  Total writes:       $(echo "$writes" | jq '.total')"
    echo "  Failed writes:      $(echo "$writes" | jq '.failed')"
    echo "  Success rate:       $(echo "$writes" | jq '.success_rate_pct')%"
    echo "  Avg latency:        $(echo "$writes" | jq '.latency.avg_ms')ms"
    echo "  P99 latency:        $(echo "$writes" | jq '.latency.p99_ms')ms"
    echo "  Max latency:        $(echo "$writes" | jq '.latency.max_ms')ms"

    echo
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo
    ok "Results JSON: $OUTPUT_FILE"
    echo "  Compare with: $0 --compare $OUTPUT_FILE <other-run.json>"
}

# ─── Compare mode (reuse from original script) ───────────────────────────────

compare_results() {
    local file_a=$1
    local file_b=$2

    local label_a label_b cluster_a cluster_b image_a image_b version_a version_b
    label_a=$(jq -r '.metadata.label' < "$file_a")
    label_b=$(jq -r '.metadata.label' < "$file_b")
    cluster_a=$(jq -r '.metadata.cluster' < "$file_a")
    cluster_b=$(jq -r '.metadata.cluster' < "$file_b")
    image_a=$(jq -r '.metadata.etcd_image' < "$file_a")
    image_b=$(jq -r '.metadata.etcd_image' < "$file_b")
    version_a=$(jq -r '.metadata.cluster_version' < "$file_a")
    version_b=$(jq -r '.metadata.cluster_version' < "$file_b")

    echo
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}                   DEFRAG A/B COMPARISON (Direct etcdctl)                ${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo
    printf "  %-22s %-30s %-30s\n" "" "A ($label_a)" "B ($label_b)"
    printf "  %-22s %-30s %-30s\n" "Cluster:" "$cluster_a" "$cluster_b"
    printf "  %-22s %-30s %-30s\n" "Version:" "$version_a" "$version_b"
    local img_a_short="${image_a##*/}"
    local img_b_short="${image_b##*/}"
    printf "  %-22s %-30s %-30s\n" "etcd image:" "$img_a_short" "$img_b_short"
    echo

    # gRPC Disruption per member
    echo -e "${BOLD}─── gRPC Disruption (per member) ──────────────────────────────────────────${NC}"
    echo

    local members_a members_b
    members_a=$(jq -r '.members | length' < "$file_a")
    members_b=$(jq -r '.members | length' < "$file_b")
    local max_members=$(( members_a > members_b ? members_a : members_b ))

    for (( i=0; i<max_members; i++ )); do
        local pod_a role_a window_a failed_a total_a p99_a
        pod_a=$(jq -r ".members[$i].pod // \"N/A\"" < "$file_a")
        role_a=$(jq -r ".members[$i].role // \"\"" < "$file_a")
        window_a=$(jq ".members[$i].grpc_disruption.longest_window_ms // 0" < "$file_a")
        failed_a=$(jq ".members[$i].grpc_disruption.probes_failed // 0" < "$file_a")
        total_a=$(jq ".members[$i].grpc_disruption.probes_total // 0" < "$file_a")
        p99_a=$(jq ".members[$i].grpc_disruption.latency.p99_ms // 0" < "$file_a")

        local pod_b role_b window_b failed_b total_b p99_b
        pod_b=$(jq -r ".members[$i].pod // \"N/A\"" < "$file_b")
        role_b=$(jq -r ".members[$i].role // \"\"" < "$file_b")
        window_b=$(jq ".members[$i].grpc_disruption.longest_window_ms // 0" < "$file_b")
        failed_b=$(jq ".members[$i].grpc_disruption.probes_failed // 0" < "$file_b")
        total_b=$(jq ".members[$i].grpc_disruption.probes_total // 0" < "$file_b")
        p99_b=$(jq ".members[$i].grpc_disruption.latency.p99_ms // 0" < "$file_b")

        local dur_a dur_b
        dur_a=$(jq ".members[$i].defrag_duration_s // 0" < "$file_a")
        dur_b=$(jq ".members[$i].defrag_duration_s // 0" < "$file_b")

        echo -e "  ${BOLD}member-$i ($role_a / $role_b):${NC}"

        # Disruption window
        local window_delta window_pct marker=""
        window_delta=$((window_b - window_a))
        if (( window_a > 0 )); then
            window_pct=$(echo "scale=1; $window_delta * 100 / $window_a" | bc)
        else
            window_pct="N/A"
        fi
        [[ "$window_pct" != "N/A" ]] && (( $(echo "${window_pct#-} > 50" | bc -l) )) && marker="  <<<"

        local window_color="$NC"
        if (( window_b < window_a )); then window_color="$GREEN"
        elif (( window_b > window_a )); then window_color="$RED"
        fi

        printf "    %-24s %12sms  %12sms  ${window_color}%+8s%%${NC}${marker}\n" \
            "disruption window:" "$window_a" "$window_b" "$window_pct"

        # Probes failed
        printf "    %-24s %8s/%s  %8s/%s\n" \
            "probes failed:" "$failed_a" "$total_a" "$failed_b" "$total_b"

        # p99
        local p99_delta p99_pct p99_marker=""
        p99_delta=$((p99_b - p99_a))
        if (( p99_a > 0 )); then
            p99_pct=$(echo "scale=1; $p99_delta * 100 / $p99_a" | bc)
        else
            p99_pct="N/A"
        fi
        [[ "$p99_pct" != "N/A" ]] && (( $(echo "${p99_pct#-} > 50" | bc -l) )) && p99_marker="  <<<"

        local p99_color="$NC"
        if (( p99_b < p99_a )); then p99_color="$GREEN"
        elif (( p99_b > p99_a )); then p99_color="$RED"
        fi

        printf "    %-24s %12sms  %12sms  ${p99_color}%+8s%%${NC}${p99_marker}\n" \
            "probe p99:" "$p99_a" "$p99_b" "$p99_pct"

        # Defrag duration
        printf "    %-24s %12ss   %12ss\n" "defrag duration:" "$dur_a" "$dur_b"
        echo
    done

    # Direct etcd Write Availability
    echo -e "${BOLD}─── Direct etcd Write Availability ────────────────────────────────────────${NC}"
    echo
    local fail_a fail_b rate_a rate_b wp99_a wp99_b wmax_a wmax_b
    fail_a=$(jq '.etcd_writes.failed // 0' < "$file_a")
    fail_b=$(jq '.etcd_writes.failed // 0' < "$file_b")
    rate_a=$(jq '.etcd_writes.success_rate_pct // 100' < "$file_a")
    rate_b=$(jq '.etcd_writes.success_rate_pct // 100' < "$file_b")
    wp99_a=$(jq '.etcd_writes.latency.p99_ms // 0' < "$file_a")
    wp99_b=$(jq '.etcd_writes.latency.p99_ms // 0' < "$file_b")
    wmax_a=$(jq '.etcd_writes.latency.max_ms // 0' < "$file_a")
    wmax_b=$(jq '.etcd_writes.latency.max_ms // 0' < "$file_b")

    printf "    %-24s %14s  %14s\n" "Failed writes:" "$fail_a" "$fail_b"
    printf "    %-24s %13s%%  %13s%%\n" "Success rate:" "$rate_a" "$rate_b"
    printf "    %-24s %12sms  %12sms\n" "p99 latency:" "$wp99_a" "$wp99_b"
    printf "    %-24s %12sms  %12sms\n" "Max latency:" "$wmax_a" "$wmax_b"
    echo

    # DB Size
    echo -e "${BOLD}─── DB Size ──────────────────────────────────────────────────────────────${NC}"
    echo
    for (( i=0; i<max_members; i++ )); do
        local before_a before_b after_a after_b
        before_a=$(jq ".members[$i].db_size_before // 0" < "$file_a")
        before_b=$(jq ".members[$i].db_size_before // 0" < "$file_b")
        after_a=$(jq ".members[$i].db_size_after // 0" < "$file_a")
        after_b=$(jq ".members[$i].db_size_after // 0" < "$file_b")

        printf "    member-%d before:  %14s  %14s\n" "$i" "$(human_bytes "$before_a")" "$(human_bytes "$before_b")"
        printf "    member-%d after:   %14s  %14s\n" "$i" "$(human_bytes "$after_a")" "$(human_bytes "$after_b")"
        printf "    member-%d reclaimed:%13s  %13s\n" "$i" "$(human_bytes $((before_a - after_a)))" "$(human_bytes $((before_b - after_b)))"
        echo
    done

    # Verdict
    echo -e "${BOLD}─── Verdict ──────────────────────────────────────────────────────────────${NC}"
    echo

    # Average disruption window across members
    local avg_window_a=0 avg_window_b=0
    for (( i=0; i<max_members; i++ )); do
        local wa wb
        wa=$(jq ".members[$i].grpc_disruption.longest_window_ms // 0" < "$file_a")
        wb=$(jq ".members[$i].grpc_disruption.longest_window_ms // 0" < "$file_b")
        avg_window_a=$((avg_window_a + wa))
        avg_window_b=$((avg_window_b + wb))
    done
    if (( max_members > 0 )); then
        avg_window_a=$((avg_window_a / max_members))
        avg_window_b=$((avg_window_b / max_members))
    fi

    if (( avg_window_a > 0 )); then
        local reduction
        reduction=$(echo "scale=4; r = (1 - $avg_window_b * 1.0 / $avg_window_a) * 100; scale=1; r / 1" | bc)
        echo -e "  ${GREEN}gRPC disruption window reduced by ~${reduction}% (${avg_window_a}ms -> ${avg_window_b}ms avg)${NC}"
    else
        echo "  gRPC disruption: A=${avg_window_a}ms, B=${avg_window_b}ms"
    fi

    if (( fail_a > 0 && fail_b == 0 )); then
        echo -e "  ${GREEN}Direct etcd write failures eliminated (${fail_a} -> 0)${NC}"
    elif (( fail_b < fail_a )); then
        echo -e "  ${GREEN}Direct etcd write failures reduced (${fail_a} -> ${fail_b})${NC}"
    elif (( fail_b > fail_a )); then
        echo -e "  ${RED}Direct etcd write failures increased (${fail_a} -> ${fail_b})${NC}"
    else
        echo "  Direct etcd write failures unchanged ($fail_a)"
    fi

    echo
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════════${NC}"
}

# ─── Main ────────────────────────────────────────────────────────────────────

parse_args "$@"

if $COMPARE_MODE; then
    compare_results "$COMPARE_FILE_A" "$COMPARE_FILE_B"
    exit 0
fi

trap cleanup EXIT

check_prereqs
capture_metadata
defrag_with_probes
save_results
print_summary
