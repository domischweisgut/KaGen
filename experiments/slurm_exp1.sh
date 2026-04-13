#!/usr/bin/env bash
#SBATCH --job-name=kagen-exp1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=64G
#SBATCH --time=05:00:00
#SBATCH --output=results/exp1_%j.out
#SBATCH --error=results/exp1_%j.err

# Experiment 1: In-memory vs. streaming memory scaling with graph size
# N in {20..24}, k=32, generators: GNM, RHG, RGG2D, BA, Grid2D, RDG2D

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

./run_exp1_scaling.sh "$BINARY"
