# KaGen Memory & Timing Experiments

Experiments comparing peak memory consumption and generation time between **in-memory** and **streaming** graph generation across graph sizes, chunk counts, and generator types.

---

## Motivation

The in-memory generator stores the entire graph (edge list) before returning control to the caller, so peak RSS grows as **O(m)** – proportional to the number of edges.  The streaming generator (`sKaGen`) produces the graph in *k* chunks and delivers edges one chunk at a time via a callback, giving a theoretical peak of **O(m / k + overhead)**.

These experiments quantify:
1. How both modes scale as graph size grows (Exp 1 & 3).
2. How faithfully streaming achieves the O(1/k) memory reduction as k increases (Exp 2).
3. Whether the reduction is consistent across generator algorithms (all experiments).
4. How generation time splits between initialisation (`Initialize()`) and edge streaming (`StreamEdges()`).

---

## Measurement Methodology

### Platform
All runs use a **single MPI process** (`mpirun -np 1`). Distributed-memory parallelism is not evaluated; the goal is to characterise single-node memory and time behaviour.

### Memory metric: peak RSS
Memory is measured with `getrusage(RUSAGE_SELF, ...)` immediately after generation completes.  `ru_maxrss` is the **process-lifetime peak resident set size** – the maximum physical RAM the process had resident at any point.  On macOS `ru_maxrss` is in bytes; on Linux it is in kilobytes; the benchmark normalises both to bytes.

Each run records two RSS values:
- **`baseline_rss_bytes`**: RSS captured after `MPI_Init` but before any graph generation, capturing MPI and library startup overhead.
- **`peak_rss_bytes`**: RSS captured after generation completes.

The **net generation memory** is `peak_rss_bytes − baseline_rss_bytes`.

### Timing metric: wall-clock time
Three timing columns are recorded, all using `std::chrono::steady_clock`:

| Column | Streaming mode | In-memory mode |
|--------|---------------|----------------|
| `init_sec` | Time for `sKaGen::Initialize()` | 0 (no separate init phase) |
| `stream_sec` | Time for `sKaGen::StreamEdges()` | Time for `KaGen::GenerateFromOptionString()` |
| `wall_sec` | `init_sec + stream_sec` | Same as `stream_sec` |

With multiple MPI ranks, all metrics are aggregated via `MPI_Reduce(..., MPI_MAX, ...)` (worst-case rank). Edge counts use `MPI_SUM`.

### What is measured
- Peak RSS of the generator process (including all internal generator state).
- Time to initialise the streaming generator.
- Time to iterate through all edges (streaming), or to generate and store the full graph (in-memory).

### What is not measured
- Memory consumed by the *application* processing edges – the benchmark discards each edge immediately in the callback (`++edge_count` only).
- Virtual memory or swap – only resident pages.
- Disk I/O.

---

## Graph Generators

The following generators are used. All support the KaGen streaming API.

| Generator | KaGen name | Graph model | Notes |
|-----------|-----------|------------|-------|
| GNM undirected | `gnm-undirected` | Erdős–Rényi, exact edge count | Uniform random edges |
| RHG | `rhg` | Random Hyperbolic Graph | Power-law degree distribution |
| RGG2D | `rgg2d` | Random Geometric Graph, 2D unit square | Spatial proximity graph |
| BA | `ba` | Barabási–Albert preferential attachment | Scale-free, growing graph |
| Grid2D | `grid2d` | Regular 2D grid | Structured, low diameter |
| RDG2D | `rdg2d` | 2D Delaunay triangulation | Requires CGAL at build time |

---

## Experiments

### Experiment 1 – In-memory vs. streaming: memory scaling with graph size

**Research question:** How does peak RSS scale with *n* for in-memory vs. streaming generation?

**Script:** `run_exp1_scaling.sh`  
**Output:** `results/exp1_scaling.csv`

#### Parameters

| Parameter | Value |
|-----------|-------|
| Node count | n = 2^N, **N ∈ {20, 21, 22, 23, 24}** (≈ 1 M – 16 M nodes) |
| Streaming chunk count | **k = 32** |
| Modes | in-memory, streaming |
| Repetitions | 1 per configuration |
| MPI processes | 1 |

#### Generator-specific parameters

| Generator | Options string | Parameters |
|-----------|---------------|-----------|
| GNM undirected | `gnm-undirected;N=<N>;M=<N+3>` | m = 2^(N+3) edges → avg degree **d̄ = 16** |
| RHG | `rhg;N=<N>;d=16;g=2.8` | Target avg degree **d̄ = 16**, power-law exponent **γ = 2.8** |
| RGG2D | `rgg2d;N=<N>;r=<r>` | Radius **r = √(16 / (2^N · π))** → avg degree **d̄ ≈ 16** |
| BA | `ba;N=<N>;d=8` | Attachment count **d = 8** → avg degree **d̄ ≈ 16** |
| Grid2D | `grid2d;N=<N>;p=1` | Square grid, all edges present; dimensions auto-computed as ⌊√(2^N)⌋ × ⌊√(2^N)⌋; avg degree **d̄ ≈ 4** |
| RDG2D | `rdg2d;N=<N>` | Delaunay triangulation; avg degree **d̄ ≈ 6**; requires CGAL |

**Expected outcome:** In-memory RSS grows linearly with m (slope 1 on a log-log plot). Streaming RSS is shifted down by a factor of k = 32 toward the theoretical lower bound of one edge-list chunk.

---

### Experiment 2 – Fixed graph size, varying chunk count

**Research question:** Does streaming memory scale as O(1/k) as k increases?

**Script:** `run_exp2_chunks.sh`  
**Output:** `results/exp2_chunks.csv`

#### Parameters

| Parameter | Value |
|-----------|-------|
| Node count | n = 2^26 ≈ **67.1 M nodes** (fixed) |
| Edge count (GNM) | m = 2^29 ≈ **536.9 M edges** (fixed) |
| Avg degree | **d̄ = 16** (all generators except Grid2D) |
| Chunk counts swept | **k ∈ {1, 2, 4, 8, 16, 32, 64, 128, 256, 512}** |
| Modes | in-memory (once, as baseline), streaming (all k values) |
| Repetitions | 1 per configuration |
| MPI processes | 1 |

#### Generator-specific parameters

| Generator | Options string | Parameters |
|-----------|---------------|-----------|
| GNM undirected | `gnm-undirected;N=26;M=29` | m = 2^29 ≈ 537 M edges, **d̄ = 16** |
| RHG | `rhg;N=26;d=16;g=2.8` | **d̄ = 16**, **γ = 2.8** |
| RGG2D | `rgg2d;N=26;r=<r>` | **r = √(16 / (2^26 · π)) ≈ 1.55 × 10⁻³**, **d̄ ≈ 16** |
| BA | `ba;N=26;d=8` | **d = 8**, **d̄ ≈ 16** |
| Grid2D | `grid2d;N=26;p=1` | ⌊√(2^26)⌋ × ⌊√(2^26)⌋ = 8192 × 8192 nodes, **d̄ ≈ 4** |

**Expected outcome:** Streaming RSS ∝ 1/k for large k (once fixed per-chunk generator overhead is negligible). At k = 1 the streaming peak converges to the in-memory peak. The analysis plots both raw RSS and the **reduction ratio** (streaming / in-memory) against an ideal 1/k reference.

Init time should remain roughly constant across k (it is a one-time setup cost). Stream time should decrease proportionally to 1/k per chunk, but total stream time may grow slightly due to per-chunk dispatch overhead.

---

### Experiment 3 – Streaming scalability: fixed chunk count, increasing graph size

**Research question:** How do streaming memory and time scale with graph size when k is fixed?

**Script:** `run_exp3_generators.sh`  
**Output:** `results/exp3_size_scaling.csv`

#### Parameters

| Parameter | Value |
|-----------|-------|
| Node count | n = 2^N, **N ∈ {18, 20, 22, 24, 26}** (≈ 262 K – 67 M nodes) |
| Streaming chunk count | **k = 32** (fixed) |
| Mode | streaming only |
| Repetitions | 1 per configuration |
| MPI processes | 1 |

#### Generator-specific parameters

| Generator | Options string | Parameters |
|-----------|---------------|-----------|
| GNM undirected | `gnm-undirected;N=<N>;M=<N+3>` | m = 2^(N+3), **d̄ = 16** |
| RHG | `rhg;N=<N>;d=16;g=2.8` | **d̄ = 16**, **γ = 2.8** |
| RGG2D | `rgg2d;N=<N>;r=<r>` | **r = √(16 / (2^N · π))**, **d̄ ≈ 16** |
| BA | `ba;N=<N>;d=8` | **d = 8**, **d̄ ≈ 16** |
| Grid2D | `grid2d;N=<N>;p=1` | ⌊√(2^N)⌋ × ⌊√(2^N)⌋ grid, **d̄ ≈ 4** |
| RDG2D | `rdg2d;N=<N>` | Delaunay triangulation, **d̄ ≈ 6**; requires CGAL |

**Expected outcome:** Peak RSS grows sub-linearly (O(m/k) = O(n) for fixed d̄ and k). Init time should scale sub-linearly or remain approximately constant (generator-dependent). Stream time should grow linearly with m.

---

## CSV Schema

All result files share the same column layout:

| Column | Type | Description |
|--------|------|-------------|
| `options` | string | KaGen options string passed to the binary, e.g. `gnm-undirected;N=20;M=23` |
| `mode` | string | `inmemory` or `streaming` |
| `chunks` | int | Chunk count k (always 1 for in-memory runs) |
| `peak_rss_bytes` | int | Peak RSS of the process after generation (bytes) |
| `baseline_rss_bytes` | int | Peak RSS before generation – after MPI init (bytes) |
| `init_sec` | float | Time for `Initialize()` (streaming); 0 for in-memory |
| `stream_sec` | float | Time for `StreamEdges()` (streaming) or full generation (in-memory) |
| `wall_sec` | float | Total wall-clock time: `init_sec + stream_sec` |
| `edge_count` | int | Total edge count summed across all MPI ranks |
| `num_pes` | int | Number of MPI processes (always 1 in these experiments) |

---

## Building

```bash
# From the repository root
cmake -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DKAGEN_BUILD_EXPERIMENTS=ON
cmake --build build --target memory_benchmark -j$(nproc)
```

To include the Delaunay generator (RDG2D), CGAL must be available and detected by CMake.

---

## Running

Each script takes one optional positional argument (path to the binary):

```bash
cd experiments

# Experiment 1 – ~5 sizes × 6 generators × 2 modes = ~60 runs
./run_exp1_scaling.sh ../build/experiments/memory_benchmark

# Experiment 2 – ~10 chunk counts × 5 generators × 2 modes = ~110 runs
./run_exp2_chunks.sh  ../build/experiments/memory_benchmark

# Experiment 3 – ~5 sizes × 6 generators × 1 mode = ~30 runs
./run_exp3_generators.sh ../build/experiments/memory_benchmark
```

Logs are written alongside each CSV (`results/exp*.log`). Failed runs are skipped with a warning and do not abort the script.

---

## Analysis

Requires Python ≥ 3.9 with `pandas`, `matplotlib`, `numpy`.

```bash
# All experiments, PDF output
python3 analyze.py

# Single experiment, PNG, interactive display
python3 analyze.py --exp 2 --format png --show
```

### Output figures

| File | Content |
|------|---------|
| `exp1_scaling_combined.pdf` | Peak RSS vs N, all generators side-by-side (in-memory vs. streaming k=32) |
| `exp1_scaling_{generator}.pdf` | Peak RSS vs N, one file per generator |
| `exp1_timing.pdf` | Wall time vs N |
| `exp2_chunks.pdf` | Peak RSS vs k with in-memory baseline and O(1/k) reference |
| `exp2_chunks_ratio.pdf` | Streaming / in-memory memory ratio vs k |
| `exp2_timing.pdf` | Wall time vs k |
| `exp2_timing_breakdown.pdf` | Init time vs stream time vs k |
| `exp3_size_scaling.pdf` | Peak RSS vs N (streaming k=32 only) with O(m/k) reference |
| `exp3_timing_breakdown.pdf` | Init time vs stream time vs N |
