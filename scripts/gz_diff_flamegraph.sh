#!/usr/bin/env bash
# gz_diff_flamegraph.sh — Differential flamegraph for before/after comparison
#
# Usage: ./gz_diff_flamegraph.sh <baseline.folded> <optimized.folded> [label]
#
# Generates a differential flamegraph (red = regression, blue = improvement)
# plus a machine-readable TSV of the top changes ranked by absolute delta.
#
# Requires: difffolded.pl and flamegraph.pl from Brendan Gregg's FlameGraph
#
# Outputs:
#   ${LABEL}_diff.svg       Interactive differential flamegraph
#   ${LABEL}_diff.folded    Diff stacks (three-column: stack count1 count2)
#   ${LABEL}_diff.tsv       Top changes ranked by absolute delta

set +o pipefail

BASELINE="${1:?Usage: $0 <baseline.folded> <optimized.folded> [label]}"
OPTIMIZED="${2:?Usage: $0 <baseline.folded> <optimized.folded> [label]}"
LABEL="${3:-diff_$(date +%Y%m%d_%H%M%S)}"

FLAMEGRAPH_DIR="${FLAMEGRAPH_DIR:-$(pwd)/FlameGraph}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/captures/diff}"

if [[ ! -f "$BASELINE" ]]; then
    echo "ERROR: Baseline file not found: $BASELINE" >&2
    exit 1
fi
if [[ ! -f "$OPTIMIZED" ]]; then
    echo "ERROR: Optimized file not found: $OPTIMIZED" >&2
    exit 1
fi
if [[ ! -f "$FLAMEGRAPH_DIR/difffolded.pl" ]]; then
    echo "ERROR: difffolded.pl not found at $FLAMEGRAPH_DIR" >&2
    echo "  Set FLAMEGRAPH_DIR or clone https://github.com/brendangregg/FlameGraph" >&2
    exit 1
fi
if [[ ! -f "$FLAMEGRAPH_DIR/flamegraph.pl" ]]; then
    echo "ERROR: flamegraph.pl not found at $FLAMEGRAPH_DIR" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

BASELINE_LABEL=$(basename "$BASELINE" .folded)
OPTIMIZED_LABEL=$(basename "$OPTIMIZED" .folded)

echo "=== Differential Flamegraph: $LABEL ==="
echo "  Baseline:  $BASELINE ($BASELINE_LABEL)"
echo "  Optimized: $OPTIMIZED ($OPTIMIZED_LABEL)"
echo ""

# Step 1: Generate diff folded (three-column: stack count1 count2)
echo "[1/3] Computing differential..."
"$FLAMEGRAPH_DIR/difffolded.pl" -n "$BASELINE" "$OPTIMIZED" \
    > "$OUTPUT_DIR/${LABEL}_diff.folded"

# Step 2: Generate differential SVG
echo "[2/3] Generating differential flamegraph..."
"$FLAMEGRAPH_DIR/flamegraph.pl" \
    --title "$LABEL: differential" \
    --subtitle "Blue = improvement, Red = regression (baseline: $BASELINE_LABEL)" \
    < "$OUTPUT_DIR/${LABEL}_diff.folded" \
    > "$OUTPUT_DIR/${LABEL}_diff.svg"

# Step 3: Generate machine-readable TSV of top changes
echo "[3/3] Extracting top changes..."

BASELINE_TOTAL=$(awk '{s+=$NF} END {print s}' "$BASELINE")
OPTIMIZED_TOTAL=$(awk '{s+=$NF} END {print s}' "$OPTIMIZED")

# Extract per-function self-time deltas from the diff folded file.
# difffolded.pl output format: stack count1 count2
# Stacks may contain spaces (C++ templates), so parse counts from the right.
awk -v bt="$BASELINE_TOTAL" -v ot="$OPTIMIZED_TOTAL" \
    -v lbl="$LABEL" -v blbl="$BASELINE_LABEL" -v olbl="$OPTIMIZED_LABEL" '
BEGIN {
    OFS = "\t"
}
{
    # Parse from the right: last two fields are count1 count2
    c2 = $NF + 0
    c1 = $(NF-1) + 0

    # Reconstruct the stack (everything except the last two fields)
    stack = $0
    sub(/[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]*$/, "", stack)

    n = split(stack, a, ";")
    leaf = a[n]

    self_b[leaf] += c1
    self_o[leaf] += c2
}
END {
    if (bt == 0) bt = 1
    if (ot == 0) ot = 1

    print "# Differential analysis: " lbl
    print "# Baseline: " blbl " (" bt " samples)"
    print "# Optimized: " olbl " (" ot " samples)"
    print "# Negative delta_pct = improvement, positive = regression"
    print "function_name\tbaseline_pct\toptimized_pct\tdelta_pct\tdirection"

    for (f in self_b) {
        bp = self_b[f] * 100.0 / bt
        op = (f in self_o) ? self_o[f] * 100.0 / ot : 0
        delta = op - bp
        if (bp < 0.5 && op < 0.5) continue
        dir = (delta < -0.1) ? "improvement" : (delta > 0.1) ? "regression" : "unchanged"
        printf "%s\t%.1f\t%.1f\t%+.1f\t%s\n", f, bp, op, delta, dir
    }
    # Functions that only appear in optimized (new code paths)
    for (f in self_o) {
        if (!(f in self_b)) {
            op = self_o[f] * 100.0 / ot
            if (op < 0.5) continue
            printf "%s\t0.0\t%.1f\t+%.1f\tregression\n", f, op, op
        }
    }
}' "$OUTPUT_DIR/${LABEL}_diff.folded" \
    | (head -5; tail -n +6 | sort -t$'\t' -k4 -g) \
    > "$OUTPUT_DIR/${LABEL}_diff.tsv"

echo ""
echo "=== Top Changes ==="
# Print the top 10 improvements and regressions
tail -n +6 "$OUTPUT_DIR/${LABEL}_diff.tsv" \
    | awk -F'\t' '$5 == "improvement"' | head -5 \
    | while IFS=$'\t' read -r func bp op delta dir; do
        printf "  %+6s%%  %s\n" "$delta" "$func"
    done

echo "  ---"

tail -n +6 "$OUTPUT_DIR/${LABEL}_diff.tsv" \
    | awk -F'\t' '$5 == "regression"' | sort -t$'\t' -k4 -rg | head -5 \
    | while IFS=$'\t' read -r func bp op delta dir; do
        printf "  %+6s%%  %s\n" "$delta" "$func"
    done

echo ""
echo "=== Results ==="
echo "  SVG:    $OUTPUT_DIR/${LABEL}_diff.svg"
echo "  Folded: $OUTPUT_DIR/${LABEL}_diff.folded"
echo "  TSV:    $OUTPUT_DIR/${LABEL}_diff.tsv"
