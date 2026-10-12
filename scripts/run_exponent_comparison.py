#!/usr/bin/env python3
"""Record direct-exponent final pipelines, tile probes and streaming sieves."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--billion-binary", type=Path, required=True)
    parser.add_argument("--build-command", required=True)
    parser.add_argument("--billion-build-command", required=True)
    parser.add_argument("--dependency-root", type=Path, required=True)
    parser.add_argument("--order-oracle", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("results/exponent_comparison.json"))
    parser.add_argument("--skip-billion", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    dependency = args.dependency_root.resolve()
    binary = args.binary.resolve()
    billion = args.billion_binary.resolve()
    oracle = json.loads(args.order_oracle.read_text())
    dependency_paths = [*dependency.glob("src/ml/metal/**/*.cr"),
                        *dependency.glob("src/ml/core/**/*.cr"),
                        dependency / "build/bridge.o"]
    output = {
        "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
        "hardware": "Apple M2 Max, 64 GiB unified memory, one host",
        "os": platform.platform(),
        "compiler": subprocess.check_output(["crystal", "--version"], text=True).strip(),
        "gmp_version": subprocess.check_output(["pkg-config", "--modversion", "gmp"], text=True).strip(),
        "host_load_average_before_run": list(os.getloadavg()),
        "build_command": args.build_command,
        "billion_build_command": args.billion_build_command,
        "binary_sha256": sha256(binary),
        "billion_binary_sha256": sha256(billion),
        "source_sha256": {str(p.relative_to(root)): sha256(p)
                          for p in sorted(root.rglob("*"))
                          if p.is_file() and p.suffix in (".cr", ".metal", ".ptx", ".py")},
        "dependency_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=dependency, text=True).strip(),
        "dependency_source_sha256": {str(p.relative_to(dependency)): sha256(p)
                                      for p in sorted(dependency_paths) if p.is_file()},
        "order_oracle": {"file_sha256": sha256(args.order_oracle),
                         "counts": oracle["counts"], "provenance": oracle["provenance"]},
        "author_generator": {
            "forum_url": "https://forum.crystal-lang.org/t/optimal-mersenne-primes-search-using-modular-groups/9207/5",
            "schedule": "Consecutive odd q, M_q=(1<<q)-1, preserved including composite q.",
            "normalization": "Exact author Crystal primes-utils unavailable; all finite final paths share GMP probable-prime(25). Floating-log reporting and console output excluded.",
            "source_record": "results/jabari_comparison.json author_sources identifies the inspected forum snapshot and PDF.",
            "source_record_sha256": sha256(root / "results/jabari_comparison.json"),
        },
        "limitations": [
            "Small-factor screening and shared GMP probable-prime classification, not primality certification or a GIMPS comparison.",
            "Full variants time plan preparation; prepared variants reuse one plan. All GPU calls include allocation, transfer, dispatch, synchronization, readback and result mapping.",
            "GPU initialization/kernel compilation, equality checks and output excluded; first-call costs separately recorded.",
            "One M2 Max with uncontrolled background load and temperature; medians and raw repeats are exploratory measurements.",
            "Tile selection is a measured tuning probe, not an automatic CPU/GPU policy or a universal optimum.",
            "Billion-exponent stream executes filtering only; growing M_q BigInts and GMP tests make a full-search linear extrapolation invalid.",
        ],
        "final_cases": [], "tile_cases": [], "scale_cases": [], "billion_sieves": [],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def save():
        args.output.write_text(json.dumps(output, indent=2) + "\n")

    def run(section, command):
        load = list(os.getloadavg())
        completed = subprocess.run(command, cwd=root, text=True, stdout=subprocess.PIPE, check=True)
        row = json.loads(completed.stdout)
        # The executed harness's final-mode equality concerns classification
        # states, not whole Result records. Give the saved field its exact scope.
        if section == "final_cases":
            row["all_final_states_equal"] = row.pop("all_outputs_equal")
        row["run_command"] = command
        row["host_load_average_before_case"] = load
        row["host_load_average_after_case"] = list(os.getloadavg())
        output[section].append(row)
        save()
        if section == "billion_sieves":
            medians = {k: row[k]["median_ms"] for k in ("cpu_prepared", "metal_prepared")}
        else:
            medians = {k: v["median_ms"] for k, v in row["methods"].items()}
        print(json.dumps({"section": section, "count": row["count"],
                          "start_q": row["start_q"], "tile": row["tile_size"],
                          "active_orders": row["active_order_count"], "medians_ms": medians}), flush=True)
        return row

    # Tune only the filter stage; all full final-pipeline paths use tile4096
    # so a noisy winner from this probe cannot bias the shared-GMP comparison.
    for count, start in ((32, 17), (512, 33), (1024, 17), (2040, 17)):
        run("final_cases", [str(binary), "final", str(count), str(start), "5", "4096"])
    for tile in (256, 1024, 4096, 16384, 65536):
        run("tile_cases", [str(binary), "filter", "1048576", "17", "5", str(tile)])
    chosen = min(output["tile_cases"], key=lambda row: row["methods"]["metal_direct_prepared"]["median_ms"])["tile_size"]
    output["selected_large_window_tile"] = chosen
    output["selection_scope"] = "Lowest median prepared Metal filter at 1,048,576 exponents among five tested tiles; verify scaling separately."
    save()
    for count, start in ((65536, 17), (1048576, 136279841),
                         (4194304, 17), (16777216, 17)):
        run("scale_cases", [str(binary), "filter", str(count), str(start), "5", str(chosen)])
    if not args.skip_billion:
        run("billion_sieves", [str(billion), "1000000000", "17", "3", str(chosen)])
    output["host_load_average_after_run"] = list(os.getloadavg())
    save()
    print(f"saved {args.output}", flush=True)


if __name__ == "__main__":
    main()
