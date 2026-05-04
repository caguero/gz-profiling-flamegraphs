#!/usr/bin/env bash
# gz_summary.sh — Unified profiling summary combining all analysis dimensions
#
# Usage: ./gz_summary.sh <captures_dir> <label>
#
# Combines evidence from multiple profiling analyses into a single ranked
# list of optimization targets. Each function receives a composite score
# (0-100) based on:
#
#   CPU time (0-40)     — from runtime .folded files
#   Cache hostility     — from cache comparison (cache ratio)
#   Off-CPU blocking    — from off-CPU .tsv files
#   False sharing       — from c2c .tsv files
#   Scheduler impact    — from sched .tsv files
#
# Works with whatever dimensions are available. Missing dimensions reduce
# the maximum possible score but don't prevent ranking.
#
# Outputs:
#   ${LABEL}_summary.tsv    Ranked optimization targets with per-dimension evidence
#   ${LABEL}_summary.txt    Human-readable formatted summary

set +o pipefail

CAPTURES_DIR="${1:?Usage: $0 <captures_dir> <label> [cache_label]}"
LABEL="${2:?Usage: $0 <captures_dir> <label> [cache_label]}"
CACHE_LABEL="${3:-$LABEL}"  # Cache files may use a different naming convention

OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/captures/summary}"

mkdir -p "$OUTPUT_DIR"

# Gazebo namespace pattern (same as gz_hotspots.sh)
GZ_MATCH='gz::sim::|gz::physics::dartsim::|gz::rendering::|gz::common::|gz::math::|gz::transport::|gz::plugin::|gz::msgs::|gz::sensors::|SimulationRunner::|SimulationFeatures::|gz::sim::v11::systems::|gz::sim::v11::detail::|gz::sim::v11::Entity|stbi__|gz::common::Image|SdfModelSerializer|ServerPrivate::DownloadAssets|ServerPrivate::LoadSdfRoot|pybind11::initialize'

echo "=== Unified Profiling Summary: $LABEL ==="
echo ""

# ─── Detect available data sources ───

DIMENSIONS=""
CPU_FOLDED=""
CACHE_FOLDED=""
OFFCPU_TSV=""
C2C_TSV=""
SCHED_TSV=""
THREADS_TSV=""

# CPU: look for runtime folded files
for f in "$CAPTURES_DIR"/runtime/${LABEL}*.folded "$CAPTURES_DIR"/${LABEL}*.folded; do
    if [[ -f "$f" && ! "$f" =~ _loading|_cachemiss|_offcpu|_diff|_all_tids ]]; then
        CPU_FOLDED="$f"
        DIMENSIONS="${DIMENSIONS:+$DIMENSIONS,}cpu"
        break
    fi
done

# Cache: look for cache-miss folded file (may use different label)
for f in "$CAPTURES_DIR"/cache/${LABEL}*cachemiss.folded \
         "$CAPTURES_DIR"/cache/${CACHE_LABEL}*cachemiss.folded \
         "$CAPTURES_DIR"/${LABEL}*cachemiss.folded \
         "$CAPTURES_DIR"/${CACHE_LABEL}*cachemiss.folded; do
    if [[ -f "$f" ]]; then
        CACHE_FOLDED="$f"
        DIMENSIONS="${DIMENSIONS:+$DIMENSIONS,}cache"
        break
    fi
done

# Off-CPU: look for off-CPU TSV
for f in "$CAPTURES_DIR"/offcpu/${LABEL}*offcpu.tsv; do
    if [[ -f "$f" ]]; then
        OFFCPU_TSV="$f"
        DIMENSIONS="${DIMENSIONS:+$DIMENSIONS,}offcpu"
        break
    fi
done

# False sharing: look for c2c TSV
for f in "$CAPTURES_DIR"/c2c/${LABEL}*c2c.tsv; do
    if [[ -f "$f" ]]; then
        C2C_TSV="$f"
        DIMENSIONS="${DIMENSIONS:+$DIMENSIONS,}c2c"
        break
    fi
done

# Scheduler: look for sched TSV
for f in "$CAPTURES_DIR"/sched/${LABEL}*sched.tsv; do
    if [[ -f "$f" ]]; then
        SCHED_TSV="$f"
        DIMENSIONS="${DIMENSIONS:+$DIMENSIONS,}sched"
        break
    fi
done

# Threads: look for thread TSV
for f in "$CAPTURES_DIR"/threads/${LABEL}*threads.tsv; do
    if [[ -f "$f" ]]; then
        THREADS_TSV="$f"
        break
    fi
done

echo "  Data sources detected:"
[[ -n "$CPU_FOLDED" ]]   && echo "    CPU:     $CPU_FOLDED"
[[ -n "$CACHE_FOLDED" ]] && echo "    Cache:   $CACHE_FOLDED"
[[ -n "$OFFCPU_TSV" ]]   && echo "    Off-CPU: $OFFCPU_TSV"
[[ -n "$C2C_TSV" ]]      && echo "    C2C:     $C2C_TSV"
[[ -n "$SCHED_TSV" ]]    && echo "    Sched:   $SCHED_TSV"
[[ -n "$THREADS_TSV" ]]  && echo "    Threads: $THREADS_TSV"
echo ""

if [[ -z "$CPU_FOLDED" ]]; then
    echo "ERROR: No CPU folded file found for label '$LABEL' in $CAPTURES_DIR" >&2
    echo "  Expected: $CAPTURES_DIR/runtime/${LABEL}*.folded" >&2
    exit 1
fi

# ─── Extract per-function metrics from each source ───

# Temp files for intermediate data
TMP_CPU=$(mktemp)
TMP_CACHE=$(mktemp)
TMP_OFFCPU=$(mktemp)
TMP_C2C=$(mktemp)
TMP_SCHED=$(mktemp)
trap "rm -f $TMP_CPU $TMP_CACHE $TMP_OFFCPU $TMP_C2C $TMP_SCHED" EXIT

# CPU: extract Gazebo functions with inclusive CPU %
CPU_TOTAL=$(awk '{s+=$NF} END {print s}' "$CPU_FOLDED")

awk -v total="$CPU_TOTAL" '{
    count = $NF
    stack = $0
    sub(/[[:space:]]+[0-9]+[[:space:]]*$/, "", stack)

    n = split(stack, a, ";")
    seen = ""
    for (i = 1; i <= n; i++) {
        func = a[i]
        if (index(seen, "|" func "|") > 0) continue
        seen = seen "|" func "|"
        inclusive[func] += count
    }
}
END {
    if (total == 0) total = 1
    for (f in inclusive) {
        pct = inclusive[f] * 100.0 / total
        if (pct >= 0.5) printf "%s\t%.1f\n", f, pct
    }
}' "$CPU_FOLDED" \
    | grep -E "$GZ_MATCH" \
    | grep -v 'gz-sim-main' \
    > "$TMP_CPU"

echo "  CPU: $(wc -l < "$TMP_CPU") Gazebo functions above 0.5%"

# Cache: compute cache ratio per function (if available)
if [[ -n "$CACHE_FOLDED" ]]; then
    CACHE_TOTAL=$(awk '{s+=$NF} END {print s}' "$CACHE_FOLDED")

    # Extract inclusive cache-miss % for Gazebo functions
    awk -v total="$CACHE_TOTAL" '{
        count = $NF
        stack = $0
        sub(/[[:space:]]+[0-9]+[[:space:]]*$/, "", stack)

        n = split(stack, a, ";")
        seen = ""
        for (i = 1; i <= n; i++) {
            func = a[i]
            if (index(seen, "|" func "|") > 0) continue
            seen = seen "|" func "|"
            inclusive[func] += count
        }
    }
    END {
        if (total == 0) total = 1
        for (f in inclusive) {
            pct = inclusive[f] * 100.0 / total
            if (pct >= 0.1) printf "%s\t%.1f\n", f, pct
        }
    }' "$CACHE_FOLDED" \
        | grep -E "$GZ_MATCH" \
        | grep -v 'gz-sim-main' \
        > "$TMP_CACHE"

    echo "  Cache: $(wc -l < "$TMP_CACHE") functions with cache data"
fi

# Off-CPU: read TSV directly (function_name\toffcpu_us\toffcpu_pct)
if [[ -n "$OFFCPU_TSV" ]]; then
    grep -v '^#' "$OFFCPU_TSV" | grep -v '^function_name' \
        | grep -E "$GZ_MATCH" \
        > "$TMP_OFFCPU"
    echo "  Off-CPU: $(wc -l < "$TMP_OFFCPU") Gazebo functions"
fi

# C2C: read TSV directly (symbol\tdso\ttotal_hitm\thitm_pct)
if [[ -n "$C2C_TSV" ]]; then
    grep -v '^#' "$C2C_TSV" | grep -v '^symbol' \
        | grep -E "$GZ_MATCH" \
        > "$TMP_C2C"
    echo "  C2C: $(wc -l < "$TMP_C2C") Gazebo symbols with HITM"
fi

# Sched: read TSV for flagged threads
if [[ -n "$SCHED_TSV" ]]; then
    grep -v '^#' "$SCHED_TSV" | grep -v '^thread_name' \
        | awk -F'\t' '$7 == "YES"' \
        > "$TMP_SCHED"
    echo "  Sched: $(wc -l < "$TMP_SCHED") threads with high delay"
fi

echo ""

# ─── Combine all dimensions and score ───

echo "  Computing composite scores..."

awk -F'\t' -v dimensions="$DIMENSIONS" \
    -v cache_file="$TMP_CACHE" \
    -v offcpu_file="$TMP_OFFCPU" \
    -v c2c_file="$TMP_C2C" \
    -v sched_file="$TMP_SCHED" \
    -v cpu_total="$CPU_TOTAL" \
    -v cache_total="${CACHE_TOTAL:-0}" '
BEGIN {
    OFS = "\t"

    # Load cache data: function -> cache_pct
    if (cache_file != "") {
        while ((getline line < cache_file) > 0) {
            split(line, f, "\t")
            cache_pct[f[1]] = f[2] + 0
        }
        close(cache_file)
    }

    # Load off-CPU data: function -> offcpu_us, offcpu_pct
    if (offcpu_file != "") {
        while ((getline line < offcpu_file) > 0) {
            split(line, f, "\t")
            offcpu_us[f[1]] = f[2] + 0
            offcpu_pct[f[1]] = f[3] + 0
        }
        close(offcpu_file)
    }

    # Load c2c data: symbol -> hitm_pct
    if (c2c_file != "") {
        while ((getline line < c2c_file) > 0) {
            split(line, f, "\t")
            c2c_pct[f[1]] = f[4] + 0
            c2c_hitm[f[1]] = f[3] + 0
        }
        close(c2c_file)
    }

    # Load sched data: check if any threads are flagged
    sched_flagged = 0
    if (sched_file != "") {
        while ((getline line < sched_file) > 0) {
            sched_flagged++
        }
        close(sched_file)
    }
}

# Process CPU data (function\tcpu_pct)
{
    func = $1
    cpu = $2 + 0

    # ── Score: CPU (0-40) ──
    if (cpu >= 10) cpu_score = 40
    else if (cpu >= 5) cpu_score = 25
    else if (cpu >= 1) cpu_score = 10
    else cpu_score = 5

    # ── Score: Cache hostility (0-20) ──
    cache_score = 0
    cache_ratio = "-"
    if (func in cache_pct && cpu > 0) {
        cache_ratio = sprintf("%.1f", cache_pct[func] / cpu)
        r = cache_ratio + 0
        if (r > 2.0) cache_score = 20
        else if (r > 1.3) cache_score = 10
    }

    # ── Score: Off-CPU (0-15) ──
    offcpu_score = 0
    offcpu_val = "-"
    if (func in offcpu_pct) {
        offcpu_val = offcpu_us[func]
        op = offcpu_pct[func]
        if (op >= 10) offcpu_score = 15
        else if (op >= 5) offcpu_score = 8
        else if (op >= 1) offcpu_score = 3
    }

    # ── Score: False sharing (0-15) ──
    c2c_score = 0
    hitm_val = "-"
    if (func in c2c_pct) {
        hitm_val = sprintf("%.1f", c2c_pct[func])
        hp = c2c_pct[func]
        if (hp >= 5) c2c_score = 15
        else if (hp >= 1) c2c_score = 8
        else c2c_score = 3
    }

    # ── Score: Scheduler (0-10) ──
    sched_score = 0
    sched_val = "NO"
    if (sched_flagged > 0) {
        # If there are flagged threads, any CPU-hot function gets partial credit
        if (cpu >= 10) { sched_score = 10; sched_val = "YES" }
    }

    # ── Composite ──
    total_score = cpu_score + cache_score + offcpu_score + c2c_score + sched_score

    # Evidence sources
    sources = "cpu"
    if (cache_ratio != "-") sources = sources ",cache"
    if (offcpu_val != "-") sources = sources ",offcpu"
    if (hitm_val != "-") sources = sources ",c2c"
    if (sched_val == "YES") sources = sources ",sched"

    # Store for sorting
    printf "%d\t%s\t%.1f\t%s\t%s\t%s\t%s\t%s\n", \
        total_score, func, cpu, cache_ratio, offcpu_val, hitm_val, sched_val, sources
}
' "$TMP_CPU" \
    | sort -t$'\t' -k1 -rn \
    > "$OUTPUT_DIR/${LABEL}_summary_raw.tmp"

# ─── Generate final TSV ───

{
    echo "# Unified profiling summary: $LABEL"
    echo "# Date: $(date '+%Y-%m-%d %H:%M')"
    echo "# Dimensions available: $DIMENSIONS"
    echo "# Scoring: cpu(0-40) + cache(0-20) + offcpu(0-15) + c2c(0-15) + sched(0-10) = 0-100"
    echo "rank	function_name	score	cpu_pct	cache_ratio	offcpu_us	hitm_pct	sched_flag	evidence_sources"

    rank=0
    while IFS=$'\t' read -r score func cpu cache offcpu hitm sched sources; do
        rank=$((rank + 1))
        printf "%d\t%s\t%d\t%s\t%s\t%s\t%s\t%s\n" \
            "$rank" "$func" "$score" "$cpu" "$cache" "$offcpu" "$hitm" "$sources"
    done < "$OUTPUT_DIR/${LABEL}_summary_raw.tmp"
} > "$OUTPUT_DIR/${LABEL}_summary.tsv"

rm -f "$OUTPUT_DIR/${LABEL}_summary_raw.tmp"

# ─── Generate human-readable summary ───

{
    echo "============================================"
    echo "  Unified Profiling Summary: $LABEL"
    echo "============================================"
    echo "  Dimensions: $DIMENSIONS"
    echo "  CPU total:  $CPU_TOTAL samples"
    [[ -n "$CACHE_FOLDED" ]] && echo "  Cache total: $CACHE_TOTAL samples"
    echo ""
    printf "  %-4s %-50s %5s %6s %6s %6s %5s %s\n" \
        "Rank" "Function" "Score" "CPU%" "Cache" "HITM%" "Sched" "Sources"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    head -20 "$OUTPUT_DIR/${LABEL}_summary_raw.tmp" 2>/dev/null \
        || tail -n +6 "$OUTPUT_DIR/${LABEL}_summary.tsv" | head -20

} > "$OUTPUT_DIR/${LABEL}_summary.txt" 2>/dev/null

# Pretty-print to stdout
echo ""
echo "=== Top 15 Optimization Targets ==="
echo ""
printf "  %-4s %-50s %5s %6s %6s %6s %s\n" \
    "Rank" "Function" "Score" "CPU%" "Cache" "HITM%" "Sources"
echo "  ────────────────────────────────────────────────────────────────────────────────────"

rank=0
tail -n +6 "$OUTPUT_DIR/${LABEL}_summary.tsv" | head -15 \
    | while IFS=$'\t' read -r rnk func score cpu cache offcpu hitm sources; do
        # Truncate long function names
        display="$func"
        if [[ ${#display} -gt 49 ]]; then
            idx=$(echo "$display" | grep -b -o '<' | head -1 | cut -d: -f1)
            if [[ -n "$idx" && "$idx" -gt 0 ]]; then
                display="${display:0:$idx}<...>"
            else
                display="${display:0:46}..."
            fi
        fi
        printf "  %-4s %-50s %5s %6s %6s %6s %s\n" \
            "$rnk" "$display" "$score" "$cpu" "$cache" "$hitm" "$sources"
    done

echo ""
echo "=== Results ==="
echo "  TSV:  $OUTPUT_DIR/${LABEL}_summary.tsv"
echo "  Text: $OUTPUT_DIR/${LABEL}_summary.txt"
