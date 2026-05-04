#!/usr/bin/env bash
# gz_analyze.sh — Run all post-capture analysis and produce a cross-world summary
#
# Usage: ./gz_analyze.sh [captures_dir]
#
# Runs hotspot analysis, per-thread flamegraphs, cache comparison, and
# per-world summary on existing captures, then merges all per-world results
# into a single cross-world ranked list of optimization targets.
#
# No simulation needed — works entirely on .folded and perf_*.data files.
#
# Outputs:
#   captures/runtime/${label}_hotspots.txt    Per-world hotspot analysis
#   captures/threads/${label}_threads.tsv     Per-thread CPU distribution
#   captures/summary/${label}_summary.tsv     Per-world composite scores
#   captures/summary/cross_world_summary.tsv  Cross-world ranked list (main output)

set +o pipefail

CAPTURES_DIR="${1:-$(pwd)/captures}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FLAMEGRAPH_DIR="${FLAMEGRAPH_DIR:-$(pwd)/FlameGraph}"

if [[ ! -d "$CAPTURES_DIR" ]]; then
    echo "ERROR: Captures directory not found: $CAPTURES_DIR" >&2
    echo "  Run ./scripts/capture_all.sh first." >&2
    exit 1
fi

# Find runtime folded files — these define our world list
RUNTIME_DIR="$CAPTURES_DIR/runtime"
if [[ ! -d "$RUNTIME_DIR" ]]; then
    # Try alternate layout (e.g., existing 2026-04-21/ structure)
    for candidate in "$CAPTURES_DIR" "$CAPTURES_DIR"/flamegraphs/runtime; do
        if ls "$candidate"/*.folded >/dev/null 2>&1; then
            RUNTIME_DIR="$candidate"
            break
        fi
    done
fi

FOLDED_FILES=()
for f in "$RUNTIME_DIR"/*.folded; do
    [[ -f "$f" ]] || continue
    # Skip non-runtime folded files
    base=$(basename "$f")
    [[ "$base" == *_loading* || "$base" == *_cachemiss* || "$base" == *_offcpu* || "$base" == *_diff* || "$base" == *_all_tids* || "$base" == *_thread_* || "$base" == *_hotspots* ]] && continue
    FOLDED_FILES+=("$f")
done

if [[ ${#FOLDED_FILES[@]} -eq 0 ]]; then
    echo "ERROR: No runtime .folded files found in $RUNTIME_DIR" >&2
    exit 1
fi

NUM_WORLDS=${#FOLDED_FILES[@]}

echo "============================================"
echo "  Gazebo Post-Capture Analysis"
echo "============================================"
echo "  Source:  $CAPTURES_DIR"
echo "  Worlds:  $NUM_WORLDS"
echo ""

mkdir -p "$CAPTURES_DIR/summary" "$CAPTURES_DIR/threads"

# ─── Step 1: Per-world hotspot analysis ───

echo "[1/5] Running hotspot analysis..."
for folded in "${FOLDED_FILES[@]}"; do
    label=$(basename "$folded" .folded)
    hotspot_file="$RUNTIME_DIR/${label}_hotspots.txt"
    if [[ ! -f "$hotspot_file" ]]; then
        echo "  $label"
        "$SCRIPT_DIR/gz_hotspots.sh" "$folded" 15 > "$hotspot_file" 2>/dev/null
    else
        echo "  $label (cached)"
    fi
done

# ─── Step 2: Per-thread analysis ───

echo "[2/5] Running per-thread analysis..."
for folded in "${FOLDED_FILES[@]}"; do
    label=$(basename "$folded" .folded)
    threads_tsv="$CAPTURES_DIR/threads/${label}_threads.tsv"
    if [[ -f "$threads_tsv" ]]; then
        echo "  $label (cached)"
        continue
    fi
    # Find matching perf_*.data file
    perf_data=""
    for candidate in \
        "$RUNTIME_DIR/perf_${label}.data" \
        "$(dirname "$RUNTIME_DIR")/runtime/perf_${label}.data" \
        "$(dirname "$RUNTIME_DIR")/flamegraphs/runtime/perf_${label}.data"; do
        if [[ -f "$candidate" ]]; then
            perf_data="$candidate"
            break
        fi
    done
    if [[ -n "$perf_data" ]]; then
        echo "  $label"
        OUTPUT_DIR="$CAPTURES_DIR/threads" \
            FLAMEGRAPH_DIR="$FLAMEGRAPH_DIR" \
            "$SCRIPT_DIR/gz_per_thread_flamegraph.sh" "$perf_data" "$label" > /dev/null 2>&1
    else
        echo "  $label (no perf_*.data — skipped)"
    fi
done

# ─── Step 3: Cache comparison ───

echo "[3/5] Running cache comparisons..."
CACHE_DIR=""
for candidate in "$CAPTURES_DIR/cache" "$(dirname "$RUNTIME_DIR")/cache"; do
    if ls "$candidate"/*cachemiss.folded >/dev/null 2>&1; then
        CACHE_DIR="$candidate"
        break
    fi
done

if [[ -n "$CACHE_DIR" ]]; then
    for folded in "${FOLDED_FILES[@]}"; do
        label=$(basename "$folded" .folded)
        # Find matching cache folded — try several naming patterns
        cache_folded=""
        for pattern in \
            "${CACHE_DIR}/${label}_cachemiss.folded" \
            "${CACHE_DIR}/${label}_rt_cachemiss.folded"; do
            if [[ -f "$pattern" ]]; then
                cache_folded="$pattern"
                break
            fi
        done
        # Fuzzy match: try progressively shorter substrings, prefer shortest match
        if [[ -z "$cache_folded" ]]; then
            for short in \
                "$(echo "$label" | sed 's/_shapes_/_/g; s/_headless\|_nonrendering//g')" \
                "$(echo "$label" | sed 's/_shapes_static/static/; s/_shapes_dynamic/dynamic/')" \
                "$(echo "$label" | sed 's/_shapes//; s/_headless\|_nonrendering\|_demo//g')" \
                "$(echo "$label" | cut -d_ -f1)"; do
                # Prefer shortest matching filename (exact > partial)
                best=""
                for f in "$CACHE_DIR"/"${short}"*rt_cachemiss.folded; do
                    [[ -f "$f" ]] || continue
                    if [[ -z "$best" || ${#f} -lt ${#best} ]]; then
                        best="$f"
                    fi
                done
                if [[ -n "$best" ]]; then
                    cache_folded="$best"
                    break
                fi
            done
        fi
        if [[ -n "$cache_folded" ]]; then
            echo "  $label ↔ $(basename "$cache_folded")"
        else
            echo "  $label (no cache data)"
        fi
    done
else
    echo "  No cache directory found — skipped"
fi

# ─── Step 4: Per-world summary ───

echo "[4/5] Running per-world summaries..."
WORLD_LABELS=()
for folded in "${FOLDED_FILES[@]}"; do
    label=$(basename "$folded" .folded)
    WORLD_LABELS+=("$label")
    summary_file="$CAPTURES_DIR/summary/${label}_summary.tsv"
    if [[ -f "$summary_file" ]]; then
        echo "  $label (cached)"
        continue
    fi

    # Find cache label for this world (prefer shortest match)
    cache_label="$label"
    if [[ -n "$CACHE_DIR" ]]; then
        for short in \
            "$label" \
            "$(echo "$label" | sed 's/_shapes_/_/g; s/_headless\|_nonrendering//g')" \
            "$(echo "$label" | sed 's/_shapes//; s/_headless\|_nonrendering\|_demo//g')" \
            "$(echo "$label" | cut -d_ -f1)"; do
            best=""
            for f in "$CACHE_DIR"/"${short}"*rt_cachemiss.folded; do
                [[ -f "$f" ]] || continue
                if [[ -z "$best" || ${#f} -lt ${#best} ]]; then
                    best="$f"
                fi
            done
            if [[ -n "$best" ]]; then
                cache_label=$(basename "$best" _rt_cachemiss.folded)
                break
            fi
        done
    fi

    echo "  $label (cache: $cache_label)"
    OUTPUT_DIR="$CAPTURES_DIR/summary" \
        "$SCRIPT_DIR/gz_summary.sh" "$(dirname "$RUNTIME_DIR")" "$label" "$cache_label" > /dev/null 2>&1 \
        || OUTPUT_DIR="$CAPTURES_DIR/summary" \
            "$SCRIPT_DIR/gz_summary.sh" "$CAPTURES_DIR" "$label" "$cache_label" > /dev/null 2>&1 \
        || echo "    (summary failed)"
done

# ─── Step 5: Cross-world merge ───

echo "[5/5] Merging cross-world summary..."

SUMMARY_FILES=()
for label in "${WORLD_LABELS[@]}"; do
    f="$CAPTURES_DIR/summary/${label}_summary.tsv"
    [[ -f "$f" ]] && SUMMARY_FILES+=("$f")
done

if [[ ${#SUMMARY_FILES[@]} -eq 0 ]]; then
    echo "  ERROR: No per-world summaries generated" >&2
    exit 1
fi

CROSS_WORLD="$CAPTURES_DIR/summary/cross_world_summary.tsv"

awk -F'\t' '
BEGIN {
    OFS = "\t"
}

# Read each summary file
FNR == 1 {
    # Extract world label from filename
    fname = FILENAME
    sub(/.*\//, "", fname)
    sub(/_summary\.tsv$/, "", fname)
    world = fname
    num_worlds++
    world_list = (world_list == "") ? world : world_list ", " world
}

# Skip comment and header lines
/^#/ || /^rank/ { next }

{
    func = $2
    score = $3 + 0
    cpu = $4 + 0
    cache = $5
    evidence = $8

    # Track per-function data across worlds
    if (score > max_score[func]) {
        max_score[func] = score
        worst_world[func] = world
        worst_cpu[func] = cpu
        worst_cache[func] = cache
    }
    count[func]++

    # Track CPU range
    if (!(func in min_cpu) || cpu < min_cpu[func]) min_cpu[func] = cpu
    if (cpu > max_cpu[func]) max_cpu[func] = cpu

    # Track cache range
    if (cache != "-" && cache != "") {
        c = cache + 0
        if (!(func in min_cache) || c < min_cache[func]) min_cache[func] = c
        if (c > max_cache[func]) max_cache[func] = c
        has_cache[func] = 1
    }

    # Merge evidence sources
    n = split(evidence, ev, ",")
    for (i = 1; i <= n; i++) {
        if (index(all_evidence[func], ev[i]) == 0) {
            all_evidence[func] = (all_evidence[func] == "") ? ev[i] : all_evidence[func] "," ev[i]
        }
    }
}

END {
    # Header
    print "# Cross-world profiling summary"
    print "# Worlds analyzed: " world_list
    print "# Date: " strftime("%Y-%m-%d %H:%M")
    print "# Ranked by max_score desc, then worlds_present desc"
    print "rank\tfunction_name\tmax_score\tworlds_present\tworst_world\tcpu_range\tcache_range\tevidence"

    # Collect into sortable array
    n = 0
    for (func in max_score) {
        n++
        funcs[n] = func
        sort_key[n] = sprintf("%04d %04d", max_score[func], count[func])
    }

    # Simple selection sort (awk has no built-in sort)
    for (i = 1; i <= n; i++) {
        max_idx = i
        for (j = i + 1; j <= n; j++) {
            if (sort_key[j] > sort_key[max_idx]) max_idx = j
        }
        if (max_idx != i) {
            tmp = funcs[i]; funcs[i] = funcs[max_idx]; funcs[max_idx] = tmp
            tmp = sort_key[i]; sort_key[i] = sort_key[max_idx]; sort_key[max_idx] = tmp
        }
    }

    for (i = 1; i <= n; i++) {
        func = funcs[i]
        cpu_range = sprintf("%.1f-%.1f%%", min_cpu[func], max_cpu[func])
        if (has_cache[func]) {
            cache_range = sprintf("%.1f-%.1f", min_cache[func], max_cache[func])
        } else {
            cache_range = "-"
        }
        worst_info = sprintf("%s (%.1f%%)", worst_world[func], worst_cpu[func])
        printf "%d\t%s\t%d\t%d/%d\t%s\t%s\t%s\t%s\n", \
            i, func, max_score[func], count[func], num_worlds, \
            worst_info, cpu_range, cache_range, all_evidence[func]
    }
}
' "${SUMMARY_FILES[@]}" > "$CROSS_WORLD"

# ─── Print results ───

echo ""
echo "============================================"
echo "  Cross-World Optimization Targets"
echo "============================================"

TOTAL_WORLDS=${#SUMMARY_FILES[@]}
echo "  Worlds analyzed: $TOTAL_WORLDS"
echo ""

printf "  %-4s %-45s %5s %7s %s\n" "Rank" "Function" "Score" "Worlds" "Worst Case"
echo "  ────────────────────────────────────────────────────────────────────────────"

tail -n +6 "$CROSS_WORLD" | head -15 \
    | while IFS=$'\t' read -r rank func score worlds worst cpu_range cache_range evidence; do
        # Truncate long function names
        display="$func"
        if [[ ${#display} -gt 44 ]]; then
            idx=$(echo "$display" | grep -b -o '<' | head -1 | cut -d: -f1)
            if [[ -n "$idx" && "$idx" -gt 0 ]]; then
                display="${display:0:$idx}<...>"
            else
                display="${display:0:41}..."
            fi
        fi
        printf "  %-4s %-45s %5s %7s %s\n" "$rank" "$display" "$score" "$worlds" "$worst"
    done

echo ""
echo "  Full results:  $CROSS_WORLD"
echo "  Per-world:     $CAPTURES_DIR/summary/*_summary.tsv"
echo "  Hotspots:      $RUNTIME_DIR/*_hotspots.txt"
echo "  Per-thread:    $CAPTURES_DIR/threads/*_threads.tsv"
