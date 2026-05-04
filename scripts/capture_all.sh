#!/usr/bin/env bash
# capture_all.sh — Run flamegraph captures for all worlds in a directory
#
# Usage: ./capture_all.sh <worlds_dir> [flags...]
#
# Flags:
#   --runtime-only   Skip loading captures
#   --loading-only   Skip runtime captures
#   --with-cache     Add cache-miss flamegraph captures
#   --with-offcpu    Add off-CPU flamegraph captures (requires tracepoint access)
#   --with-c2c       Add false sharing detection (perf c2c)
#   --with-sched     Add scheduler latency analysis (requires tracepoint access)
#   --full           Enable all extended analyses (cache + offcpu + c2c + sched)
#
# Each .sdf file in <worlds_dir> is captured as a headless runtime + loading
# flamegraph. The label is derived from the filename (e.g., jetty.sdf → jetty).
#
# For sensor worlds that need subscribers, create a companion file
# <world>.topics with one topic per line (e.g., gpu_lidar_sensor.topics).
#
# Prerequisites:
#   - Workspace built with ENABLE_PROFILER=OFF, RelWithDebInfo, -fno-omit-frame-pointer
#   - sudo sysctl kernel.perf_event_paranoid=1
#   - Assets pre-cached (run each world once beforehand)
#   - For --with-offcpu/--with-sched: sudo mount -o remount,mode=755 /sys/kernel/tracing/

set -eo pipefail

WORLDS_DIR="${1:?Usage: $0 <worlds_dir> [--runtime-only] [--loading-only]}"
shift

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse flags
DO_RUNTIME=true
DO_LOADING=true
DO_CACHE=false
DO_OFFCPU=false
DO_C2C=false
DO_SCHED=false
for arg in "$@"; do
    case "$arg" in
        --runtime-only) DO_LOADING=false ;;
        --loading-only) DO_RUNTIME=false ;;
        --with-cache)   DO_CACHE=true ;;
        --with-offcpu)  DO_OFFCPU=true ;;
        --with-c2c)     DO_C2C=true ;;
        --with-sched)   DO_SCHED=true ;;
        --full)         DO_CACHE=true; DO_OFFCPU=true; DO_C2C=true; DO_SCHED=true ;;
    esac
done

DURATION=30
CACHE_DURATION=30
OFFCPU_DURATION=10
C2C_DURATION=5
SCHED_DURATION=10

echo "============================================"
echo "  Gazebo Performance Profiling"
echo "============================================"
echo "  Worlds dir: $WORLDS_DIR"
echo "  Duration:   ${DURATION}s per runtime capture"
echo "  Runtime:    $DO_RUNTIME"
echo "  Loading:    $DO_LOADING"
echo "  Cache:      $DO_CACHE"
echo "  Off-CPU:    $DO_OFFCPU"
echo "  C2C:        $DO_C2C"
echo "  Sched:      $DO_SCHED"
echo ""

WORLDS_DIR="$(cd "$WORLDS_DIR" && pwd)"
COUNT=0

for world in "$WORLDS_DIR"/*.sdf; do
    [ -f "$world" ] || continue

    label=$(basename "$world" .sdf)
    topics_file="${world%.sdf}.topics"

    # Read sensor topics from companion file if it exists
    topics=()
    if [ -f "$topics_file" ]; then
        while IFS= read -r topic; do
            [ -n "$topic" ] && topics+=("$topic")
        done < "$topics_file"
        mode="headless-rendering"
    else
        mode="headless"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $label"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if $DO_RUNTIME; then
        echo ""
        echo "--- Runtime capture ---"
        "$SCRIPT_DIR/gz_flamegraph.sh" "$world" "$label" "$DURATION" "$mode" "${topics[@]}"
    fi

    if $DO_LOADING; then
        echo ""
        echo "--- Loading capture ---"
        "$SCRIPT_DIR/gz_loading_flamegraph.sh" "$world" "$label"
    fi

    if $DO_CACHE && $DO_RUNTIME; then
        echo ""
        echo "--- Cache-miss runtime capture ---"
        "$SCRIPT_DIR/gz_cache_flamegraph.sh" --runtime "$world" "${label}" "$CACHE_DURATION" || echo "  (cache runtime capture failed)"
    fi

    if $DO_CACHE && $DO_LOADING; then
        echo ""
        echo "--- Cache-miss loading capture ---"
        "$SCRIPT_DIR/gz_cache_flamegraph.sh" --loading "$world" "${label}" || echo "  (cache loading capture failed)"
    fi

    if $DO_OFFCPU; then
        echo ""
        echo "--- Off-CPU capture ---"
        "$SCRIPT_DIR/gz_offcpu_flamegraph.sh" "$world" "$label" "$OFFCPU_DURATION" "$mode" "${topics[@]}" || echo "  (off-CPU capture failed — tracepoint access may be needed)"
    fi

    if $DO_C2C; then
        echo ""
        echo "--- False sharing capture ---"
        "$SCRIPT_DIR/gz_false_sharing.sh" --runtime "$world" "$label" "$C2C_DURATION" || echo "  (c2c capture failed)"
    fi

    if $DO_SCHED; then
        echo ""
        echo "--- Scheduler analysis ---"
        "$SCRIPT_DIR/gz_sched_analysis.sh" "$world" "$label" "$SCHED_DURATION" || echo "  (sched analysis failed — tracepoint access may be needed)"
    fi

    COUNT=$((COUNT + 1))
done

# ---- Summary ----

echo ""
echo "============================================"
echo "  $COUNT worlds captured"
echo "============================================"
