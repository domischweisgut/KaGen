/**
 * memory_benchmark.cpp
 *
 * Measures peak resident set size (RSS) for KaGen graph generation in
 * both in-memory and streaming modes.
 *
 * Usage:
 *   mpirun -np <P> ./memory_benchmark <options_string> <mode> [chunks]
 *
 *   <options_string>  KaGen options, e.g. "gnm-undirected;N=20;M=24"
 *   <mode>            "inmemory" or "streaming"
 *   [chunks]          Chunks per PE for streaming mode (default: 32)
 *
 * Output (CSV row, stdout, only from rank 0):
 *   options,mode,chunks,peak_rss_bytes,baseline_rss_bytes,init_sec,stream_sec,wall_sec,edge_count,num_pes
 */

#include <kagen.h>
#include <mpi.h>

#include <chrono>
#include <cstdlib>
#include <iostream>
#include <string>
#include <sys/resource.h>

// Returns the process-lifetime peak RSS in bytes.
// On macOS ru_maxrss is already in bytes; on Linux it is in kilobytes.
static long GetPeakRSSBytes() {
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
#ifdef __APPLE__
    return static_cast<long>(ru.ru_maxrss);
#else
    return static_cast<long>(ru.ru_maxrss) * 1024L;
#endif
}

int main(int argc, char* argv[]) {
    MPI_Init(&argc, &argv);

    int rank, size;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    if (argc < 3) {
        if (rank == 0) {
            std::cerr
                << "Usage: " << argv[0]
                << " <options_string> <mode: inmemory|streaming> [chunks=32]\n"
                << "Example: " << argv[0]
                << " 'gnm-undirected;N=20;M=24' streaming 32\n";
        }
        MPI_Finalize();
        return 1;
    }

    const std::string options = argv[1];
    const std::string mode    = argv[2];
    const int         chunks  = (argc >= 4) ? std::atoi(argv[3]) : 32;

    // Baseline: RSS consumed before any generation (MPI + library init).
    const long rss_baseline = GetPeakRSSBytes();

    unsigned long long edge_count = 0;
    double init_sec = 0.0, stream_sec = 0.0;

    using Clock = std::chrono::steady_clock;

    if (mode == "streaming") {
        kagen::sKaGen gen(options, chunks, MPI_COMM_WORLD);

        const auto t0 = Clock::now();
        gen.Initialize();
        const auto t1 = Clock::now();
        gen.StreamEdges(
            [&](kagen::SInt /*u*/, kagen::SInt /*v*/) { ++edge_count; },
            kagen::StreamingMode::ALL
        );
        const auto t2 = Clock::now();

        init_sec   = std::chrono::duration<double>(t1 - t0).count();
        stream_sec = std::chrono::duration<double>(t2 - t1).count();

    } else if (mode == "inmemory") {
        kagen::KaGen gen(MPI_COMM_WORLD);
        gen.EnableOutput(false); // suppress built-in timing/statistics output

        const auto t0 = Clock::now();
        kagen::Graph graph = gen.GenerateFromOptionString(options);
        const auto t1 = Clock::now();

        edge_count = static_cast<unsigned long long>(graph.NumberOfLocalEdges());
        // No API-level init/stream split for in-memory; attribute all time to stream_sec.
        stream_sec = std::chrono::duration<double>(t1 - t0).count();

    } else {
        if (rank == 0) {
            std::cerr << "Unknown mode '" << mode
                      << "'. Expected 'inmemory' or 'streaming'.\n";
        }
        MPI_Finalize();
        return 1;
    }

    const double wall = init_sec + stream_sec;
    const long   rss   = GetPeakRSSBytes();

    // Aggregate across all PEs: max RSS (worst-case PE), max times, sum of edges.
    long               global_rss_max   = 0;
    long               global_rss_base  = 0;
    unsigned long long global_edges     = 0;
    double             global_init_sec  = 0.0;
    double             global_stream_sec = 0.0;
    double             global_wall      = 0.0;

    MPI_Reduce(&rss,          &global_rss_max,    1, MPI_LONG,               MPI_MAX, 0, MPI_COMM_WORLD);
    MPI_Reduce(&rss_baseline, &global_rss_base,   1, MPI_LONG,               MPI_MAX, 0, MPI_COMM_WORLD);
    MPI_Reduce(&edge_count,   &global_edges,      1, MPI_UNSIGNED_LONG_LONG, MPI_SUM, 0, MPI_COMM_WORLD);
    MPI_Reduce(&init_sec,     &global_init_sec,   1, MPI_DOUBLE,             MPI_MAX, 0, MPI_COMM_WORLD);
    MPI_Reduce(&stream_sec,   &global_stream_sec, 1, MPI_DOUBLE,             MPI_MAX, 0, MPI_COMM_WORLD);
    MPI_Reduce(&wall,         &global_wall,       1, MPI_DOUBLE,             MPI_MAX, 0, MPI_COMM_WORLD);

    if (rank == 0) {
        // CSV columns:
        //   options            – the options string (quoted)
        //   mode               – inmemory | streaming
        //   chunks             – chunks parameter (1 for inmemory runs)
        //   peak_rss_bytes     – max peak RSS across PEs (bytes)
        //   baseline_rss_bytes – RSS before generation (bytes), for delta computation
        //   init_sec           – time for Initialize() phase (0 for inmemory)
        //   stream_sec         – time for StreamEdges() / GenerateFromOptionString()
        //   wall_sec           – total wall-clock seconds (init_sec + stream_sec)
        //   edge_count         – total edges across all PEs
        //   num_pes            – MPI communicator size
        std::cout
            << '"' << options << '"' << ','
            << mode << ','
            << chunks << ','
            << global_rss_max << ','
            << global_rss_base << ','
            << global_init_sec << ','
            << global_stream_sec << ','
            << global_wall << ','
            << global_edges << ','
            << size << '\n';
    }

    MPI_Finalize();
    return 0;
}
