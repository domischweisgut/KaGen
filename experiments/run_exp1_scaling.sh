#!/usr/bin/env bash
# =============================================================================
# Experiment 1: Memory scaling with graph size
# =============================================================================
# Fixes the average degree and grows the number of nodes exponentially.
# Runs each configuration in both in-memory and streaming modes.
#
# Output: results/exp1_scaling.csv
#
# Usage:
#   ./run_exp1_scaling.sh [BINARY] [NUM_PES]
#
#   BINARY   path to the compiled memory_benchmark binary
#            (default: ../build/experiments/memory_benchmark)
#   NUM_PES  number of MPI processes (default: 1)
# =============================================================================

set -euo pipefail

BINARY="${1:-../build/experiments/memory_benchmark}"
NUM_PES="${2:-1}"
OUTPUT="results/exp1_scaling.csv"
LOGFILE="results/exp1_scaling.log"

# Streaming chunk counts to test (in addition to inmemory mode)
STREAMING_CHUNKS=(8 32 128)

# Range of N: n = 2^N nodes; sweep from 2^12 (4K) to 2^26 (64M)
N_MIN=12
N_MAX=26
N_STEP=2

# Average degree kept constant for all sizes (M = N + log2(avg_deg/2))
# avg_deg = 16  ->  m = 8 * n  ->  log2(m) = N + 3
AVG_DEG_LOG=3   # log2(avg_degree/2) to add to N for M parameter

if [[ ! -x "$BINARY" ]]; then
    echo "ERROR: binary not found or not executable: $BINARY" >&2
    echo "Build with:  cmake -DKAGEN_BUILD_EXPERIMENTS=ON .. && make memory_benchmark" >&2
    exit 1
fi

mkdir -p results
echo "Logging to $LOGFILE"

# Write CSV header
echo "options,mode,chunks,peak_rss_bytes,baseline_rss_bytes,wall_sec,edge_count,num_pes" \
    > "$OUTPUT"

run_one() {
    local options="$1"
    local mode="$2"
    local k="$3"

    echo "  [$(date +%H:%M:%S)] mode=$mode k=$k  $options" | tee -a "$LOGFILE"

    local result
    if result=$(mpirun -np "$NUM_PES" "$BINARY" "$options" "$mode" "$k" 2>>"$LOGFILE"); then
        echo "$result" >> "$OUTPUT"
    else
        echo "  WARNING: run failed (see $LOGFILE)" >&2
    fi
}

# ---------------------------------------------------------------------------
# Generator 1: GNM-undirected   (exact edge count, simplest model)
# ---------------------------------------------------------------------------
echo "=== GNM-undirected ===" | tee -a "$LOGFILE"
for N in $(seq "$N_MIN" "$N_STEP" "$N_MAX"); do
    M=$((N + AVG_DEG_LOG))
    OPTIONS="gnm-undirected;N=${N};M=${M}"
    echo "N=$N  M=$M  (n=2^${N}, m=2^${M})" | tee -a "$LOGFILE"

    # in-memory baseline (chunks=1 is irrelevant for this mode but keeps CSV consistent)
    run_one "$OPTIONS" "inmemory" 1

    # streaming with increasing chunk counts
    for k in "${STREAMING_CHUNKS[@]}"; do
        run_one "$OPTIONS" "streaming" "$k"
    done
done

# ---------------------------------------------------------------------------
# Generator 2: RHG (Random Hyperbolic Graph, power-law degree distribution)
# Specifies average degree and gamma; edge count is approximate.
# ---------------------------------------------------------------------------
echo "" | tee -a "$LOGFILE"
echo "=== RHG ===" | tee -a "$LOGFILE"
GAMMA=2.8
AVG_DEG=16
for N in $(seq "$N_MIN" "$N_STEP" "$N_MAX"); do
    OPTIONS="rhg;N=${N};d=${AVG_DEG};g=${GAMMA}"
    echo "N=$N  d=$AVG_DEG  g=$GAMMA" | tee -a "$LOGFILE"

    run_one "$OPTIONS" "inmemory" 1

    for k in "${STREAMING_CHUNKS[@]}"; do
        run_one "$OPTIONS" "streaming" "$k"
    done
done

# ---------------------------------------------------------------------------
# Generator 3: RGG2D (Random Geometric Graph in unit square)
# Radius computed to yield approximately AVG_DEG=16 neighbours.
#   avg_deg ≈ n * π * r²  =>  r = sqrt(avg_deg / (n * π))
# ---------------------------------------------------------------------------
echo "" | tee -a "$LOGFILE"
echo "=== RGG2D ===" | tee -a "$LOGFILE"
for N in $(seq "$N_MIN" "$N_STEP" "$N_MAX"); do
    # Compute radius in Python (bc lacks sqrt / pi)
    R=$(python3 -c "import math; print(f'{math.sqrt(16.0 / (2**${N} * math.pi)):.8f}')")
    OPTIONS="rgg2d;N=${N};r=${R}"
    echo "N=$N  r=$R" | tee -a "$LOGFILE"

    run_one "$OPTIONS" "inmemory" 1

    for k in "${STREAMING_CHUNKS[@]}"; do
        run_one "$OPTIONS" "streaming" "$k"
    done
done

echo ""
echo "Done. Results written to $OUTPUT"
