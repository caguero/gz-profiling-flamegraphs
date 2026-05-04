#!/usr/bin/env bash
# gz_per_thread_flamegraph.sh — Split a perf capture into per-thread flamegraphs
#
# Usage: ./gz_per_thread_flamegraph.sh <perf_data_file> <label>
#
# Post-processing only: works on existing perf_*.data files (no live simulation).
# Generates one flamegraph per thread plus a TSV summary showing sample
# distribution across threads.
#
# Requires: stackcollapse-perf.pl and flamegraph.pl from Brendan Gregg's FlameGraph
#
# Outputs:
#   ${LABEL}_threads.tsv                  Thread comparison summary
#   ${LABEL}_all_tids.folded              Combined folded with TID annotation
#   ${LABEL}_thread_<NAME>_<TID>.folded   Per-thread folded (one per thread)
#   ${LABEL}_thread_<NAME>_<TID>.svg      Per-thread flamegraph (one per thread)

set +o pipefail

PERF_DATA="${1:?Usage: $0 <perf_data_file> <label>}"
LABEL="${2:?Usage: $0 <perf_data_file> <label>}"

FLAMEGRAPH_DIR="${FLAMEGRAPH_DIR:-$(pwd)/FlameGraph}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/captures/threads}"

if [[ ! -f "$PERF_DATA" ]]; then
    echo "ERROR: perf data file not found: $PERF_DATA" >&2
    exit 1
fi
if [[ ! -f "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" ]]; then
    echo "ERROR: stackcollapse-perf.pl not found at $FLAMEGRAPH_DIR" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

ALL_FOLDED="$OUTPUT_DIR/${LABEL}_all_tids.folded"

echo "=== Per-Thread Flamegraph: $LABEL ==="
echo "  Input: $PERF_DATA"
echo ""

# Step 1: Generate folded output with TID annotation
# --tid produces: "comm-PID/TID;stack... count"
echo "[1/4] Collapsing stacks with thread IDs..."
perf script -i "$PERF_DATA" 2>/dev/null \
    | "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" --tid \
    > "$ALL_FOLDED"

TOTAL_SAMPLES=$(awk '{s+=$NF} END {print s+0}' "$ALL_FOLDED")
if [[ "$TOTAL_SAMPLES" -eq 0 ]]; then
    echo "ERROR: No samples found in perf data" >&2
    exit 1
fi

# Step 2: Identify unique thread labels and their sample counts
echo "[2/4] Identifying threads..."
THREAD_INFO=$(awk '{
    # First field before ";" is the thread label (comm-PID/TID)
    split($0, parts, ";")
    tid_label = parts[1]
    s[tid_label] += $NF
}
END {
    for (t in s) printf "%d\t%s\n", s[t], t
}' "$ALL_FOLDED" | sort -rn)

NUM_THREADS=$(echo "$THREAD_INFO" | wc -l)
echo "  Found $NUM_THREADS threads, $TOTAL_SAMPLES total samples"
echo ""

# Step 3: Generate per-thread flamegraphs
echo "[3/4] Generating per-thread flamegraphs..."
while IFS=$'\t' read -r samples tid_label; do
    pct=$(echo "scale=1; $samples * 100 / $TOTAL_SAMPLES" | bc 2>/dev/null)

    # Create safe filename from tid_label (replace / with _)
    safe_name=$(echo "$tid_label" | tr '/' '_')

    # Extract this thread's stacks, strip the tid_label prefix
    # Use awk with string comparison (not regex) to handle special chars in tid_label
    awk -v prefix="$tid_label" '
    BEGIN { plen = length(prefix) + 1 }  # +1 for the ";"
    substr($0, 1, plen) == prefix ";" {
        print substr($0, plen + 1)
    }' "$ALL_FOLDED" \
        > "$OUTPUT_DIR/${LABEL}_thread_${safe_name}.folded"

    thread_samples=$(awk '{s+=$NF} END {print s+0}' "$OUTPUT_DIR/${LABEL}_thread_${safe_name}.folded")
    if [[ "$thread_samples" -eq 0 ]]; then
        rm -f "$OUTPUT_DIR/${LABEL}_thread_${safe_name}.folded"
        continue
    fi

    "$FLAMEGRAPH_DIR/flamegraph.pl" \
        --title "$LABEL thread: $tid_label ($pct%)" \
        --subtitle "$thread_samples samples" \
        "$OUTPUT_DIR/${LABEL}_thread_${safe_name}.folded" \
        > "$OUTPUT_DIR/${LABEL}_thread_${safe_name}.svg"

    printf "  %-40s %8d  %5s%%  %s\n" "$tid_label" "$samples" "$pct" \
        "${LABEL}_thread_${safe_name}.svg"
done <<< "$THREAD_INFO"

# Step 4: Generate TSV summary
echo ""
echo "[4/4] Generating thread summary TSV..."

{
    echo "# Per-thread analysis: $LABEL"
    echo "# Source: $PERF_DATA"
    echo "# Total samples: $TOTAL_SAMPLES"
    echo "thread_label	samples	pct_of_total	top_function	top_function_pct"

    echo "$THREAD_INFO" | while IFS=$'\t' read -r samples tid_label; do
        pct=$(echo "scale=1; $samples * 100 / $TOTAL_SAMPLES" | bc 2>/dev/null)
        safe_name=$(echo "$tid_label" | tr '/' '_')
        folded_file="$OUTPUT_DIR/${LABEL}_thread_${safe_name}.folded"

        if [[ -f "$folded_file" ]]; then
            # Find the top self-time function in this thread
            top_info=$(awk '{
                n = split($0, parts, ";")
                # Last field after last space is the count
                stack_and_count = $0
                count = $NF
                # Get the leaf function (last semicolon-delimited element before the count)
                sub(/[[:space:]]+[0-9]+[[:space:]]*$/, "", stack_and_count)
                n2 = split(stack_and_count, a, ";")
                leaf = a[n2]
                s[leaf] += count
            }
            END {
                max_s = 0; max_f = "?"
                for (f in s) { if (s[f] > max_s) { max_s = s[f]; max_f = f } }
                total = 0; for (f in s) total += s[f]
                if (total > 0) printf "%s\t%.1f", max_f, max_s * 100.0 / total
                else printf "?\t0.0"
            }' "$folded_file")

            top_func=$(echo "$top_info" | cut -f1)
            top_pct=$(echo "$top_info" | cut -f2)
        else
            top_func="(no samples)"
            top_pct="0.0"
        fi

        printf "%s\t%d\t%s\t%s\t%s\n" "$tid_label" "$samples" "$pct" "$top_func" "$top_pct"
    done
} > "$OUTPUT_DIR/${LABEL}_threads.tsv"

echo ""
echo "=== Thread Summary ==="
tail -n +5 "$OUTPUT_DIR/${LABEL}_threads.tsv" \
    | awk -F'\t' '{printf "  %5s%%  %-35s  top: %s (%s%%)\n", $3, $1, $4, $5}'

echo ""
echo "=== Results ==="
echo "  TSV:    $OUTPUT_DIR/${LABEL}_threads.tsv"
echo "  Folded: $OUTPUT_DIR/${LABEL}_all_tids.folded"
echo "  SVGs:   $OUTPUT_DIR/${LABEL}_thread_*.svg"
