#!/usr/bin/env bash
# =============================================================================
# Experiment 3: Cross-generator memory comparison
# =============================================================================
# Runs all streaming-capable generators at a fixed target size and compares
# in-memory vs streaming peak RSS.
#
# Generators tested (those that support streaming):
#   gnm-undirected, gnp-undirected, rgg2d, ba, rhg, grid2d, path
#
# Output: results/exp3_generators.csv
#
# Usage:
#   ./run_exp3_generators.sh [BINARY] [NUM_PES]
# =============================================================================

set -euo pipefail

BINARY="${1:-../build/experiments/memory_benchmark}"
NUM_PES="${2:-1}"
OUTPUT="results/exp3_generators.csv"
LOGFILE="results/exp3_generators.log"

# Target: ~2^20 nodes, avg degree ~16  (m ≈ 2^23)
N=20
AVG_DEG=16
STREAMING_CHUNKS=(8 32 128)

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

run_generator() {
    local label="$1"
    local opts="$2"
    echo "" | tee -a "$LOGFILE"
    echo "=== $label ===" | tee -a "$LOGFILE"

    run_one "$opts" "inmemory" 1
    for k in "${STREAMING_CHUNKS[@]}"; do
        run_one "$opts" "streaming" "$k"
    done
}

# GNM undirected – exact edge count
run_generator "GNM-undirected" "gnm-undirected;N=${N};M=$((N + 3))"

# GNM directed – same edge count, directed
run_generator "GNM-directed"   "gnm-directed;N=${N};M=$((N + 3))"

# GNP undirected – edge probability p = avg_deg / n
P=$(python3 -c "print(f'{${AVG_DEG} / 2**${N}:.8f}')")
run_generator "GNP-undirected" "gnp-undirected;N=${N};p=${P}"

# BA (Barabasi-Albert) – min-degree d gives avg degree ~ 2*d
D=$((AVG_DEG / 2))
run_generator "BA"             "ba;N=${N};d=${D}"

# RHG (Random Hyperbolic Graph, power-law)
run_generator "RHG"            "rhg;N=${N};d=${AVG_DEG};g=2.8"

# RGG2D – radius computed from avg degree
R2D=$(python3 -c "import math; print(f'{math.sqrt(${AVG_DEG} / (2**${N} * math.pi)):.8f}')")
run_generator "RGG2D"          "rgg2d;N=${N};r=${R2D}"

# RGG3D – radius computed from avg degree (3D ball: avg = n * 4/3 π r³)
R3D=$(python3 -c "import math; print(f'{(${AVG_DEG} / (2**${N} * 4.0/3.0 * math.pi))**(1.0/3.0):.8f}')")
run_generator "RGG3D"          "rgg3d;N=${N};r=${R3D}"

# Grid2D – square grid, p=1 (all edges present)
# grid_x * grid_y = n = 2^N  =>  grid_x = grid_y = 2^(N/2)
HALF_N=$((N / 2))
run_generator "Grid2D"         "grid2d;X=${HALF_N};Y=${HALF_N};p=1"

# PATH – linear path graph (sparse, 1 edge per node)
run_generator "PATH"           "path;N=${N}"

echo ""
echo "Done. Results written to $OUTPUT"
