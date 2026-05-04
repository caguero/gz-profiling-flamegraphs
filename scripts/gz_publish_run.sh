#!/usr/bin/env bash
# gz_publish_run.sh — Package local captures into a dated run for the repository
#
# Usage: ./gz_publish_run.sh [captures_dir] [--date YYYY-MM-DD] [--description "text"]
#
# Takes local capture results and packages them into a dated directory
# ready for git commit and GitHub Pages publishing.
#
# Workflow:
#   1. Run captures locally:    ./scripts/capture_all.sh worlds/ --full
#   2. Inspect results, re-run as needed
#   3. Publish when happy:      ./scripts/gz_publish_run.sh
#
# What it does:
#   - Creates YYYY-MM-DD/ directory with runtime/, loading/, cache/, etc.
#   - Copies .svg, .folded, .tsv files (skips large perf_*.data)
#   - Runs gz_hotspots.sh and gz_summary.sh if not already done
#   - Generates YYYY-MM-DD/index.html with links to all SVGs
#   - Updates the top-level index.html to include the new run
#
# Outputs:
#   YYYY-MM-DD/runtime/*.svg, *.folded
#   YYYY-MM-DD/loading/*.svg, *.folded
#   YYYY-MM-DD/cache/*.svg, *.folded
#   YYYY-MM-DD/c2c/*.tsv
#   YYYY-MM-DD/sched/*.tsv
#   YYYY-MM-DD/threads/*.tsv, *.svg
#   YYYY-MM-DD/summary/*.tsv
#   YYYY-MM-DD/index.html

set +o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
CAPTURES_DIR="$(pwd)/captures"
RUN_DATE=$(date +%Y-%m-%d)
DESCRIPTION=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --date)
            RUN_DATE="$2"
            shift 2
            ;;
        --description)
            DESCRIPTION="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [captures_dir] [--date YYYY-MM-DD] [--description \"text\"]"
            echo ""
            echo "  captures_dir    Directory with capture results (default: ./captures)"
            echo "  --date          Override run date (default: today)"
            echo "  --description   Short description for the index page"
            exit 0
            ;;
        *)
            if [[ -d "$1" ]]; then
                CAPTURES_DIR="$(cd "$1" && pwd)"
            else
                echo "ERROR: Not a directory: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

FLAMEGRAPH_DIR="${FLAMEGRAPH_DIR:-$(pwd)/FlameGraph}"
RUN_DIR="$REPO_DIR/$RUN_DATE"

# Validate captures directory
if [[ ! -d "$CAPTURES_DIR" ]]; then
    echo "ERROR: Captures directory not found: $CAPTURES_DIR" >&2
    echo "  Run ./scripts/capture_all.sh first." >&2
    exit 1
fi

# Check for at least some data
SVG_COUNT=$(find "$CAPTURES_DIR" -name '*.svg' 2>/dev/null | wc -l)
FOLDED_COUNT=$(find "$CAPTURES_DIR" -name '*.folded' 2>/dev/null | wc -l)
if [[ "$SVG_COUNT" -eq 0 && "$FOLDED_COUNT" -eq 0 ]]; then
    echo "ERROR: No .svg or .folded files found in $CAPTURES_DIR" >&2
    echo "  Run ./scripts/capture_all.sh first." >&2
    exit 1
fi

# Check for existing run
if [[ -d "$RUN_DIR" ]]; then
    echo "WARNING: $RUN_DIR already exists."
    echo "  Contents will be merged (existing files NOT overwritten)."
    echo "  Use --date to specify a different date, or remove the directory first."
    echo ""
fi

echo "============================================"
echo "  Publishing Profiling Run"
echo "============================================"
echo "  Source:  $CAPTURES_DIR"
echo "  Target:  $RUN_DIR"
echo "  Date:    $RUN_DATE"
echo ""

# ─── Step 1: Create directory structure ───

echo "[1/5] Creating directory structure..."
SUBDIRS="runtime loading cache c2c sched threads summary"
for dir in $SUBDIRS; do
    mkdir -p "$RUN_DIR/$dir"
done

# ─── Step 2: Copy artifacts (skip perf_*.data) ───

echo "[2/5] Copying artifacts..."

copy_artifacts() {
    local src_dir="$1" dst_dir="$2" label="$3"
    local count=0

    if [[ ! -d "$src_dir" ]]; then
        return
    fi

    for ext in svg folded tsv txt; do
        for f in "$src_dir"/*."$ext"; do
            [[ -f "$f" ]] || continue
            local base=$(basename "$f")
            if [[ ! -f "$dst_dir/$base" ]]; then
                cp "$f" "$dst_dir/"
                count=$((count + 1))
            fi
        done
    done

    [[ $count -gt 0 ]] && echo "  $label: $count files"
}

copy_artifacts "$CAPTURES_DIR/runtime" "$RUN_DIR/runtime" "Runtime"
copy_artifacts "$CAPTURES_DIR/loading" "$RUN_DIR/loading" "Loading"
copy_artifacts "$CAPTURES_DIR/cache"   "$RUN_DIR/cache"   "Cache"
copy_artifacts "$CAPTURES_DIR/c2c"     "$RUN_DIR/c2c"     "C2C"
copy_artifacts "$CAPTURES_DIR/sched"   "$RUN_DIR/sched"   "Sched"
copy_artifacts "$CAPTURES_DIR/threads" "$RUN_DIR/threads"  "Threads"
copy_artifacts "$CAPTURES_DIR/summary" "$RUN_DIR/summary" "Summary"
copy_artifacts "$CAPTURES_DIR/diff"    "$RUN_DIR/diff"     "Diff"

# ─── Step 3: Run post-capture analysis if missing ───

echo "[3/5] Running post-capture analysis..."

# Hotspots for each runtime folded file
for folded in "$RUN_DIR/runtime"/*.folded; do
    [[ -f "$folded" ]] || continue
    label=$(basename "$folded" .folded)
    hotspot_file="$RUN_DIR/runtime/${label}_hotspots.txt"
    if [[ ! -f "$hotspot_file" ]]; then
        echo "  Hotspots: $label"
        "$SCRIPT_DIR/gz_hotspots.sh" "$folded" 15 > "$hotspot_file" 2>/dev/null
    fi
done

# Summary for each runtime folded file (if cache data exists)
for folded in "$RUN_DIR/runtime"/*.folded; do
    [[ -f "$folded" ]] || continue
    label=$(basename "$folded" .folded)
    summary_file="$RUN_DIR/summary/${label}_summary.tsv"
    if [[ ! -f "$summary_file" ]]; then
        echo "  Summary: $label"
        OUTPUT_DIR="$RUN_DIR/summary" \
            "$SCRIPT_DIR/gz_summary.sh" "$RUN_DIR" "$label" > /dev/null 2>&1
    fi
done

# ─── Step 4: Generate per-run index.html ───

echo "[4/5] Generating index.html..."

# Collect world info
LOADING_ROWS=""
for svg in "$RUN_DIR/loading"/*_loading.svg; do
    [[ -f "$svg" ]] || continue
    label=$(basename "$svg" _loading.svg)
    wallclock_file="$RUN_DIR/loading/${label}_wallclock.txt"
    if [[ -f "$wallclock_file" ]]; then
        wallclock=$(grep real "$wallclock_file" 2>/dev/null | awk '{print $2}' | head -1)
    else
        wallclock="—"
    fi
    LOADING_ROWS+="    <tr><td>${label}</td><td>${wallclock}</td><td><a href=\"loading/$(basename "$svg")\">Open</a></td></tr>
"
done

RUNTIME_ROWS=""
for svg in "$RUN_DIR/runtime"/*.svg; do
    [[ -f "$svg" ]] || continue
    label=$(basename "$svg" .svg)
    RUNTIME_ROWS+="    <tr><td>${label}</td><td><a href=\"runtime/$(basename "$svg")\">Open</a></td></tr>
"
done

CACHE_ROWS=""
for svg in "$RUN_DIR/cache"/*_cachemiss.svg; do
    [[ -f "$svg" ]] || continue
    label=$(basename "$svg" _cachemiss.svg)
    CACHE_ROWS+="    <tr><td>${label}</td><td><a href=\"cache/$(basename "$svg")\">Open</a></td></tr>
"
done

# Build optional sections
C2C_SECTION=""
if ls "$RUN_DIR/c2c"/*.tsv >/dev/null 2>&1; then
    C2C_SECTION="
  <h2>False Sharing Analysis (perf c2c)</h2>
  <table>
    <tr><th>World</th><th>Report</th></tr>"
    for tsv in "$RUN_DIR/c2c"/*_c2c.tsv; do
        [[ -f "$tsv" ]] || continue
        label=$(basename "$tsv" _c2c.tsv)
        total=$(grep "Total HITM" "$tsv" | head -1 | grep -o '[0-9]*' | head -1)
        C2C_SECTION+="
    <tr><td>${label} (${total:-?} HITM)</td><td><a href=\"c2c/$(basename "$tsv")\">TSV</a></td></tr>"
    done
    C2C_SECTION+="
  </table>"
fi

SCHED_SECTION=""
if ls "$RUN_DIR/sched"/*.tsv >/dev/null 2>&1; then
    SCHED_SECTION="
  <h2>Scheduler Analysis</h2>
  <table>
    <tr><th>World</th><th>Report</th></tr>"
    for tsv in "$RUN_DIR/sched"/*_sched.tsv; do
        [[ -f "$tsv" ]] || continue
        label=$(basename "$tsv" _sched.tsv)
        flagged=$(grep -c "YES" "$tsv" 2>/dev/null || echo 0)
        SCHED_SECTION+="
    <tr><td>${label} (${flagged} flagged)</td><td><a href=\"sched/$(basename "$tsv")\">TSV</a></td></tr>"
    done
    SCHED_SECTION+="
  </table>"
fi

SUMMARY_SECTION=""
if ls "$RUN_DIR/summary"/*_summary.tsv >/dev/null 2>&1; then
    SUMMARY_SECTION="
  <h2>Unified Summary (gz_summary.sh)</h2>
  <table>
    <tr><th>World</th><th>Report</th></tr>"
    for tsv in "$RUN_DIR/summary"/*_summary.tsv; do
        [[ -f "$tsv" ]] || continue
        label=$(basename "$tsv" _summary.tsv)
        top=$(tail -n +6 "$tsv" | head -1 | cut -f2)
        SUMMARY_SECTION+="
    <tr><td>${label}</td><td><a href=\"summary/$(basename "$tsv")\">TSV</a> (top: ${top:-?})</td></tr>"
    done
    SUMMARY_SECTION+="
  </table>"
fi

# Hardware/software info from system
HW_CPU=$(lscpu 2>/dev/null | grep "Model name" | sed 's/Model name:[[:space:]]*//' | head -1)
HW_KERNEL=$(uname -r)
PERF_VER=$(perf version 2>/dev/null | awk '{print $NF}')

cat > "$RUN_DIR/index.html" << HTMLEOF
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Gazebo Profiling - ${RUN_DATE}</title>
  <style>
    body { font-family: 'Palatino', 'Georgia', serif; max-width: 900px; margin: 40px auto; padding: 0 20px; color: #333; }
    h1 { color: #333366; border-bottom: 2px solid #333366; padding-bottom: 10px; }
    h2 { color: #444477; margin-top: 30px; }
    a { color: #336; }
    table { border-collapse: collapse; width: 100%; margin: 15px 0; }
    th, td { text-align: left; padding: 8px 12px; border-bottom: 1px solid #ddd; }
    th { background: #f5f5f5; color: #333366; }
    tr:hover { background: #f9f9f9; }
    .back { margin-bottom: 20px; }
    .note { color: #666; font-size: 0.9em; }
  </style>
</head>
<body>
  <p class="back"><a href="../">&larr; All benchmark runs</a></p>
  <h1>Gazebo Profiling &mdash; ${RUN_DATE}</h1>

  <p class="note">
    Hardware: ${HW_CPU:-unknown}<br>
    Kernel: ${HW_KERNEL}, perf ${PERF_VER:-unknown}<br>
    All worlds at RTF=0 (maximum speed).
  </p>

  <h2>Loading Flamegraphs (startup + 1 iteration)</h2>
  <p class="note">Click any flamegraph to open it interactively (click frames to zoom, Ctrl+F to search).</p>
  <table>
    <tr><th>World</th><th>Wall-clock</th><th>Flamegraph</th></tr>
${LOADING_ROWS}  </table>

  <h2>Runtime Flamegraphs (30s steady-state)</h2>
  <table>
    <tr><th>World</th><th>Flamegraph</th></tr>
${RUNTIME_ROWS}  </table>

  <h2>Cache-Miss Flamegraphs</h2>
  <table>
    <tr><th>World</th><th>Flamegraph</th></tr>
${CACHE_ROWS}  </table>
${C2C_SECTION}
${SCHED_SECTION}
${SUMMARY_SECTION}

  <p><small>Generated with <a href="https://github.com/brendangregg/FlameGraph">FlameGraph</a> and Linux perf.</small></p>
</body>
</html>
HTMLEOF

echo "  Created $RUN_DIR/index.html"

# ─── Step 5: Update top-level index.html ───

echo "[5/5] Updating top-level index.html..."

TOP_INDEX="$REPO_DIR/index.html"

if [[ -f "$TOP_INDEX" ]]; then
    # Check if this run is already listed
    if grep -q "$RUN_DATE" "$TOP_INDEX"; then
        echo "  Run $RUN_DATE already in top-level index — skipping"
    else
        # Count worlds
        WORLD_COUNT=$(ls "$RUN_DIR/runtime"/*.svg 2>/dev/null | wc -l)
        DESC="${DESCRIPTION:-${WORLD_COUNT} worlds. $(lscpu 2>/dev/null | grep 'Model name' | sed 's/Model name:[[:space:]]*//' | head -1 | cut -c1-60).}"

        # Insert new row after the <tr><th> header row
        NEW_ROW="    <tr>\n      <td class=\"date\"><a href=\"${RUN_DATE}/\">${RUN_DATE}</a></td>\n      <td>${DESC}</td>\n      <td></td>\n    </tr>"

        # Insert before the first existing <tr> data row (after the header row)
        sed -i "/<tr><th>Date<\/th>/a\\${NEW_ROW}" "$TOP_INDEX"
        echo "  Added $RUN_DATE to top-level index"
    fi
else
    echo "  WARNING: Top-level index.html not found at $TOP_INDEX"
fi

# ─── Summary ───

echo ""
echo "============================================"
echo "  Published: $RUN_DIR"
echo "============================================"
echo ""
echo "  Files:"
for dir in $SUBDIRS diff; do
    count=$(find "$RUN_DIR/$dir" -type f 2>/dev/null | wc -l)
    [[ $count -gt 0 ]] && echo "    $dir/: $count files"
done
echo "    index.html"
echo ""
echo "  Next steps:"
echo "    cd $REPO_DIR"
echo "    git add $RUN_DATE/"
echo "    git commit -m \"Add profiling run $RUN_DATE\""
echo "    git push"
