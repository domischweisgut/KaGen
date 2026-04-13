#!/usr/bin/env bash
#SBATCH --job-name=kagen-exp2
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=64G
#SBATCH --time=05:00:00
#SBATCH --output=results/exp2_%j.out
#SBATCH --error=results/exp2_%j.err

# Experiment 2: Fixed graph size (N=26, ~67M nodes), sweep chunk count k in {1..512}
# Generators: GNM, RHG, RGG2D, BA, Grid2D
# NOTE: in-memory at N=26 requires ~8 GB for the edge list alone; 32G gives headroom.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY="${SCRIPT_DIR}/../build/experiments/memory_benchmark"

module load mpi

mkdir -p "${SCRIPT_DIR}/results"
cd "${SCRIPT_DIR}"

if [[ ! -x "$BINARY" ]]; then
    echo "ERROR: binary not found: $BINARY" >&2
    exit 1
fi

./run_exp2_chunks.sh "$BINARY"
