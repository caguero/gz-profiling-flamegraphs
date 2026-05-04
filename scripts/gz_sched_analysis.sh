#!/usr/bin/env bash
# gz_sched_analysis.sh — Scheduler latency analysis for Gazebo
#
# Usage:
#   Live:    ./gz_sched_analysis.sh <world.sdf> <label> [duration_s]
#   By PID:  ./gz_sched_analysis.sh --pid <PID> <label> [duration_s]
#
# Measures per-thread scheduling delays using /proc/PID/task/TID/schedstat.
# Two snapshots are taken (start/end) to compute scheduling wait time
# during the measurement interval. Flags threads where average scheduling
# delay exceeds a threshold (default 1.0ms).
#
# schedstat fields: cpu_time_ns  runqueue_wait_ns  timeslices_run
#
# No special permissions needed — works with default perf_event_paranoid.
#
# Outputs:
#   ${LABEL}_sched.tsv    Per-thread scheduling metrics (machine-readable)

set +o pipefail

SCHED_THRESHOLD_MS="${SCHED_THRESHOLD_MS:-1.0}"

MODE="${1:?Usage: $0 <world.sdf> <label> [duration] OR $0 --pid <PID> <label> [duration]}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/captures/sched}"

mkdir -p "$OUTPUT_DIR"

# Snapshot schedstat for all threads of a PID
# Output: thread_name TID cpu_ns wait_ns timeslices
snapshot_schedstat() {
    local pid="$1"
    for tid in $(ls "/proc/$pid/task/" 2>/dev/null); do
        local sfile="/proc/$pid/task/$tid/schedstat"
        local cfile="/proc/$pid/task/$tid/comm"
        if [[ -f "$sfile" && -f "$cfile" ]]; then
            local name
            name=$(cat "$cfile" 2>/dev/null)
            local stats
            stats=$(cat "$sfile" 2>/dev/null)
            echo "$name $tid $stats"
        fi
    done
}

case "$MODE" in
    --pid)
        PID="${2:?Usage: $0 --pid <PID> <label> [duration_s]}"
        LABEL="${3:?Usage: $0 --pid <PID> <label> [duration_s]}"
        DURATION="${4:-10}"
        GZ_PID="$PID"

        if ! kill -0 "$PID" 2>/dev/null; then
            echo "ERROR: Process $PID not found" >&2
            exit 1
        fi

        echo "=== Scheduler Analysis: $LABEL ==="
        echo "  PID:       $GZ_PID"
        echo "  Duration:  ${DURATION}s"
        echo "  Threshold: ${SCHED_THRESHOLD_MS}ms avg delay"
        echo ""
        ;;

    *)
        WORLD="$MODE"
        LABEL="${2:?Usage: $0 <world.sdf> <label> [duration_s]}"
        DURATION="${3:-10}"
        STARTUP_WAIT=40

        GZ_SIM_MAIN="${GZ_SIM_MAIN:-$(which gz-sim-main 2>/dev/null || echo "")}"
        if [[ -z "$GZ_SIM_MAIN" || ! -x "$GZ_SIM_MAIN" ]]; then
            for candidate in \
                "$(dirname "$SCRIPT_DIR")/../../install/libexec/gz/sim/gz-sim-main" \
                "/usr/libexec/gz/sim/gz-sim-main"; do
                if [[ -x "$candidate" ]]; then
                    GZ_SIM_MAIN="$candidate"
                    break
                fi
            done
        fi
        if [[ -z "$GZ_SIM_MAIN" || ! -x "$GZ_SIM_MAIN" ]]; then
            echo "ERROR: gz-sim-main not found. Set GZ_SIM_MAIN." >&2
            exit 1
        fi

        echo "=== Scheduler Analysis: $LABEL ==="
        echo "  World:     $WORLD"
        echo "  Duration:  ${DURATION}s"
        echo "  Threshold: ${SCHED_THRESHOLD_MS}ms avg delay"
        echo ""

        echo "[0/3] Launching gz-sim-main..."
        "$GZ_SIM_MAIN" -s -r "$WORLD" > /dev/null 2>&1 &
        GZ_PID=$!
        echo "  PID: $GZ_PID"

        echo "  Waiting ${STARTUP_WAIT}s for loading..."
        sleep "$STARTUP_WAIT"

        if ! kill -0 "$GZ_PID" 2>/dev/null; then
            echo "ERROR: gz-sim-main exited during startup" >&2
            exit 1
        fi
        ;;
esac

# Step 1: Take start snapshot
echo "[1/3] Taking start snapshot..."
SNAP1=$(mktemp)
snapshot_schedstat "$GZ_PID" > "$SNAP1"

# Step 2: Wait for measurement interval
echo "[2/3] Measuring for ${DURATION}s..."
sleep "$DURATION"

# Step 3: Take end snapshot and compute deltas
echo "[3/3] Computing scheduling delays..."
SNAP2=$(mktemp)
snapshot_schedstat "$GZ_PID" > "$SNAP2"

# Kill simulation if we launched it
if [[ "$MODE" != "--pid" ]]; then
    kill "$GZ_PID" 2>/dev/null
    wait "$GZ_PID" 2>/dev/null
fi

# Compute deltas between snapshots
{
    echo "# Scheduler analysis: $LABEL"
    echo "# Duration: ${DURATION}s"
    echo "# Threshold: avg_delay > ${SCHED_THRESHOLD_MS}ms flagged"
    echo "thread_name	tid	cpu_ms	wait_ms	switches	avg_delay_ms	max_possible_ms	flagged"

    # Join snapshots on TID and compute deltas
    awk -v threshold="$SCHED_THRESHOLD_MS" -v dur="$DURATION" '
    FILENAME == ARGV[1] {
        # Start snapshot: name tid cpu_ns wait_ns timeslices
        start_cpu[$2] = $3 + 0
        start_wait[$2] = $4 + 0
        start_ts[$2] = $5 + 0
        names[$2] = $1
        next
    }
    FILENAME == ARGV[2] {
        # End snapshot
        tid = $2
        if (!(tid in start_cpu)) next

        d_cpu = ($3 - start_cpu[tid]) / 1000000.0    # ns -> ms
        d_wait = ($4 - start_wait[tid]) / 1000000.0   # ns -> ms
        d_ts = ($5 - start_ts[tid]) + 0

        if (d_ts <= 0) next

        avg_delay = d_wait / d_ts
        # Max possible is the entire wait budget (conservative upper bound)
        max_possible = d_wait

        flagged = (avg_delay > threshold + 0) ? "YES" : "NO"

        printf "%s\t%s\t%.1f\t%.1f\t%d\t%.3f\t%.1f\t%s\n", \
            names[tid], tid, d_cpu, d_wait, d_ts, avg_delay, max_possible, flagged
    }
    ' "$SNAP1" "$SNAP2" \
        | sort -t$'\t' -k6 -rg
} > "$OUTPUT_DIR/${LABEL}_sched.tsv"

rm -f "$SNAP1" "$SNAP2"

echo ""
echo "=== Scheduling Delays ==="
tail -n +5 "$OUTPUT_DIR/${LABEL}_sched.tsv" \
    | head -15 \
    | while IFS=$'\t' read -r name tid cpu wait switches avg maxp flag; do
        marker=""
        [[ "$flag" == "YES" ]] && marker=" <-- DELAY"
        printf "  %-20s  TID %-8s  CPU: %8sms  Wait: %8sms  Switches: %6s  Avg: %7sms%s\n" \
            "$name" "$tid" "$cpu" "$wait" "$switches" "$avg" "$marker"
    done

echo ""
echo "=== Results ==="
echo "  TSV: $OUTPUT_DIR/${LABEL}_sched.tsv"
