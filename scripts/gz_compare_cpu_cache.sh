#!/usr/bin/env bash
# gz_compare_cpu_cache.sh — Compare CPU time vs cache-miss attribution
#
# Usage: ./gz_compare_cpu_cache.sh <cpu.folded> <cachemiss.folded>
#
# Produces a side-by-side comparison showing which Gazebo functions are
# cache-hostile (more cache misses than their CPU share) vs algorithmically
# wasteful (high CPU but proportionally fewer cache misses).

set +o pipefail

CPU_FOLDED="${1:?Usage: $0 <cpu.folded> <cachemiss.folded>}"
CACHE_FOLDED="${2:?Usage: $0 <cpu.folded> <cachemiss.folded>}"

if [[ ! -f "$CPU_FOLDED" || ! -f "$CACHE_FOLDED" ]]; then
    echo "ERROR: File not found" >&2
    exit 1
fi

LABEL=$(basename "$CPU_FOLDED" .folded)

# Gazebo pattern for attribution
GZ_MATCH='gz::sim::|gz::physics::dartsim::|gz::rendering::|gz::common::|gz::transport::|gz::sensors::|SimulationRunner::|SimulationFeatures::|gz::sim::v11::systems::|gz::sim::v11::detail::|ServerPrivate::'

# Extract inclusive time for Gazebo functions from a folded file
extract_gz_inclusive() {
    local folded="$1"
    awk '{
        n = split($1, a, ";")
        samples = $NF
        seen = ""
        for (i = 1; i <= n; i++) {
            func = a[i]
            if (index(seen, "|" func "|") > 0) continue
            seen = seen "|" func "|"
            printf "%s\t%d\n", func, samples
        }
    }' "$folded" \
        | awk -F'\t' '{s[$1]+=$2} END {for(k in s) printf "%d\t%s\n",s[k],k}' \
        | grep -E "$GZ_MATCH" \
        | grep -v 'gz-sim-main' \
        | sort -rn
}

CPU_TOTAL=$(awk '{s+=$NF} END {print s}' "$CPU_FOLDED")
CACHE_TOTAL=$(awk '{s+=$NF} END {print s}' "$CACHE_FOLDED")

echo "============================================"
echo "  CPU vs Cache-Miss Comparison: $LABEL"
echo "============================================"
echo "  CPU total:        $CPU_TOTAL"
echo "  Cache-miss total: $CACHE_TOTAL"
echo ""
echo "  'Cache ratio' = cache-miss% / cpu-time%"
echo "    > 1.0 = cache-hostile (more cache misses than CPU share)"
echo "    < 1.0 = cache-friendly (fewer cache misses than CPU share)"
echo "    = 1.0 = neutral"
echo ""

# Build associative data: function -> cpu%, cache%
CPU_DATA=$(extract_gz_inclusive "$CPU_FOLDED" | head -15)
CACHE_DATA=$(extract_gz_inclusive "$CACHE_FOLDED" | head -30)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "%-45s %8s %8s %8s\n" "Gazebo Function" "CPU %" "Cache %" "Ratio"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# For each top CPU function, find its cache-miss %
echo "$CPU_DATA" | while IFS=$'\t' read -r cpu_samples func; do
    cpu_pct=$(echo "scale=1; $cpu_samples * 100 / $CPU_TOTAL" | bc 2>/dev/null)

    # Find this function in cache data
    cache_samples=$(echo "$CACHE_DATA" | grep -F "$func" | head -1 | cut -f1)
    if [[ -n "$cache_samples" && "$cache_samples" -gt 0 ]]; then
        cache_pct=$(echo "scale=1; $cache_samples * 100 / $CACHE_TOTAL" | bc 2>/dev/null)
        if [[ "$cpu_pct" != "0" && "$cpu_pct" != ".0" ]]; then
            ratio=$(echo "scale=1; $cache_pct / $cpu_pct" | bc 2>/dev/null)
        else
            ratio="N/A"
        fi
    else
        cache_pct="0.0"
        ratio="0.0"
    fi

    # Truncate long names
    display_func="$func"
    if [[ ${#display_func} -gt 44 ]]; then
        idx=$(echo "$display_func" | grep -b -o '<' | head -1 | cut -d: -f1)
        if [[ -n "$idx" && "$idx" -gt 0 ]]; then
            display_func="${display_func:0:$idx}<...>"
        else
            display_func="${display_func:0:41}..."
        fi
    fi

    # Mark cache-hostile functions
    marker=""
    if echo "$ratio" | grep -qE '^[1-9]|^[0-9]+\.[5-9]'; then
        if [[ $(echo "$ratio > 1.3" | bc 2>/dev/null) == "1" ]]; then
            marker=" ← CACHE-HOSTILE"
        fi
    fi
    if [[ $(echo "$ratio < 0.7" | bc 2>/dev/null) == "1" && "$cpu_pct" != "0" && "$cpu_pct" != ".0" ]]; then
        marker=" ← cache-friendly"
    fi

    printf "%-45s %7s%% %7s%% %7s%s\n" "$display_func" "$cpu_pct" "$cache_pct" "$ratio" "$marker"
done

echo ""
echo "============================================"
echo "  Interpretation"
echo "============================================"
echo "  CACHE-HOSTILE (ratio > 1.3): The function causes more cache"
echo "    misses than its CPU share. Fix needs better data layout"
echo "    (contiguous storage, fewer pointer chases)."
echo ""
echo "  cache-friendly (ratio < 0.7): The function's cost is mostly"
echo "    algorithmic, not memory-bound. Fix is to reduce work"
echo "    (skip calls, use cached results)."
echo ""
echo "  neutral (ratio ~1.0): Cache behavior matches CPU share."
