#!/usr/bin/env python3
"""
analyze.py – Parse experiment CSV results and produce publication-quality plots.

Usage:
    python3 analyze.py                      # process all three experiments
    python3 analyze.py --exp 1              # only experiment 1
    python3 analyze.py --show               # display figures interactively
    python3 analyze.py --format png         # save as PNG instead of PDF

Figures produced (saved in results/figures/):
    exp1_scaling_{generator}.pdf  – memory vs graph size per generator
    exp1_scaling_combined.pdf     – all generators on one canvas
    exp2_chunks.pdf               – memory vs chunk count with O(1/k) reference
    exp3_generators.pdf           – cross-generator bar chart
"""

import argparse
import math
import re
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np
import pandas as pd

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

RESULTS_DIR = Path("results")
FIGURES_DIR = RESULTS_DIR / "figures"

COLORS = {
    "inmemory":      "#e41a1c",  # red
    "streaming_8":   "#377eb8",  # blue
    "streaming_32":  "#4daf4a",  # green
    "streaming_128": "#ff7f00",  # orange
    "streaming_256": "#984ea3",  # purple
    "streaming_512": "#a65628",  # brown
}

MODE_LABEL = {
    "inmemory":      "In-memory",
    "streaming_8":   "Streaming k=8",
    "streaming_32":  "Streaming k=32",
    "streaming_128": "Streaming k=128",
    "streaming_256": "Streaming k=256",
    "streaming_512": "Streaming k=512",
}


def bytes_to_mib(b):
    return b / (1024 ** 2)


def parse_options(opts_str: str) -> dict:
    """Extract key=value pairs from a KaGen options string like 'gnm-undirected;N=20;M=24'."""
    parts = opts_str.strip('"').split(";")
    result = {"generator": parts[0]}
    for p in parts[1:]:
        if "=" in p:
            k, v = p.split("=", 1)
            try:
                result[k] = float(v)
            except ValueError:
                result[k] = v
    return result


def load_csv(path: Path) -> pd.DataFrame:
    if not path.exists():
        print(f"  File not found: {path}  (skipping)", file=sys.stderr)
        return pd.DataFrame()

    df = pd.read_csv(path, quotechar='"')
    df.columns = df.columns.str.strip()

    # Derive generator name and key parameters
    parsed = df["options"].apply(parse_options)
    df["generator"] = parsed.apply(lambda d: d.get("generator", "unknown"))
    df["N"]         = parsed.apply(lambda d: int(d["N"]) if "N" in d else None)
    df["M"]         = parsed.apply(lambda d: int(d["M"]) if "M" in d else None)

    # Derived columns
    df["n"]              = df["N"].apply(lambda x: 2 ** x if x is not None else None)
    df["peak_rss_mib"]   = bytes_to_mib(df["peak_rss_bytes"])
    df["delta_rss_mib"]  = bytes_to_mib(df["peak_rss_bytes"] - df["baseline_rss_bytes"])
    df["series"]         = df.apply(
        lambda r: r["mode"] if r["mode"] == "inmemory"
                  else f"streaming_{int(r['chunks'])}",
        axis=1,
    )
    return df


def save_fig(fig, name: str, fmt: str):
    FIGURES_DIR.mkdir(parents=True, exist_ok=True)
    path = FIGURES_DIR / f"{name}.{fmt}"
    fig.savefig(path, bbox_inches="tight", dpi=150)
    print(f"  Saved: {path}")


# ---------------------------------------------------------------------------
# Experiment 1 – Memory scaling with graph size
# ---------------------------------------------------------------------------

def plot_exp1(df: pd.DataFrame, fmt: str, show: bool):
    if df.empty:
        return

    generators = df["generator"].unique()

    # --- Combined figure: one subplot per generator ---
    ncols = min(3, len(generators))
    nrows = math.ceil(len(generators) / ncols)
    fig, axes = plt.subplots(nrows, ncols, figsize=(5 * ncols, 4 * nrows),
                              squeeze=False, sharey=False)
    fig.suptitle("Memory Scaling with Graph Size\n(avg degree ≈ 16)", fontsize=13)

    for idx, gen in enumerate(generators):
        ax = axes[idx // ncols][idx % ncols]
        sub = df[df["generator"] == gen].sort_values("N")

        series_list = sub["series"].unique()
        for series in sorted(series_list, key=lambda s: (s != "inmemory", s)):
            row = sub[sub["series"] == series]
            label = MODE_LABEL.get(series, series)
            color = COLORS.get(series, "gray")
            ls    = "-" if series == "inmemory" else "--"
            ax.plot(row["N"], row["peak_rss_mib"], marker="o", label=label,
                    color=color, linestyle=ls, linewidth=1.8, markersize=4)

        # Theoretical O(m) reference (in-memory, edge list = 16 bytes per directed edge)
        ns = sub["N"].dropna().unique()
        if len(ns):
            ns_sorted = np.sort(ns.astype(int))
            # m_approx = 8 * n (avg deg 16 → 8 directed edges per node for undirected)
            # edge list: 2 * SInt (8 bytes each) = 16 bytes per directed edge
            theory_mib = bytes_to_mib(16 * 8 * 2.0 ** ns_sorted)
            ax.plot(ns_sorted, theory_mib, color="black", linestyle=":", linewidth=1,
                    label="Theoretical (edge list)")

        ax.set_title(gen, fontsize=10)
        ax.set_xlabel("log₂(n)  [N]")
        ax.set_ylabel("Peak RSS (MiB)")
        ax.set_yscale("log")
        ax.xaxis.set_major_locator(ticker.MultipleLocator(2))
        ax.legend(fontsize=7, loc="upper left")
        ax.grid(True, which="both", alpha=0.3)

    # Hide unused subplots
    for idx in range(len(generators), nrows * ncols):
        axes[idx // ncols][idx % ncols].set_visible(False)

    fig.tight_layout()
    save_fig(fig, "exp1_scaling_combined", fmt)

    # --- Individual figures per generator ---
    for gen in generators:
        sub = df[df["generator"] == gen].sort_values("N")
        fig2, ax2 = plt.subplots(figsize=(6, 4))
        ax2.set_title(f"{gen} – Memory vs Graph Size", fontsize=11)

        for series in sorted(sub["series"].unique(), key=lambda s: (s != "inmemory", s)):
            row = sub[sub["series"] == series]
            color = COLORS.get(series, "gray")
            ls    = "-" if series == "inmemory" else "--"
            ax2.plot(row["N"], row["peak_rss_mib"], marker="o",
                     label=MODE_LABEL.get(series, series),
                     color=color, linestyle=ls, linewidth=1.8, markersize=5)

        ax2.set_xlabel("log₂(n)  [N]")
        ax2.set_ylabel("Peak RSS (MiB)")
        ax2.set_yscale("log")
        ax2.legend(fontsize=9)
        ax2.grid(True, which="both", alpha=0.3)
        fig2.tight_layout()
        safe_gen = re.sub(r"[^a-zA-Z0-9_]", "_", gen)
        save_fig(fig2, f"exp1_scaling_{safe_gen}", fmt)
        plt.close(fig2)

    if show:
        plt.show()
    plt.close(fig)


# ---------------------------------------------------------------------------
# Experiment 2 – Memory vs chunk count
# ---------------------------------------------------------------------------

def plot_exp2(df: pd.DataFrame, fmt: str, show: bool):
    if df.empty:
        return

    generators = df["generator"].unique()

    fig, axes = plt.subplots(1, len(generators),
                              figsize=(5 * len(generators), 4),
                              squeeze=False)
    fig.suptitle("Peak Memory vs Number of Streaming Chunks", fontsize=13)

    for idx, gen in enumerate(generators):
        ax = axes[0][idx]
        sub = df[df["generator"] == gen]

        # In-memory baseline (horizontal line)
        im = sub[sub["mode"] == "inmemory"]
        if not im.empty:
            rss_inmem = im["peak_rss_mib"].values[0]
            ax.axhline(rss_inmem, color=COLORS["inmemory"], linestyle="-",
                       linewidth=1.8, label="In-memory baseline")

        # Streaming: only keep rows where mode == streaming, group by chunk count
        st = sub[sub["mode"] == "streaming"].sort_values("chunks")
        if not st.empty:
            ax.plot(st["chunks"], st["peak_rss_mib"], marker="o",
                    color="#377eb8", linewidth=1.8, markersize=5,
                    label="Streaming")

            # Theoretical O(1/k) curve anchored at k=1 streaming value
            k1 = st[st["chunks"] == 1]
            if not k1.empty:
                rss_k1 = k1["peak_rss_mib"].values[0]
                ks = np.geomspace(st["chunks"].min(), st["chunks"].max(), 100)
                ax.plot(ks, rss_k1 / ks, color="gray", linestyle=":",
                        linewidth=1.2, label="O(1/k) reference")

        ax.set_title(gen, fontsize=10)
        ax.set_xlabel("Chunk count (k)")
        ax.set_ylabel("Peak RSS (MiB)")
        ax.set_xscale("log", base=2)
        ax.set_yscale("log")
        ax.xaxis.set_major_formatter(ticker.ScalarFormatter())
        ax.legend(fontsize=8)
        ax.grid(True, which="both", alpha=0.3)

    fig.tight_layout()
    save_fig(fig, "exp2_chunks", fmt)
    if show:
        plt.show()
    plt.close(fig)

    # --- Memory reduction ratio ---
    fig2, axes2 = plt.subplots(1, len(generators),
                                figsize=(5 * len(generators), 4),
                                squeeze=False)
    fig2.suptitle("Memory Reduction Ratio  (streaming / in-memory)", fontsize=13)

    for idx, gen in enumerate(generators):
        ax = axes2[0][idx]
        sub = df[df["generator"] == gen]

        im_rss = sub[sub["mode"] == "inmemory"]["peak_rss_mib"]
        if im_rss.empty:
            continue
        rss_base = im_rss.values[0]

        st = sub[sub["mode"] == "streaming"].sort_values("chunks")
        if st.empty:
            continue

        ratio = st["peak_rss_mib"].values / rss_base
        ks    = st["chunks"].values

        ax.plot(ks, ratio, marker="o", color="#4daf4a", linewidth=1.8, markersize=5,
                label="Actual ratio")
        ax.plot(ks, 1.0 / ks * ks[0] * ratio[0], color="gray", linestyle=":",
                linewidth=1.2, label="Ideal O(1/k)")
        ax.axhline(1.0, color=COLORS["inmemory"], linestyle="--", linewidth=1,
                   label="In-memory = 1.0")

        ax.set_title(gen, fontsize=10)
        ax.set_xlabel("Chunk count (k)")
        ax.set_ylabel("Ratio (streaming / in-memory)")
        ax.set_xscale("log", base=2)
        ax.xaxis.set_major_formatter(ticker.ScalarFormatter())
        ax.legend(fontsize=8)
        ax.grid(True, which="both", alpha=0.3)

    fig2.tight_layout()
    save_fig(fig2, "exp2_chunks_ratio", fmt)
    if show:
        plt.show()
    plt.close(fig2)


# ---------------------------------------------------------------------------
# Experiment 3 – Cross-generator comparison
# ---------------------------------------------------------------------------

def plot_exp3(df: pd.DataFrame, fmt: str, show: bool):
    if df.empty:
        return

    generators = df["generator"].unique()
    x = np.arange(len(generators))
    width = 0.18

    # Series to display
    series_to_plot = ["inmemory", "streaming_8", "streaming_32", "streaming_128"]

    fig, ax = plt.subplots(figsize=(max(8, 2 * len(generators)), 5))
    ax.set_title("Peak RSS by Generator  (N=20, avg degree ≈ 16)", fontsize=12)

    for si, series in enumerate(series_to_plot):
        rss_vals = []
        for gen in generators:
            row = df[(df["generator"] == gen) & (df["series"] == series)]
            rss_vals.append(row["peak_rss_mib"].values[0] if not row.empty else 0)

        offset = (si - len(series_to_plot) / 2 + 0.5) * width
        ax.bar(x + offset, rss_vals, width=width * 0.9,
               label=MODE_LABEL.get(series, series),
               color=COLORS.get(series, "gray"))

    ax.set_xticks(x)
    ax.set_xticklabels(generators, rotation=20, ha="right", fontsize=9)
    ax.set_ylabel("Peak RSS (MiB)")
    ax.set_yscale("log")
    ax.legend(fontsize=9, loc="upper right")
    ax.grid(True, axis="y", alpha=0.3)
    fig.tight_layout()
    save_fig(fig, "exp3_generators", fmt)

    # --- Table: reduction factor per generator ---
    print("\n--- Generator comparison: memory reduction factor (inmemory / streaming) ---")
    print(f"{'Generator':<25} {'In-mem (MiB)':>14}", end="")
    for s in ["streaming_8", "streaming_32", "streaming_128"]:
        print(f"  {MODE_LABEL.get(s, s):>18}", end="")
    print()

    for gen in generators:
        sub = df[df["generator"] == gen]
        im  = sub[sub["series"] == "inmemory"]["peak_rss_mib"]
        if im.empty:
            continue
        im_rss = im.values[0]
        print(f"{gen:<25} {im_rss:>14.1f}", end="")
        for s in ["streaming_8", "streaming_32", "streaming_128"]:
            row = sub[sub["series"] == s]["peak_rss_mib"]
            if not row.empty:
                ratio = im_rss / row.values[0]
                print(f"  {ratio:>17.1f}x", end="")
            else:
                print(f"  {'N/A':>17}", end="")
        print()

    if show:
        plt.show()
    plt.close(fig)


# ---------------------------------------------------------------------------
# Timing analysis (shared across experiments)
# ---------------------------------------------------------------------------

def plot_timing(df: pd.DataFrame, title: str, x_col: str, xlabel: str,
                fmt: str, name: str, show: bool):
    if df.empty or "wall_sec" not in df.columns:
        return

    generators = df["generator"].unique()

    fig, axes = plt.subplots(1, len(generators),
                              figsize=(5 * len(generators), 4),
                              squeeze=False)
    fig.suptitle(title, fontsize=13)

    for idx, gen in enumerate(generators):
        ax = axes[0][idx]
        sub = df[df["generator"] == gen]

        for series in sorted(sub["series"].unique(), key=lambda s: (s != "inmemory", s)):
            row = sub[sub["series"] == series].sort_values(x_col)
            if row.empty:
                continue
            color = COLORS.get(series, "gray")
            ls    = "-" if series == "inmemory" else "--"
            ax.plot(row[x_col], row["wall_sec"], marker="s",
                    label=MODE_LABEL.get(series, series),
                    color=color, linestyle=ls, linewidth=1.8, markersize=4)

        ax.set_title(gen, fontsize=10)
        ax.set_xlabel(xlabel)
        ax.set_ylabel("Wall time (s)")
        ax.set_yscale("log")
        ax.legend(fontsize=7)
        ax.grid(True, which="both", alpha=0.3)

    fig.tight_layout()
    save_fig(fig, name, fmt)
    if show:
        plt.show()
    plt.close(fig)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Analyze KaGen memory experiments")
    parser.add_argument("--exp", type=int, choices=[1, 2, 3],
                        help="Run only this experiment number (default: all)")
    parser.add_argument("--show", action="store_true",
                        help="Display figures interactively")
    parser.add_argument("--format", default="pdf", choices=["pdf", "png", "svg"],
                        help="Output figure format (default: pdf)")
    args = parser.parse_args()

    FIGURES_DIR.mkdir(parents=True, exist_ok=True)

    run_all = args.exp is None

    # ---- Experiment 1 ----
    if run_all or args.exp == 1:
        print("=== Experiment 1: Scaling ===")
        df1 = load_csv(RESULTS_DIR / "exp1_scaling.csv")
        plot_exp1(df1, args.format, args.show)
        plot_timing(df1, "Generation Time vs Graph Size", "N", "log₂(n) [N]",
                    args.format, "exp1_timing", args.show)

    # ---- Experiment 2 ----
    if run_all or args.exp == 2:
        print("\n=== Experiment 2: Chunks ===")
        df2 = load_csv(RESULTS_DIR / "exp2_chunks.csv")
        plot_exp2(df2, args.format, args.show)
        plot_timing(df2, "Generation Time vs Chunk Count", "chunks", "Chunk count (k)",
                    args.format, "exp2_timing", args.show)

    # ---- Experiment 3 ----
    if run_all or args.exp == 3:
        print("\n=== Experiment 3: Generators ===")
        df3 = load_csv(RESULTS_DIR / "exp3_generators.csv")
        plot_exp3(df3, args.format, args.show)

    print("\nAll done.")


if __name__ == "__main__":
    main()
