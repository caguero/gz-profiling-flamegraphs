#!/usr/bin/env bash
# gz_cache_flamegraph.sh — Cache-miss flamegraph capture for Gazebo
#
# Usage:
#   Runtime:  ./gz_cache_flamegraph.sh --runtime <world.sdf> <label> [duration_s]
#   Loading:  ./gz_cache_flamegraph.sh --loading <world.sdf> <label>
#
# Generates a flamegraph showing WHERE cache misses happen (not CPU time).
# Compare with CPU flamegraphs to identify cache-hostile vs compute-bound code.
#
# Prerequisites:
#   - sudo sysctl kernel.perf_event_paranoid=1
#   - GZ_SIM_MAIN set or in PATH
#   - FLAMEGRAPH_DIR set or ./FlameGraph exists

set +o pipefail

MODE="${1:?Usage: $0 --runtime <world.sdf> <label> [duration] OR $0 --loading <world.sdf> <label>}"
WORLD="${2:?Missing world.sdf}"
LABEL="${3:?Missing label}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FLAMEGRAPH_DIR="${FLAMEGRAPH_DIR:-$(pwd)/FlameGraph}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/captures/cache}"
GZ_SIM_MAIN="${GZ_SIM_MAIN:-$(which gz-sim-main 2>/dev/null || echo "")}"

# Try common locations
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

mkdir -p "$OUTPUT_DIR"

if [[ -z "$GZ_SIM_MAIN" || ! -x "$GZ_SIM_MAIN" ]]; then
    echo "ERROR: gz-sim-main not found. Set GZ_SIM_MAIN." >&2
    exit 1
fi
if [[ ! -f "$FLAMEGRAPH_DIR/flamegraph.pl" ]]; then
    echo "ERROR: FlameGraph scripts not found at $FLAMEGRAPH_DIR" >&2
    exit 1
fi

case "$MODE" in
    --runtime)
        DURATION="${4:-30}"
        STARTUP_WAIT=40

        echo "=== Cache-Miss Flamegraph (runtime): $LABEL ==="
        echo "  World:    $WORLD"
        echo "  Duration: ${DURATION}s"
        echo ""

        echo "[1/5] Launching gz-sim-main..."
        "$GZ_SIM_MAIN" -s -r "$WORLD" > /dev/null 2>&1 &
        GZ_PID=$!
        echo "  PID: $GZ_PID"

        echo "[2/5] Waiting ${STARTUP_WAIT}s for loading..."
        sleep "$STARTUP_WAIT"

        if ! kill -0 "$GZ_PID" 2>/dev/null; then
            echo "ERROR: gz-sim-main exited during startup" >&2
            exit 1
        fi

        echo "[3/5] Recording cache misses for ${DURATION}s..."
        perf record -e cache-misses --call-graph dwarf \
            -p "$GZ_PID" \
            -o "$OUTPUT_DIR/perf_${LABEL}_cachemiss.data" \
            sleep "$DURATION" 2>&1 | tail -3

        kill "$GZ_PID" 2>/dev/null
        wait "$GZ_PID" 2>/dev/null
        ;;

    --loading)
        echo "=== Cache-Miss Flamegraph (loading): $LABEL ==="
        echo "  World: $WORLD"
        echo ""

        echo "[1/5] Recording cache misses during loading..."
        perf record -e cache-misses --call-graph dwarf \
            -o "$OUTPUT_DIR/perf_${LABEL}_cachemiss.data" \
            -- "$GZ_SIM_MAIN" -s -r --iterations 1 "$WORLD" 2>&1 | tail -3
        ;;

    *)
        echo "Usage: $0 --runtime <world.sdf> <label> [duration]" >&2
        echo "       $0 --loading <world.sdf> <label>" >&2
        exit 1
        ;;
esac

echo "[4/5] Generating cache-miss flamegraph..."
perf script -i "$OUTPUT_DIR/perf_${LABEL}_cachemiss.data" 2>/dev/null \
    | "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" \
    > "$OUTPUT_DIR/${LABEL}_cachemiss.folded"

"$FLAMEGRAPH_DIR/flamegraph.pl" \
    --title "$LABEL: CACHE MISSES" \
    --subtitle "Where cache misses happen (not CPU time)" \
    --countname "cache misses" \
    "$OUTPUT_DIR/${LABEL}_cachemiss.folded" \
    > "$OUTPUT_DIR/${LABEL}_cachemiss.svg"

echo "[5/5] Top cache-miss hotspots:"
total=$(awk '{s+=$NF} END {print s}' "$OUTPUT_DIR/${LABEL}_cachemiss.folded")
awk '{ n=split($1,a,";"); printf "%s\t%d\n", a[n], $NF }' "$OUTPUT_DIR/${LABEL}_cachemiss.folded" \
    | awk -F'\t' '{s[$1]+=$2} END {for(k in s) printf "%12d  %4.1f%%  %s\n",s[k],s[k]*100.0/'$total',k}' \
    | sort -rn | head -10

echo ""
echo "  SVG:    $OUTPUT_DIR/${LABEL}_cachemiss.svg"
echo "  Folded: $OUTPUT_DIR/${LABEL}_cachemiss.folded"
