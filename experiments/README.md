# KaGen Memory Experiments

Experiments comparing peak memory consumption between **in-memory** and **streaming** graph generation across graph sizes, chunk counts, and generator types.

---

## Motivation

The in-memory generator stores the entire graph (edge list or CSR) before returning it to the caller, so peak RSS grows as **O(m)** – proportional to the number of edges.  The streaming generator (`sKaGen`) produces the graph in *k* chunks and delivers edges via a callback, so at most one chunk lives in memory at a time, giving a theoretical peak of **O(m / k + overhead)**.

These experiments quantify:
1. How the two modes scale as graph size grows.
2. How faithfully streaming achieves the O(1/k) memory reduction.
3. Whether the reduction is consistent across different generator algorithms.

---

## Measurement Methodology

### Metric: peak RSS
Memory is measured with `getrusage(RUSAGE_SELF, ...)` immediately after generation completes.  `ru_maxrss` is the **process-lifetime peak resident set size** – the maximum physical RAM the process had mapped at any point.  This naturally captures the high-water mark during generation without requiring instrumentation inside the library.

> Platform note: on macOS `ru_maxrss` is in bytes; on Linux it is in kilobytes.  `memory_benchmark.cpp` normalises both to bytes.

### Baseline
Each run also records `baseline_rss_bytes`: the peak RSS *before* generation starts (after MPI initialisation and library setup).  The analysis script can report `peak – baseline` as the **generation-only** memory delta, isolating the graph from MPI/runtime overhead.

### MPI
All experiments default to a single MPI process (`NUM_PES=1`).  The benchmark collects the **maximum peak RSS across all ranks** via `MPI_Reduce(..., MPI_MAX, ...)` so multi-PE runs report the worst-case PE.

### What is *not* measured
- Memory inside the application that processes edges (the benchmark discards each edge immediately in the callback).
- Virtual memory / swap – only resident pages.
- Generator *initialisation* overhead for streaming (the `Initialize()` call runs before the timer).

---

## Files

| File | Purpose |
|------|---------|
| `memory_benchmark.cpp` | C++ harness: generates a graph, records peak RSS, prints one CSV row |
| `CMakeLists.txt` | Builds `memory_benchmark`; enabled via `-DKAGEN_BUILD_EXPERIMENTS=ON` |
| `run_exp1_scaling.sh` | **Experiment 1** – sweep graph size |
| `run_exp2_chunks.sh` | **Experiment 2** – sweep chunk count |
| `run_exp3_generators.sh` | **Experiment 3** – compare generator types |
| `analyze.py` | Parse CSVs, produce plots and a summary table |

Results land in `results/` (created automatically); figures in `results/figures/`.

---

## Experiments

### Experiment 1 – Memory scaling with graph size

**Question:** How does peak RSS grow with n for each mode?

**Setup:**
- Average degree fixed at 16 (`M = N + 3`, i.e. `m = 8n`).
- `N` (log₂ of node count) swept from 12 to 26 in steps of 2.
- Modes: in-memory, streaming with k = 8, 32, 128.
- Generators: `gnm-undirected` (exact edge count), `rhg` (power-law degree distribution), `rgg2d` (spatial, radius chosen to hit avg degree 16).

**Expected outcome:**
- In-memory: straight line of slope 1 on a log–log plot (linear in m).
- Streaming: parallel lines shifted down by log₂(k), converging toward the theoretical edge-list lower bound.

---

### Experiment 2 – Memory vs chunk count

**Question:** Does streaming achieve O(1/k) memory reduction?

**Setup:**
- Graph size fixed at `N=22`, `M=25` (≈ 4 M nodes, 33 M edges).
- Chunk count swept: 1, 2, 4, 8, 16, 32, 64, 128, 256, 512.
- Generators: `gnm-undirected`, `rhg`, `rgg2d`.
- The in-memory mode is run once as a horizontal baseline.

**Expected outcome:**
- Streaming memory ∝ 1/k for large k (once per-chunk overhead dominates).
- At k=1 the streaming peak should approach the in-memory peak (whole graph processed in one chunk).
- Deviations from ideal 1/k reveal fixed overheads (generator state, MPI buffers, etc.).

The analysis script plots both the raw memory and the **reduction ratio** (streaming / in-memory) with an ideal 1/k reference curve.

---

### Experiment 3 – Cross-generator comparison

**Question:** Is the memory benefit of streaming consistent across all generator algorithms?

**Setup:**
- Fixed target: `N=20` (≈ 1 M nodes), average degree ≈ 16.
- Generators: `gnm-undirected`, `gnm-directed`, `gnp-undirected`, `ba`, `rhg`, `rgg2d`, `rgg3d`, `grid2d`, `path`.
- Modes: in-memory and streaming with k = 8, 32, 128.

**Expected outcome:**
- Generators with simple uniform structure (GNM, GNP) should reduce memory cleanly.
- Generators with internal auxiliary structures (RHG, RGG) may show higher fixed overheads.
- `path` is a near-degenerate case (m = n − 1) useful for bounding the minimum memory floor.

---

## Building

```bash
# From the repository root
cmake -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DKAGEN_BUILD_EXPERIMENTS=ON
cmake --build build --target memory_benchmark -j$(nproc)
```

---

## Running

All scripts take two optional positional arguments:

```
./run_expN_<name>.sh  [PATH_TO_BINARY]  [NUM_MPI_PROCESSES]
```

Default binary: `../build/experiments/memory_benchmark`
Default processes: `1`

```bash
cd experiments

# Experiment 1 (longest – ~60 configurations × 3 generators)
./run_exp1_scaling.sh ../build/experiments/memory_benchmark 1

# Experiment 2
./run_exp2_chunks.sh  ../build/experiments/memory_benchmark 1

# Experiment 3
./run_exp3_generators.sh ../build/experiments/memory_benchmark 1
```

Logs are written alongside each CSV (`results/expN_*.log`) for debugging failed runs.

---

## Analysis

Requires Python ≥ 3.9 with `pandas`, `matplotlib`, `numpy`.

```bash
# Process all experiments and save PDFs
python3 analyze.py

# Single experiment, PNG output, interactive display
python3 analyze.py --exp 2 --format png --show
```

### Output figures

| File | Content |
|------|---------|
| `exp1_scaling_{generator}.pdf` | Memory vs N per generator |
| `exp1_scaling_combined.pdf` | All generators side-by-side |
| `exp1_timing.pdf` | Wall time vs N |
| `exp2_chunks.pdf` | Memory vs k with O(1/k) reference |
| `exp2_chunks_ratio.pdf` | Streaming / in-memory ratio vs k |
| `exp2_timing.pdf` | Wall time vs k |
| `exp3_generators.pdf` | Grouped bar chart by generator |

The script also prints a summary table of **memory reduction factors** (in-memory / streaming_k) for Experiment 3.

---

## CSV format

All result files share the same column schema:

| Column | Type | Description |
|--------|------|-------------|
| `options` | string | KaGen options string, e.g. `gnm-undirected;N=20;M=23` |
| `mode` | string | `inmemory` or `streaming` |
| `chunks` | int | Chunk count (1 for in-memory runs) |
| `peak_rss_bytes` | int | Max peak RSS across all MPI ranks (bytes) |
| `baseline_rss_bytes` | int | Peak RSS before generation (bytes) |
| `wall_sec` | float | Wall-clock seconds for graph generation |
| `edge_count` | int | Total edges across all MPI ranks |
| `num_pes` | int | Number of MPI processes |
