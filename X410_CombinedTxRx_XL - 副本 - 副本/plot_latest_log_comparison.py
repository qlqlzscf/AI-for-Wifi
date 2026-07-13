from pathlib import Path
import re
import statistics

import matplotlib.pyplot as plt
import numpy as np


ALGORITHMS = ["AARF", "OLLA", "AOLLA", "QLOLLA"]


def find_latest_log(log_dir: Path, algorithm: str) -> Path:
    matches = sorted(log_dir.glob(f"run_{algorithm}_*.log"))
    if not matches:
        raise FileNotFoundError(f"No log found for {algorithm} in {log_dir}")
    return matches[-1]


def parse_log(log_path: Path) -> dict:
    text = log_path.read_text(encoding="utf-8", errors="ignore")

    feedback = re.findall(r"^Iter\s+\d+\s+\|\s+fb=(ack|arq)\s+\|", text, re.M)
    ack = sum(1 for item in feedback if item == "ack")
    arq = sum(1 for item in feedback if item == "arq")
    per = arq / (ack + arq) if (ack + arq) else 0.0

    bitrate_vals = [
        float(x)
        for x in re.findall(r"^\s+DataBitrate \(Mbps\):\s*([0-9.]+)", text, re.M)
    ]
    avg_bitrate = statistics.mean(bitrate_vals) if bitrate_vals else 0.0

    final_match = re.search(
        r"^Final state \| MCS=(\d+) AMPDU=(\d+) BWdec=(\d+) lastSNR=([0-9.]+) dB",
        text,
        re.M,
    )
    stats_match = re.search(
        r"^Stats \| fallback=(\d+) \([^)]+\), realDecode=(\d+) \(([^)]+)\), qUpdate=(\d+)",
        text,
        re.M,
    )

    return {
        "ack": ack,
        "arq": arq,
        "per": per,
        "avg_bitrate_mbps": avg_bitrate,
        "final_mcs": int(final_match.group(1)) if final_match else -1,
        "last_snr_db": float(final_match.group(4)) if final_match else 0.0,
        "real_decode_pct": stats_match.group(3) if stats_match else "N/A",
    }


def collect_latest_results():
    log_dir = Path(__file__).with_name("logs")
    results = []
    for algorithm in ALGORITHMS:
        log_path = find_latest_log(log_dir, algorithm)
        metrics = parse_log(log_path)
        metrics["algorithm"] = algorithm
        metrics["log_file"] = log_path.name
        results.append(metrics)
    return results


def main():
    results = collect_latest_results()
    algorithms = [item["algorithm"] for item in results]
    throughput = [item["avg_bitrate_mbps"] for item in results]
    per = [item["per"] for item in results]

    x = np.arange(len(algorithms))
    width = 0.62

    fig, ax1 = plt.subplots(figsize=(10, 6), dpi=150)
    ax2 = ax1.twinx()

    bars1 = ax1.bar(
        x,
        throughput,
        width=width,
        color="#5B9BD5",
        edgecolor="#1F1F1F",
        linewidth=0.8,
        label="Throughput",
    )
    bars2 = ax2.bar(
        x,
        per,
        width=width,
        color="#ED7D31",
        alpha=0.65,
        edgecolor="#1F1F1F",
        linewidth=0.8,
        label="PER",
    )

    ax1.set_title("Latest Algorithm Comparison: Throughput vs PER")
    ax1.set_xlabel("Algorithm")
    ax1.set_ylabel("Throughput (Mbps)", color="#2F75B5")
    ax2.set_ylabel("PER", color="#C55A11")

    ax1.set_xticks(x)
    ax1.set_xticklabels(algorithms)
    ax1.grid(axis="y", linestyle="--", alpha=0.25)

    ax1.set_ylim(0, max(throughput) * 1.25 + 1 if throughput else 1)
    ax2.set_ylim(0, max(per) * 1.15 + 0.02 if per else 0.1)

    for bar, val in zip(bars1, throughput):
        ax1.text(
            bar.get_x() + bar.get_width() / 2,
            bar.get_height() + 0.35,
            f"{val:.2f}",
            ha="center",
            va="bottom",
            fontsize=9,
            color="#2F75B5",
        )

    for bar, val in zip(bars2, per):
        ax2.text(
            bar.get_x() + bar.get_width() / 2,
            bar.get_height() + 0.01,
            f"{val:.2f}",
            ha="center",
            va="bottom",
            fontsize=9,
            color="#C55A11",
        )

    fig.tight_layout()

    out_path = Path(__file__).with_name("latest_log_comparison.png")
    fig.savefig(out_path, bbox_inches="tight")
    print(f"Saved plot to: {out_path}")
    for item in results:
        print(
            f"{item['algorithm']}: "
            f"throughput={item['avg_bitrate_mbps']:.2f} Mbps, "
            f"PER={item['per']:.2f}, "
            f"log={item['log_file']}"
        )


if __name__ == "__main__":
    main()
