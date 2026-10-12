#!/usr/bin/env python3
"""Collect the bounded release benchmark matrix using only Python's stdlib."""
import argparse
from datetime import date
import hashlib
import json
from pathlib import Path
import platform
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("results/benchmark.json"))
    parser.add_argument("--hardware", default="not recorded")
    parser.add_argument("--dependency-root", type=Path)
    parser.add_argument("--dependency-state", default="not recorded")
    parser.add_argument("--build-command", required=True,
                        help="Record the actual release build command; caller-supplied provenance")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    binary = args.binary.resolve()
    cases = [(n, cap, 136279841) for n in (4096, 65536, 262144)
             for cap in (97, 997, 65521)] + [(65536, 65521, 16)]
    rows = []
    for count, cap, exponent in cases:
        completed = subprocess.run(
            [str(binary), str(count), str(cap), "5", str(exponent)],
            cwd=root, text=True, capture_output=True, check=True)
        row = json.loads(completed.stdout)
        rows.append(row)
        timings = row["methods"]
        print(json.dumps({
            "count": count, "cap": cap, "exponent": exponent,
            "reference_ms": timings["reference_cpu_full"]["median_ms"],
            "cpu_full_ms": timings["cpu_window_full"]["median_ms"],
            "cpu_prepared_ms": timings["cpu_window_prepared"]["median_ms"],
            **({"metal_window_full_ms": timings["metal_window_full"]["median_ms"]}
               if "metal_window_full" in timings else {}),
        }), flush=True)

    dependency_head = None
    dependency_sources = {}
    if args.dependency_root:
        dependency_root = args.dependency_root.resolve()
        dependency_head = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=dependency_root, text=True).strip()
        paths = [*dependency_root.glob("src/ml/metal/**/*.cr"),
                 *dependency_root.glob("src/ml/cuda/**/*.cr"),
                 *dependency_root.glob("src/ml/core/**/*.cr"),
                 dependency_root / "build/bridge.o"]
        dependency_sources = {
            str(p.relative_to(dependency_root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(paths) if p.is_file()
        }
    output = {
        "date": date.today().isoformat(),
        "hardware": args.hardware,
        "os": platform.platform(),
        "compiler": subprocess.check_output(["crystal", "--version"], text=True).strip(),
        "build_command": args.build_command,
        "build_provenance": "Caller supplied command; binary hash identifies the executed artifact. The runner cannot infer its build flags.",
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "dependency_head": dependency_head,
        "dependency_worktree": args.dependency_state,
        "dependency_source_sha256": dependency_sources,
        "source_sha256": {
            str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob("*"))
            if p.is_file() and p.suffix in (".cr", ".metal", ".ptx", ".py")
        },
        "limitations": [
            "One host and one run per case: five rotating/reversed repetitions, two warmups per method. No temperature or background-load control.",
            "Small-factor sieve only; no PRP/Lucas-Lehmer pipeline or GIMPS comparison.",
            "Candidate input-array materialization and backend initialization excluded; candidate initialization recorded separately. Lazy window compilation is in untimed warmup.",
            "Prepared paths amortize factor validation and inversion. Full paths include them.",
            "Metal includes allocation, transfers, dispatch, synchronization, readback and rank mapping when dispatched. Even m with first-ranked 3 resolves on the host.",
            "Checked Metal window timing additionally includes CPU verification of returned nonzero factors; it does not check coverage or first-factor precedence.",
            "CUDA not measured or run.",
        ],
        "cases": rows,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2) + "\n")
    print(f"saved {args.output}", flush=True)


if __name__ == "__main__":
    main()
