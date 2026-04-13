#!/usr/bin/env bash
#SBATCH --job-name=kagen-exp3
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=64G
#SBATCH --time=05:00:00
#SBATCH --output=results/exp3_%j.out
#SBATCH --error=results/exp3_%j.err
#SBATCH --exclusive

# Experiment 3: Streaming scalability — fixed k=32, sweep graph size N in {18,20,22,24,26}
# Generators: GNM, RHG, RGG2D, BA, Grid2D, RDG2D
# Streaming with k=32 keeps peak RSS at roughly 1/32 of the in-memory footprint.

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

./run_exp3_generators.sh "$BINARY"
