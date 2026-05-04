#!/usr/bin/env bash
# gz_full_pipeline.sh — End-to-end profiling: capture all worlds, analyze, rank
#
# Usage: ./gz_full_pipeline.sh <worlds_dir> [--publish] [--skip-capture]
#
# Single command that runs the complete profiling pipeline:
#   1. Captures all worlds (CPU, loading, cache-miss, c2c, sched)
#   2. Runs all post-capture analysis (hotspots, per-thread, cache comparison)
#   3. Produces per-world summaries with composite scores
#   4. Merges into a cross-world ranked list of optimization targets
#   5. Optionally publishes to the repository
#
# Options:
#   --publish        Run gz_publish_run.sh after analysis
#   --skip-capture   Skip capture step, analyze existing captures/ directory
#   --no-cache       Skip cache-miss flamegraph captures (faster)
#   --no-extended    Skip c2c + sched captures (faster, no tracepoint access needed)
#
# Prerequisites:
#   - Workspace built with RelWithDebInfo, -fno-omit-frame-pointer
#   - sudo sysctl kernel.perf_event_paranoid=1
#   - GZ_SIM_MAIN, FLAMEGRAPH_DIR set or auto-detected
#   - Assets pre-cached (run each world once beforehand)
#
# Outputs:
#   captures/summary/cross_world_summary.tsv   The main deliverable
#   captures/summary/*_summary.tsv             Per-world composite scores
#   captures/runtime/*.svg, *.folded           CPU flamegraphs
#   captures/loading/*.svg, *.folded           Loading flamegraphs
#   captures/cache/*.svg, *.folded             Cache-miss flamegraphs
#   captures/c2c/*.tsv                         False sharing reports
#   captures/sched/*.tsv                       Scheduler analysis
#   captures/threads/*.tsv                     Per-thread distributions

set +o pipefail

WORLDS_DIR="${1:?Usage: $0 <worlds_dir> [--publish] [--skip-capture] [--no-cache] [--no-extended]}"
shift

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse flags
DO_PUBLISH=false
SKIP_CAPTURE=false
CAPTURE_FLAGS="--full"
for arg in "$@"; do
    case "$arg" in
        --publish)      DO_PUBLISH=true ;;
        --skip-capture) SKIP_CAPTURE=true ;;
        --no-cache)     CAPTURE_FLAGS="--with-c2c --with-sched" ;;
        --no-extended)  CAPTURE_FLAGS="--with-cache" ;;
    esac
done

echo "╔════════════════════════════════════════════╗"
echo "║  Gazebo Full Profiling Pipeline            ║"
echo "╚════════════════════════════════════════════╝"
echo ""
echo "  Worlds:       $WORLDS_DIR"
echo "  Skip capture: $SKIP_CAPTURE"
echo "  Publish:      $DO_PUBLISH"
echo ""

START_TIME=$(date +%s)

# ─── Step 1: Capture ───

if ! $SKIP_CAPTURE; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Step 1/3: Capturing all worlds"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    "$SCRIPT_DIR/capture_all.sh" "$WORLDS_DIR" $CAPTURE_FLAGS

    echo ""
fi

# ─── Step 2: Analyze ───

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 2/3: Post-capture analysis"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

"$SCRIPT_DIR/gz_analyze.sh" captures/

# ─── Step 3: Publish (optional) ───

if $DO_PUBLISH; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Step 3/3: Publishing"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    "$SCRIPT_DIR/gz_publish_run.sh" captures/
fi

# ─── Final summary ───

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))

echo ""
echo "╔════════════════════════════════════════════╗"
echo "║  Pipeline Complete (${MINUTES}m ${SECONDS}s)                  "
echo "╚════════════════════════════════════════════╝"
echo ""

if [[ -f captures/summary/cross_world_summary.tsv ]]; then
    echo "  Main output: captures/summary/cross_world_summary.tsv"
    echo ""
    echo "  Top optimization targets:"
    tail -n +6 captures/summary/cross_world_summary.tsv | head -10 \
        | while IFS=$'\t' read -r rank func score worlds worst cpu cache evidence; do
            display="$func"
            if [[ ${#display} -gt 40 ]]; then
                idx=$(echo "$display" | grep -b -o '<' | head -1 | cut -d: -f1)
                if [[ -n "$idx" && "$idx" -gt 0 ]]; then
                    display="${display:0:$idx}<...>"
                else
                    display="${display:0:37}..."
                fi
            fi
            printf "    %2s. %-42s  score=%s  worlds=%s\n" "$rank" "$display" "$score" "$worlds"
        done
fi

echo ""
echo "  All results in: captures/"
