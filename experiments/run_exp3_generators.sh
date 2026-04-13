#!/usr/bin/env bash
# =============================================================================
# Experiment 3: Streaming scalability — fixed k, increasing problem size
# =============================================================================
# Runs the streaming generator with a fixed chunk count (k=32) across an
# increasing range of graph sizes.  Only streaming mode is used here; the
# in-memory baseline is covered by Experiment 1.
#
# Key questions:
#   - Does peak RSS grow sub-linearly (O(m/k)) with n?
#   - Does init time stay roughly constant while stream time grows linearly?
#
# Generators tested: GNM-undirected, RHG, RGG2D, BA, Grid2D
# (RDG2D / Delaunay also attempted; silently skipped if CGAL unavailable)
#
# Output: results/exp3_size_scaling.csv
#
# Usage:
#   ./run_exp3_generators.sh [BINARY]
#
#   BINARY   path to the compiled memory_benchmark binary
#            (default: ../build/experiments/memory_benchmark)
#
# Note: always runs with a single MPI process (np=1). Parallelism is not
# the goal of these benchmarks.
# =============================================================================

set -euo pipefail

BINARY="${1:-../build/experiments/memory_benchmark}"
OUTPUT="results/exp3_size_scaling.csv"
LOGFILE="results/exp3_size_scaling.log"

# Fixed chunk count
K=32

# Range of N: n = 2^N nodes; sweep from 2^18 (~262K) to 2^26 (~67M)
N_MIN=18
N_MAX=26
N_STEP=2

# Average degree kept constant across all sizes
AVG_DEG=16
AVG_DEG_LOG=3   # log2(avg_degree/2); used for GNM: M = N + AVG_DEG_LOG

if [[ ! -x "$BINARY" ]]; then
    echo "ERROR: binary not found or not executable: $BINARY" >&2
    echo "Build with:  cmake -DKAGEN_BUILD_EXPERIMENTS=ON .. && make memory_benchmark" >&2
    exit 1
fi

mkdir -p results
echo "Logging to $LOGFILE"

# Write CSV header
echo "options,mode,chunks,peak_rss_bytes,baseline_rss_bytes,init_sec,stream_sec,wall_sec,edge_count,num_pes" \
    > "$OUTPUT"

run_one() {
    local options="$1"
    echo "  [$(date +%H:%M:%S)] k=$K  $options" | tee -a "$LOGFILE"

    local result
    if result=$(mpirun -np 1 "$BINARY" "$options" "streaming" "$K" 2>>"$LOGFILE"); then
        echo "$result" >> "$OUTPUT"
    else
        echo "  WARNING: run failed (see $LOGFILE)" >&2
    fi
}

# ---------------------------------------------------------------------------
# Generator 1: GNM-undirected
# ---------------------------------------------------------------------------
echo "=== GNM-undirected ===" | tee -a "$LOGFILE"
for N in $(seq "$N_MIN" "$N_STEP" "$N_MAX"); do
    M=$((N + AVG_DEG_LOG))
    run_one "gnm-undirected;N=${N};M=${M}"
done

# ---------------------------------------------------------------------------
# Generator 2: RHG (Random Hyperbolic Graph)
# ---------------------------------------------------------------------------
echo "" | tee -a "$LOGFILE"
echo "=== RHG ===" | tee -a "$LOGFILE"
GAMMA=2.8
for N in $(seq "$N_MIN" "$N_STEP" "$N_MAX"); do
    run_one "rhg;N=${N};d=${AVG_DEG};g=${GAMMA}"
done

# ---------------------------------------------------------------------------
# Generator 3: RGG2D
#   avg_deg ≈ n * π * r²  =>  r = sqrt(avg_deg / (n * π))
# ---------------------------------------------------------------------------
echo "" | tee -a "$LOGFILE"
echo "=== RGG2D ===" | tee -a "$LOGFILE"
for N in $(seq "$N_MIN" "$N_STEP" "$N_MAX"); do
    R=$(python3 -c "import math; print(f'{math.sqrt(${AVG_DEG} / (2**${N} * math.pi)):.8f}')")
    run_one "rgg2d;N=${N};r=${R}"
done

# ---------------------------------------------------------------------------
# Generator 4: BA (Barabási-Albert)
#   d = avg_deg / 2; each new node attaches to d existing nodes
# ---------------------------------------------------------------------------
echo "" | tee -a "$LOGFILE"
echo "=== BA ===" | tee -a "$LOGFILE"
BA_D=$((AVG_DEG / 2))
for N in $(seq "$N_MIN" "$N_STEP" "$N_MAX"); do
    run_one "ba;N=${N};d=${BA_D}"
done

# ---------------------------------------------------------------------------
# Generator 5: Grid2D (square grid, all edges)
# Pass N directly; the generator computes grid_x = grid_y = sqrt(2^N) internally.
# ---------------------------------------------------------------------------
echo "" | tee -a "$LOGFILE"
echo "=== Grid2D ===" | tee -a "$LOGFILE"
for N in $(seq "$N_MIN" "$N_STEP" "$N_MAX"); do
    run_one "grid2d;N=${N};p=1"
done

# ---------------------------------------------------------------------------
# Generator 6: RDG2D (Delaunay) — requires CGAL; silently skipped on failure
# ---------------------------------------------------------------------------
echo "" | tee -a "$LOGFILE"
echo "=== RDG2D (Delaunay, requires CGAL) ===" | tee -a "$LOGFILE"
for N in $(seq "$N_MIN" "$N_STEP" "$N_MAX"); do
    run_one "rdg2d;N=${N}"
done

echo ""
echo "Done. Results written to $OUTPUT"
