#!/usr/bin/env python3
"""Record normalized generator comparisons and a direct billion-item sieve."""
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
    parser.add_argument("--paper", type=Path, required=True)
    parser.add_argument("--forum-snapshot", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("results/jabari_comparison.json"))
    parser.add_argument("--skip-billion", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    dependency = args.dependency_root.resolve()
    binary = args.binary.resolve()
    billion_binary = args.billion_binary.resolve()
    posts = json.loads(args.forum_snapshot.read_text())["post_stream"]["posts"]
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
        "build_provenance": "Caller supplied actual build commands; SHA256 identifies the executed binaries.",
        "binary_sha256": sha256(binary),
        "billion_binary_sha256": sha256(billion_binary),
        "dependency_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=dependency, text=True).strip(),
        "dependency_source_sha256": {
            str(p.relative_to(dependency)): sha256(p)
            for p in sorted(dependency_paths) if p.is_file()
        },
        "source_sha256": {
            str(p.relative_to(root)): sha256(p)
            for p in sorted(root.rglob("*"))
            if p.is_file() and p.suffix in (".cr", ".metal", ".ptx", ".py")
        },
        "author_sources": {
            "paper_filename": args.paper.name,
            "paper_sha256": sha256(args.paper),
            "paper_code_page": 6,
            "forum_url": "https://forum.crystal-lang.org/t/optimal-mersenne-primes-search-using-modular-groups/9207",
            "forum_snapshot_sha256": sha256(args.forum_snapshot),
            "author_posts": [{"post_number": p["post_number"], "updated_at": p["updated_at"],
                              "version": p["version"], "cooked_sha256": hashlib.sha256(p["cooked"].encode()).hexdigest()}
                             for p in posts if p["username"] == "jzakiya"],
            "unavailable_dependency": "Exact 2026 Crystal primes-utils is not present in the inspected public sources; GMP(25) substituted consistently.",
        },
        "limitations": [
            "Normalized finite adapters, not untouched execution of the author's unavailable Crystal primality backend.",
            "Final-state comparisons use one GMP probable-prime test; not primality certificates or a GIMPS comparison.",
            "Dense progression seed fixed; the author's dynamic seed reset after a hit is excluded.",
            "Current Mersenne-only candidate sizes grow: no constant-cost billion-exponent extrapolation is valid.",
            "The UInt64 compatible-k recurrence limits each rebased run to 32 consecutive Mersenne exponents; the sieve API accepts larger arbitrary arrays. That overhead is timed.",
            "One M2 Max; five rotating/reversed repetitions, two warmups, no temperature or background-load control.",
            "Billion small-factor run uses a reused plan and tile 4096; equality/counting outside timing, no final primality tests.",
        ],
        "cases": [], "billion_sieves": [],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def save():
        args.output.write_text(json.dumps(output, indent=2) + "\n")

    # Five equally weighted strata of the fixed p=31, k=1+2*i billion range.
    sample_count = 262144
    strata = [(1 + 2 * (100_000_000 + 200_000_000 * i - sample_count // 2))
              for i in range(5)]
    cases = [("progression", 65536, 1, 17, None),
             ("progression", 65536, 1, 31, None),
             ("progression", 262144, 1, 31, None),
             ("progression", 1048576, 1, 31, None)]
    cases += [("progression", sample_count, k, 31, i) for i, k in enumerate(strata)]
    cases += [("mersenne", 32, 17, 31, None),
              ("mersenne", 512, 33, 31, None),
              ("mersenne", 1024, 17, 31, None)]
    for mode, count, start, exponent, stratum in cases:
        load_before = list(os.getloadavg())
        command = [str(binary), mode, str(count), str(start), str(exponent), "5", "65521"]
        completed = subprocess.run(command, cwd=root, text=True, capture_output=True, check=True)
        row = json.loads(completed.stdout)
        row["run_command"] = command
        row["host_load_average_before_case"] = load_before
        row["host_load_average_after_case"] = list(os.getloadavg())
        if stratum is not None:
            row["billion_estimate_stratum"] = stratum
        output["cases"].append(row)
        save()
        print(json.dumps({"mode": mode, "count": count, "start": start,
                          "exponent": exponent, "equal": row["all_final_states_equal"],
                          "methods_ms": {name: v["median_ms"] for name, v in row["methods"].items()}}), flush=True)

    sampled = [r for r in output["cases"] if "billion_estimate_stratum" in r]
    estimates = {}
    for name in sampled[0]["methods"]:
        seconds = sum(r["methods"][name]["median_ms"] / 1000 / r["count"] for r in sampled) / len(sampled) * 1_000_000_000
        estimates[name] = {"estimated_billion_seconds": seconds,
                           "stratum_billion_seconds": [r["methods"][name]["median_ms"] / 1000 / r["count"] * 1_000_000_000 for r in sampled]}
    output["fixed_progression_billion_estimate"] = {
        "count": 1_000_000_000, "exponent": 31, "start_k": 1, "last_k": 1_999_999_999,
        "sampled_candidates": sum(r["count"] for r in sampled),
        "sampling": "Five equal index strata, one 262144-candidate window at each midpoint; equal-weight mean of per-window median costs.",
        "provenance": "Extrapolated shared-GMP complete pipeline, not directly executed billion primality tests; not the author's dynamically resetting search.",
        "methods": estimates,
    }
    save()
    if not args.skip_billion:
        for exponent in (31, 136279841):
            load_before = list(os.getloadavg())
            command = [str(billion_binary), "1000000000", str(exponent), "3"]
            completed = subprocess.run(command, cwd=root, text=True, stdout=subprocess.PIPE, check=True)
            row = json.loads(completed.stdout)
            row["run_command"] = command
            row["host_load_average_before_case"] = load_before
            row["host_load_average_after_case"] = list(os.getloadavg())
            output["billion_sieves"].append(row)
            save()
            print(json.dumps({"direct_billion_exponent": exponent,
                              "equal": row["all_factor_arrays_equal"],
                              "cpu_ms": row["cpu_prepared"]["median_ms"],
                              "metal_ms": row["metal_prepared"]["median_ms"]}), flush=True)
    print(f"saved {args.output}", flush=True)


if __name__ == "__main__":
    main()
