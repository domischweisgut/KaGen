#!/usr/bin/env bash
# =============================================================================
# Experiment 2: Memory vs number of streaming chunks
# =============================================================================
# Fixes the graph size and sweeps chunk count from 1 (whole graph in one pass)
# to 512.  Also runs the in-memory baseline for comparison.
#
# Key question: does peak RSS decrease proportionally to k?
# Theoretical expectation: peak_rss ≈ C * m / k  for streaming.
#
# Output: results/exp2_chunks.csv
#
# Usage:
#   ./run_exp2_chunks.sh [BINARY] [NUM_PES]
# =============================================================================

set -euo pipefail

BINARY="${1:-../build/experiments/memory_benchmark}"
NUM_PES="${2:-1}"
OUTPUT="results/exp2_chunks.csv"
LOGFILE="results/exp2_chunks.log"

# Fixed graph size: 2^N nodes, 2^M edges  (avg degree 16)
N=22
M=25   # N + 3 → avg deg 16

# Chunk counts to sweep (powers of 2)
CHUNK_COUNTS=(1 2 4 8 16 32 64 128 256 512)

if [[ ! -x "$BINARY" ]]; then
    echo "ERROR: binary not found or not executable: $BINARY" >&2
    exit 1
fi

mkdir -p results

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
# GNM-undirected
# ---------------------------------------------------------------------------
echo "=== GNM-undirected  N=$N M=$M ===" | tee -a "$LOGFILE"
GNM_OPTS="gnm-undirected;N=${N};M=${M}"

# in-memory baseline
run_one "$GNM_OPTS" "inmemory" 1

# streaming: sweep k
for k in "${CHUNK_COUNTS[@]}"; do
    run_one "$GNM_OPTS" "streaming" "$k"
done

# ---------------------------------------------------------------------------
# RHG – different internal data structure, interesting to compare
# ---------------------------------------------------------------------------
echo "" | tee -a "$LOGFILE"
echo "=== RHG  N=$N d=16 g=2.8 ===" | tee -a "$LOGFILE"
RHG_OPTS="rhg;N=${N};d=16;g=2.8"

run_one "$RHG_OPTS" "inmemory" 1

for k in "${CHUNK_COUNTS[@]}"; do
    run_one "$RHG_OPTS" "streaming" "$k"
done

# ---------------------------------------------------------------------------
# RGG2D
# ---------------------------------------------------------------------------
echo "" | tee -a "$LOGFILE"
R=$(python3 -c "import math; print(f'{math.sqrt(16.0 / (2**${N} * math.pi)):.8f}')")
echo "=== RGG2D  N=$N r=$R ===" | tee -a "$LOGFILE"
RGG_OPTS="rgg2d;N=${N};r=${R}"

run_one "$RGG_OPTS" "inmemory" 1

for k in "${CHUNK_COUNTS[@]}"; do
    run_one "$RGG_OPTS" "streaming" "$k"
done

echo ""
echo "Done. Results written to $OUTPUT"
