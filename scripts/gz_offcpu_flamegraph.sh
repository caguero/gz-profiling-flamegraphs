#!/usr/bin/env bash
# gz_offcpu_flamegraph.sh — Off-CPU (blocking) flamegraph for Gazebo
#
# Usage:
#   Live:    ./gz_offcpu_flamegraph.sh <world.sdf> <label> [duration_s] [run_mode] [topic1 ...]
#   By PID:  ./gz_offcpu_flamegraph.sh --pid <PID> <label> [duration_s]
#
# Captures where threads BLOCK (mutexes, I/O, condition waits) — complementary
# to CPU flamegraphs. Together they account for 100% of thread time.
#
# Uses BCC's offcputime tool (eBPF-based, in-kernel aggregation). Falls back
# to bpftrace if offcputime is not available.
#
# Prerequisites:
#   - sudo access (eBPF programs require root)
#   - offcputime-bpfcc (apt install bpfcc-tools) or bpftrace
#   - FlameGraph scripts at FLAMEGRAPH_DIR
#   - GZ_SIM_MAIN set or in PATH (for live mode)
#
# Outputs:
#   ${LABEL}_offcpu.folded    Collapsed off-CPU stacks (countname: microseconds)
#   ${LABEL}_offcpu.svg       Interactive off-CPU flamegraph
#   ${LABEL}_offcpu.tsv       Top blocking functions with total microseconds

set +o pipefail

# Find offcputime tool
OFFCPUTIME=""
for candidate in \
    /usr/sbin/offcputime-bpfcc \
    /usr/share/bcc/tools/offcputime \
    "$(which offcputime-bpfcc 2>/dev/null)" \
    "$(which offcputime 2>/dev/null)"; do
    if [[ -f "$candidate" && -x "$candidate" ]]; then
        OFFCPUTIME="$candidate"
        break
    fi
done

if [[ -z "$OFFCPUTIME" ]]; then
    echo "ERROR: offcputime-bpfcc not found." >&2
    echo "  Install: sudo apt install bpfcc-tools" >&2
    exit 1
fi

# Check sudo access
if ! sudo -n true 2>/dev/null; then
    echo "NOTE: offcputime requires root. You may be prompted for your password." >&2
fi

MODE="${1:?Usage: $0 <world.sdf> <label> [duration] [run_mode] [topics...] OR $0 --pid <PID> <label> [duration]}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FLAMEGRAPH_DIR="${FLAMEGRAPH_DIR:-$(pwd)/FlameGraph}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/captures/offcpu}"

if [[ ! -f "$FLAMEGRAPH_DIR/flamegraph.pl" ]]; then
    echo "ERROR: FlameGraph scripts not found at $FLAMEGRAPH_DIR" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

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

        echo "=== Off-CPU Flamegraph: $LABEL ==="
        echo "  PID:      $GZ_PID"
        echo "  Duration: ${DURATION}s"
        echo "  Tool:     $OFFCPUTIME"
        echo ""
        ;;

    *)
        WORLD="$MODE"
        LABEL="${2:?Usage: $0 <world.sdf> <label> [duration] [run_mode] [topics...]}"
        DURATION="${3:-10}"
        RUN_MODE="${4:-headless}"
        shift 4 2>/dev/null || true
        TOPICS=("$@")
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

        # Build launch args
        LAUNCH_ARGS=("-s" "-r" "$WORLD")
        case "$RUN_MODE" in
            headless-rendering)
                LAUNCH_ARGS=("-s" "-r" "--headless-rendering" "$WORLD") ;;
            gui)
                LAUNCH_ARGS=("-r" "$WORLD") ;;
        esac

        echo "=== Off-CPU Flamegraph: $LABEL ==="
        echo "  World:    $WORLD"
        echo "  Mode:     $RUN_MODE"
        echo "  Duration: ${DURATION}s"
        echo "  Tool:     $OFFCPUTIME"
        echo ""

        echo "[1/4] Launching gz-sim-main..."
        "$GZ_SIM_MAIN" "${LAUNCH_ARGS[@]}" > /dev/null 2>&1 &
        GZ_PID=$!
        echo "  PID: $GZ_PID"

        echo "  Waiting ${STARTUP_WAIT}s for loading..."
        sleep "$STARTUP_WAIT"

        if ! kill -0 "$GZ_PID" 2>/dev/null; then
            echo "ERROR: gz-sim-main exited during startup" >&2
            exit 1
        fi

        # Start subscribers for sensor topics
        SUB_PIDS=()
        if [[ ${#TOPICS[@]} -gt 0 ]]; then
            for topic in "${TOPICS[@]}"; do
                gz topic -e -t "$topic" > /dev/null 2>&1 &
                SUB_PIDS+=($!)
            done
            sleep 2
        fi
        ;;
esac

# Step 1: Capture off-CPU stacks with offcputime (eBPF)
echo "[2/4] Capturing off-CPU stacks for ${DURATION}s..."

# offcputime -f outputs folded format directly:
#   stack_frame;stack_frame;... count_us
# -U = user stacks only (skip kernel frames for cleaner output)
# -m 1 = minimum 1us block time (skip trivial context switches)
sudo "$OFFCPUTIME" -f -U -p "$GZ_PID" -m 1 "$DURATION" \
    > "$OUTPUT_DIR/${LABEL}_offcpu.folded" 2>/dev/null

# Clean up simulation if we launched it
if [[ "$MODE" != "--pid" ]]; then
    for pid in "${SUB_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    kill "$GZ_PID" 2>/dev/null || true
    wait "$GZ_PID" 2>/dev/null || true
fi

TOTAL_US=$(awk '{s+=$NF} END {print s+0}' "$OUTPUT_DIR/${LABEL}_offcpu.folded")

if [[ "$TOTAL_US" -eq 0 ]]; then
    echo "WARNING: No off-CPU events captured." >&2
    echo "  Ensure sudo access works and the simulation is running." >&2
fi

# Step 2: Generate off-CPU flamegraph
echo "[3/4] Generating off-CPU flamegraph..."
"$FLAMEGRAPH_DIR/flamegraph.pl" \
    --title "$LABEL: OFF-CPU (blocking)" \
    --subtitle "Where threads block — not CPU time (${DURATION}s capture)" \
    --countname "us" \
    --color io \
    "$OUTPUT_DIR/${LABEL}_offcpu.folded" \
    > "$OUTPUT_DIR/${LABEL}_offcpu.svg"

# Step 3: Generate TSV
echo "[4/4] Generating TSV summary..."

total_ms=$(echo "scale=1; $TOTAL_US / 1000" | bc 2>/dev/null)

{
    echo "# Off-CPU analysis: $LABEL"
    echo "# Duration: ${DURATION}s"
    echo "# Total off-CPU time: ${total_ms}ms"
    echo "function_name	offcpu_us	offcpu_pct"

    awk -v total="$TOTAL_US" '{
        # Parse from right: last field is count
        count = $NF
        stack = $0
        sub(/[[:space:]]+[0-9]+[[:space:]]*$/, "", stack)

        # Leaf function (self-time)
        n = split(stack, a, ";")
        leaf = a[n]
        self[leaf] += count
    }
    END {
        if (total == 0) total = 1
        for (f in self) {
            pct = self[f] * 100.0 / total
            if (pct < 0.5) continue
            printf "%s\t%d\t%.1f\n", f, self[f], pct
        }
    }' "$OUTPUT_DIR/${LABEL}_offcpu.folded" \
        | sort -t$'\t' -k2 -rn
} > "$OUTPUT_DIR/${LABEL}_offcpu.tsv"

echo ""
echo "=== Top Off-CPU Functions ==="
grep -v '^#\|^function_name' "$OUTPUT_DIR/${LABEL}_offcpu.tsv" | head -10 \
    | while IFS=$'\t' read -r func us pct; do
        ms=$(echo "scale=1; $us / 1000" | bc 2>/dev/null)
        printf "  %6.1f%%  %8sms  %s\n" "$pct" "$ms" "$func"
    done

echo ""
echo "=== Results ==="
echo "  SVG:    $OUTPUT_DIR/${LABEL}_offcpu.svg"
echo "  Folded: $OUTPUT_DIR/${LABEL}_offcpu.folded"
echo "  TSV:    $OUTPUT_DIR/${LABEL}_offcpu.tsv"
