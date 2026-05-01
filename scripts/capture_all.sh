#!/usr/bin/env bash
# capture_all.sh — Run all flamegraph captures for the Gazebo profiling study
#
# Usage: ./capture_all.sh [--runtime-only] [--loading-only]
#
# Prerequisites:
#   - Workspace built with ENABLE_PROFILER=OFF, RelWithDebInfo, -fno-omit-frame-pointer
#   - sudo sysctl kernel.perf_event_paranoid=1
#   - Assets pre-cached (run each world once beforehand)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$WS_DIR/src"
PROF_DIR="$WS_DIR/profiling"

# Source workspace
source "$WS_DIR/install/setup.bash"
export GZ_CONFIG_PATH="$WS_DIR/install/share/gz:${GZ_CONFIG_PATH:-}"
export GZ_SIM_RESOURCE_PATH="$HOME/jetty_demo/jetty_demo/models:${GZ_SIM_RESOURCE_PATH:-}"

# Parse flags
DO_RUNTIME=true
DO_LOADING=true
for arg in "$@"; do
    case "$arg" in
        --runtime-only) DO_LOADING=false ;;
        --loading-only) DO_RUNTIME=false ;;
    esac
done

DURATION=30

echo "============================================"
echo "  Gazebo Performance Profiling - Full Suite"
echo "============================================"
echo "  Workspace: $WS_DIR"
echo "  Duration:  ${DURATION}s per runtime capture"
echo "  Runtime:   $DO_RUNTIME"
echo "  Loading:   $DO_LOADING"
echo ""

# ---------------------------------------------------------------------------
# World definitions: label, sdf_path, run_mode, topics...
# ---------------------------------------------------------------------------

run_capture() {
    local label="$1" world="$2" mode="$3"
    shift 3
    local topics=("$@")

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
}

# ---- Static worlds (isolate Gazebo framework overhead) ----

run_capture \
    "3k_shapes_static" \
    "$PROF_DIR/worlds/3k_shapes_static.sdf" \
    "headless"

run_capture \
    "sensors_nonrendering" \
    "$PROF_DIR/worlds/sensors.sdf" \
    "headless"

run_capture \
    "jetty_gui_paused" \
    "$PROF_DIR/worlds/jetty.sdf" \
    "gui"

# ---- Dynamic worlds (full picture including physics) ----

run_capture \
    "3k_shapes_dynamic" \
    "$PROF_DIR/worlds/3k_shapes.sdf" \
    "headless"

run_capture \
    "jetty_headless" \
    "$PROF_DIR/worlds/jetty.sdf" \
    "headless"

# ---- Rendering + sensor worlds ----
# Note: sensor topics must be subscribed to force rendering pipeline to run.
# Topics are identified per-world. Adjust if sensor names differ.

run_capture \
    "gpu_lidar" \
    "$PROF_DIR/worlds/gpu_lidar_sensor.sdf" \
    "headless-rendering" \
    "/lidar"

run_capture \
    "sensors_demo" \
    "$PROF_DIR/worlds/sensors_demo.sdf" \
    "headless-rendering" \
    "/camera" "/depth_camera" "/rgbd_camera" "/thermal_camera" "/segmentation_camera" "/lidar"

# ---- Summary ----

echo ""
echo "============================================"
echo "  All captures complete!"
echo "============================================"
echo ""
echo "Runtime flamegraphs:"
ls -lh "$WS_DIR/profiling/captures/flamegraphs/runtime/"*.svg 2>/dev/null || echo "  (none)"
echo ""
echo "Loading flamegraphs:"
ls -lh "$WS_DIR/profiling/captures/flamegraphs/loading/"*.svg 2>/dev/null || echo "  (none)"
echo ""
echo "Wall-clock loading times:"
for f in "$WS_DIR/profiling/captures/flamegraphs/loading/"*_wallclock.txt; do
    if [[ -f "$f" ]]; then
        label=$(basename "$f" _wallclock.txt)
        real_time=$(grep '^real' "$f" 2>/dev/null | awk '{print $2}' || echo "N/A")
        printf "  %-30s %s\n" "$label" "$real_time"
    fi
done
