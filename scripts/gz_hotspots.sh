#!/usr/bin/env bash
# gz_hotspots.sh — Extract Gazebo-owned hotspots from a flamegraph .folded file
#
# Usage: ./gz_hotspots.sh <file.folded> [top_n]
#
# Analyzes a collapsed stack file and reports:
#   1. Top Gazebo-owned functions by self-time (leaf functions in gz:: namespace)
#   2. Top Gazebo-owned functions by inclusive time (anywhere in the stack)
#   3. Top external functions for context
#   4. Gazebo callers of hot external functions (attribution)
#
# Gazebo-owned: functions matching gz::sim::, gz::physics::, gz::rendering::,
# gz::common::, gz::math::, gz::transport::, gz::plugin::, gz::msgs::,
# SimulationRunner, SimulationFeatures, SceneBroadcaster, SceneManager,
# RenderUtil, BaseView, Barrier, stbi_* (vendored in gz-common),
# Image:: (gz::common::Image)

set -eo pipefail

FOLDED="${1:?Usage: $0 <file.folded> [top_n]}"
TOP_N="${2:-15}"

if [[ ! -f "$FOLDED" ]]; then
    echo "ERROR: File not found: $FOLDED" >&2
    exit 1
fi

TOTAL=$(awk '{s+=$NF} END {print s}' "$FOLDED")
LABEL=$(basename "$FOLDED" .folded)

# Gazebo namespace pattern (regex for matching leaf functions)
GZ_PATTERN='gz::|SimulationRunner|SimulationFeatures|SceneBroadcaster|SceneManager|RenderUtil|BaseView|Barrier::Wait|BitmaskContact|OdeCollisionObject|stbi__|Image::|SdfModelSerializer|DownloadAssets|ProcessRecreate|pybind11::initialize'

# External pattern (things we know are NOT Gazebo)
EXT_PATTERN='dart::|dxHash|Ogre::|libnvidia|libdart|\[unknown\]|\[libdart|pthread_|_int_free|_int_malloc|malloc_consolidate|cfree|__memset|__memmove|operator new|operator delete|clone3|start_thread|\[vdso\]|\[libstdc\+\+|BoxedLcp|ConstraintSolver|ConstrainedGroup|BodyNode::|Frame::|DegreeOfFreedom::|Skeleton::|CollisionGroup::|CollisionObject::|ContactConstraint'

echo "============================================"
echo "  Gazebo Hotspot Analysis: $LABEL"
echo "============================================"
echo "  Total samples: $TOTAL"
echo ""

# ---------------------------------------------------------------
# 1. Gazebo-owned functions by SELF-TIME (leaf)
# ---------------------------------------------------------------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Gazebo-owned functions (self-time)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

awk '{ n=split($1,a,";"); printf "%s\t%d\n", a[n], $NF }' "$FOLDED" \
    | awk -F'\t' '{s[$1]+=$2} END {for(k in s) printf "%d\t%s\n",s[k],k}' \
    | grep -E "$GZ_PATTERN" \
    | sort -rn \
    | head -"$TOP_N" \
    | awk -F'\t' -v total="$TOTAL" '{
        pct = $1 * 100.0 / total;
        printf "%6.1f%%  %s\n", pct, $2
    }'

echo ""

# ---------------------------------------------------------------
# 2. Gazebo-owned functions by INCLUSIVE TIME (anywhere in stack)
# ---------------------------------------------------------------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Gazebo-owned functions (inclusive time)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# For each stack, find all unique gz:: functions and attribute the full sample to each
awk '{
    n = split($1, a, ";")
    samples = $NF
    seen_func = ""
    for (i = 1; i <= n; i++) {
        func = a[i]
        # Deduplicate within same stack
        if (index(seen_func, "|" func "|") > 0) continue
        seen_func = seen_func "|" func "|"
        printf "%s\t%d\n", func, samples
    }
}' "$FOLDED" \
    | awk -F'\t' '{s[$1]+=$2} END {for(k in s) printf "%d\t%s\n",s[k],k}' \
    | grep -E "$GZ_PATTERN" \
    | grep -v -E '^[0-9]+\tgz-sim-main$' \
    | sort -rn \
    | head -"$TOP_N" \
    | awk -F'\t' -v total="$TOTAL" '{
        pct = $1 * 100.0 / total;
        printf "%6.1f%%  %s\n", pct, $2
    }'

echo ""

# ---------------------------------------------------------------
# 3. External functions for context (self-time)
# ---------------------------------------------------------------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  External functions (context, self-time)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

awk '{ n=split($1,a,";"); printf "%s\t%d\n", a[n], $NF }' "$FOLDED" \
    | awk -F'\t' '{s[$1]+=$2} END {for(k in s) printf "%d\t%s\n",s[k],k}' \
    | grep -E "$EXT_PATTERN" \
    | sort -rn \
    | head -"$TOP_N" \
    | awk -F'\t' -v total="$TOTAL" '{
        pct = $1 * 100.0 / total;
        printf "%6.1f%%  %s\n", pct, $2
    }'

echo ""

# ---------------------------------------------------------------
# 4. Attribution: nearest Gazebo caller of hot external functions
# ---------------------------------------------------------------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Attribution: Gazebo callers of external hotspots"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# For each stack, find the leaf (external), then walk up to find the nearest gz:: caller
awk -v gz_pat="$GZ_PATTERN" '{
    n = split($1, a, ";")
    samples = $NF
    leaf = a[n]

    # Find nearest gz:: ancestor
    gz_caller = ""
    for (i = n; i >= 1; i--) {
        if (match(a[i], /gz::|SimulationRunner|SimulationFeatures|SceneBroadcaster|RenderUtil|ProcessRecreate|DownloadAssets/)) {
            gz_caller = a[i]
            break
        }
    }

    if (gz_caller != "" && gz_caller != leaf) {
        printf "%s → %s\t%d\n", gz_caller, leaf, samples
    }
}' "$FOLDED" \
    | awk -F'\t' '{s[$1]+=$2} END {for(k in s) printf "%d\t%s\n",s[k],k}' \
    | sort -rn \
    | head -"$TOP_N" \
    | awk -F'\t' -v total="$TOTAL" '{
        pct = $1 * 100.0 / total;
        printf "%6.1f%%  %s\n", pct, $2
    }'

echo ""
echo "============================================"
echo "  Summary"
echo "============================================"

# Calculate total Gazebo-owned self-time
GZ_TOTAL=$(awk '{ n=split($1,a,";"); printf "%s\t%d\n", a[n], $NF }' "$FOLDED" \
    | awk -F'\t' '{s[$1]+=$2} END {for(k in s) printf "%d\t%s\n",s[k],k}' \
    | grep -E "$GZ_PATTERN" \
    | awk -F'\t' '{s+=$1} END {print s+0}')

EXT_TOTAL=$(awk '{ n=split($1,a,";"); printf "%s\t%d\n", a[n], $NF }' "$FOLDED" \
    | awk -F'\t' '{s[$1]+=$2} END {for(k in s) printf "%d\t%s\n",s[k],k}' \
    | grep -E "$EXT_PATTERN" \
    | awk -F'\t' '{s+=$1} END {print s+0}')

OTHER=$((TOTAL - GZ_TOTAL - EXT_TOTAL))

echo ""
printf "  Gazebo-owned:  %6.1f%%\n" "$(echo "$GZ_TOTAL * 100.0 / $TOTAL" | bc -l)"
printf "  External libs: %6.1f%%\n" "$(echo "$EXT_TOTAL * 100.0 / $TOTAL" | bc -l)"
printf "  Other/noise:   %6.1f%%\n" "$(echo "$OTHER * 100.0 / $TOTAL" | bc -l)"
