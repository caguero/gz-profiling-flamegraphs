#!/usr/bin/env bash
# gz_false_sharing.sh — False sharing detection for Gazebo using perf c2c
#
# Usage:
#   Live:     ./gz_false_sharing.sh --runtime <world.sdf> <label> [duration_s]
#   By PID:   ./gz_false_sharing.sh --pid <PID> <label> [duration_s]
#   Analyze:  ./gz_false_sharing.sh --analyze <perf_c2c_data> <label>
#
# Detects cacheline contention between threads using HITM (Hit-In-Modified)
# events. High HITM rates indicate false sharing — threads writing to
# different data that shares a cache line.
#
# Prerequisites:
#   - perf_event_paranoid <= 1
#   - GZ_SIM_MAIN set or in PATH (for --runtime mode)
#
# Outputs:
#   ${LABEL}_c2c_report.txt   Full perf c2c report (human-readable)
#   ${LABEL}_c2c.tsv          Per-symbol HITM rates (machine-readable)

set +o pipefail

MODE="${1:?Usage: $0 --runtime <world.sdf> <label> [dur] OR $0 --pid <PID> <label> [dur] OR $0 --analyze <data> <label>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/captures/c2c}"

mkdir -p "$OUTPUT_DIR"

case "$MODE" in
    --pid)
        PID="${2:?Usage: $0 --pid <PID> <label> [duration_s]}"
        LABEL="${3:?Usage: $0 --pid <PID> <label> [duration_s]}"
        DURATION="${4:-5}"

        if ! kill -0 "$PID" 2>/dev/null; then
            echo "ERROR: Process $PID not found" >&2
            exit 1
        fi

        echo "=== False Sharing Analysis: $LABEL ==="
        echo "  PID:      $PID"
        echo "  Duration: ${DURATION}s"
        echo ""

        echo "[1/3] Recording c2c events for ${DURATION}s..."
        perf c2c record -F 60000 --all-user \
            -p "$PID" \
            -o "$OUTPUT_DIR/perf_${LABEL}_c2c.data" \
            sleep "$DURATION" 2>&1 | tail -3
        ;;

    --runtime)
        WORLD="${2:?Usage: $0 --runtime <world.sdf> <label> [duration_s]}"
        LABEL="${3:?Usage: $0 --runtime <world.sdf> <label> [duration_s]}"
        DURATION="${4:-5}"
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

        echo "=== False Sharing Analysis: $LABEL ==="
        echo "  World:    $WORLD"
        echo "  Duration: ${DURATION}s"
        echo ""

        echo "[1/3] Launching gz-sim-main..."
        "$GZ_SIM_MAIN" -s -r "$WORLD" > /dev/null 2>&1 &
        GZ_PID=$!
        echo "  PID: $GZ_PID"

        echo "  Waiting ${STARTUP_WAIT}s for loading..."
        sleep "$STARTUP_WAIT"

        if ! kill -0 "$GZ_PID" 2>/dev/null; then
            echo "ERROR: gz-sim-main exited during startup" >&2
            exit 1
        fi

        echo "  Recording c2c events for ${DURATION}s..."
        perf c2c record -F 60000 --all-user \
            -p "$GZ_PID" \
            -o "$OUTPUT_DIR/perf_${LABEL}_c2c.data" \
            sleep "$DURATION" 2>&1 | tail -3

        kill "$GZ_PID" 2>/dev/null
        wait "$GZ_PID" 2>/dev/null
        ;;

    --analyze)
        PERF_DATA="${2:?Usage: $0 --analyze <perf_c2c_data> <label>}"
        LABEL="${3:?Usage: $0 --analyze <perf_c2c_data> <label>}"

        if [[ ! -f "$PERF_DATA" ]]; then
            echo "ERROR: File not found: $PERF_DATA" >&2
            exit 1
        fi

        echo "=== False Sharing Analysis: $LABEL ==="
        echo "  Data: $PERF_DATA"
        echo ""

        # Symlink so the report step uses the same path
        ln -sf "$(realpath "$PERF_DATA")" "$OUTPUT_DIR/perf_${LABEL}_c2c.data"
        ;;

    *)
        echo "Usage:" >&2
        echo "  $0 --runtime <world.sdf> <label> [duration]" >&2
        echo "  $0 --pid <PID> <label> [duration]" >&2
        echo "  $0 --analyze <perf_c2c.data> <label>" >&2
        exit 1
        ;;
esac

# Step 2: Generate report
echo "[2/3] Generating c2c report..."
perf c2c report -i "$OUTPUT_DIR/perf_${LABEL}_c2c.data" \
    --stdio 2>/dev/null \
    > "$OUTPUT_DIR/${LABEL}_c2c_report.txt"

# Step 3: Extract machine-readable TSV
echo "[3/3] Extracting HITM metrics..."

# Parse the Trace Event Information section for totals
TOTAL_HITM=$(awk '
    /Load Local HITM/ { local = $NF }
    /Load Remote HITM/ { remote = $NF }
    /Load HIT Local Peer/ { local_peer = $NF }
    /Load HIT Remote Peer/ { remote_peer = $NF }
    END {
        total = local + remote + local_peer + remote_peer + 0
        printf "%d %d %d", total, local + local_peer + 0, remote + remote_peer + 0
    }
' "$OUTPUT_DIR/${LABEL}_c2c_report.txt")

TOTAL=$(echo "$TOTAL_HITM" | awk '{print $1}')
LOCAL=$(echo "$TOTAL_HITM" | awk '{print $2}')
REMOTE=$(echo "$TOTAL_HITM" | awk '{print $3}')

# Parse the "Shared Data Cache Line Table" for per-cacheline contention
# and the "Shared Cache Line Distribution Pareto" for per-symbol data.
# The pareto section has lines with symbol names and HITM counts.
{
    echo "# False sharing analysis: $LABEL"
    echo "# Total HITM events: $TOTAL (Local: $LOCAL, Remote: $REMOTE)"
    echo "# HITM = Hit-In-Modified: cross-thread cacheline contention"
    echo "# High HITM on a symbol suggests false sharing or true sharing contention"
    echo "symbol	dso	total_hitm	hitm_pct"

    # Extract from the Shared Cache Line Distribution Pareto section
    # Format: lines with "[.]" or "[k]" prefix before symbol name, DSO after
    # Example: "  0.00%   90.18%  ... [.] gz::sim::v11::detail::View  libgz-sim..."
    awk -v total="$TOTAL" '
    /Shared Cache Line Distribution Pareto/ { in_pareto = 1; next }
    # Lines with [.] contain user-space symbols
    in_pareto && /\[.\]/ {
        # Extract LclHitm percentage (second percentage field)
        line = $0
        # Find the symbol after "[.]"
        idx = index(line, "[.] ")
        if (idx > 0) {
            rest = substr(line, idx + 4)
            # Symbol is the first whitespace-delimited token after "[.]"
            # But symbols can have :: and <> so take everything up to multiple spaces
            n = split(rest, parts, /  +/)
            sym = parts[1]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", sym)
            dso = (n >= 2) ? parts[2] : "-"
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", dso)

            # Extract LclHitm% — second percentage in the line
            pct_count = 0
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9]+\.[0-9]+%$/) {
                    pct_count++
                    if (pct_count == 2) {
                        lcl_pct = $i + 0
                        break
                    }
                }
            }

            if (sym != "" && sym !~ /^[0-9]/) {
                hitm[sym] += lcl_pct
                dsos[sym] = dso
            }
        }
    }
    END {
        # Count total weighted HITM across all symbols
        grand = 0
        for (s in hitm) grand += hitm[s]
        if (grand == 0) grand = 1

        for (s in hitm) {
            pct = hitm[s] * 100.0 / grand
            if (pct < 0.5) continue
            printf "%s\t%s\t%.0f\t%.1f\n", s, dsos[s], hitm[s], pct
        }
    }' "$OUTPUT_DIR/${LABEL}_c2c_report.txt" \
        | sort -t$'\t' -k3 -rn
} > "$OUTPUT_DIR/${LABEL}_c2c.tsv"

echo ""
echo "=== HITM Summary ==="
echo "  Total HITM:  $TOTAL"
echo "  Local HITM:  $LOCAL"
echo "  Remote HITM: $REMOTE"

if [[ "$TOTAL" -gt 0 ]]; then
    echo ""
    echo "=== Top Contention Symbols ==="
    tail -n +6 "$OUTPUT_DIR/${LABEL}_c2c.tsv" | head -10 \
        | while IFS=$'\t' read -r sym dso hitm pct; do
            printf "  %6.1f%%  %6d HITM  %s\n" "$pct" "$hitm" "$sym"
        done
fi

echo ""
echo "=== Results ==="
echo "  Report: $OUTPUT_DIR/${LABEL}_c2c_report.txt"
echo "  TSV:    $OUTPUT_DIR/${LABEL}_c2c.tsv"
echo "  Data:   $OUTPUT_DIR/perf_${LABEL}_c2c.data"
