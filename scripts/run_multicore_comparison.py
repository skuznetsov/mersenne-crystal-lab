#!/usr/bin/env python3
"""Record matched serial and multicore Mersenne pipelines on one host."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import time


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_snapshot(root):
    return {str(p.relative_to(root)): sha256(p) for p in sorted(root.rglob("*"))
            if p.is_file() and p.suffix in (".cr", ".metal", ".ptx", ".py")}


def dependency_snapshot(root):
    paths = sorted([*root.glob("src/**/*.cr"), root / "build/bridge.o"])
    return {str(p.relative_to(root)): sha256(p) for p in paths if p.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--dependency-root", type=Path, required=True)
    parser.add_argument("--cache-dir", type=Path, default=Path("/private/tmp/mpgs-multicore-cache"))
    parser.add_argument("--output", type=Path, default=Path("results/multicore_comparison.json"))
    parser.add_argument("--cases", default="32:17,512:33,1024:17,2040:17")
    parser.add_argument("--workers", default="1,2,4,8,12")
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--tile", type=int, default=4096)
    parser.add_argument("--chunk", type=int, default=1)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    dependency = args.dependency_root.resolve()
    binary = args.binary.resolve()
    args.output = args.output.resolve()
    author_record = root / "results/jabari_comparison.json"
    if dependency != (root / "../../Crystal/cogni-ml").resolve():
        parser.error("dependency-root must match the relative import in metal_backend.cr")
    bridge = dependency / "build/bridge.o"
    if not bridge.is_file():
        parser.error(f"build the cogni-ml Metal bridge first: {bridge}")
    if root in binary.parents or dependency in binary.parents:
        parser.error("binary must be outside the source and dependency trees")
    if (args.output.suffix != ".json" or args.output == binary or args.output == author_record
            or dependency in args.output.parents or root / ".git" in args.output.parents):
        parser.error("output must be a JSON result path outside protected inputs")
    if args.output.exists() and args.output != root / "results/multicore_comparison.json":
        parser.error("refusing to overwrite an existing file other than the multicore result")
    cases = [tuple(map(int, case.split(":"))) for case in args.cases.split(",")]
    if any(len(case) != 2 for case in cases):
        parser.error("cases must be count:start pairs")

    source_hashes = source_snapshot(root)
    dependency_hashes = dependency_snapshot(dependency)
    # Build here, rather than attaching current source hashes to an arbitrary
    # previously compiled binary. Argument lists avoid shell interpretation.
    build_command = ["crystal", "build", "multicore_benchmark.cr", "--release", "--mcpu=native",
                     f"--link-flags={bridge} -lc++ -fuse-ld=/usr/bin/ld", "-o", str(binary)]
    build_environment = os.environ.copy()
    build_environment["CRYSTAL_CACHE_DIR"] = str(args.cache_dir.resolve())
    binary.parent.mkdir(parents=True, exist_ok=True)
    build_started = time.monotonic()
    subprocess.run(build_command, cwd=root, env=build_environment, check=True)
    build_elapsed = time.monotonic() - build_started
    if source_snapshot(root) != source_hashes or dependency_snapshot(dependency) != dependency_hashes:
        raise RuntimeError("source/dependency changed while building")
    binary_hash = sha256(binary)
    linked_libraries = subprocess.check_output(["otool", "-L", str(binary)], text=True)
    gmp_paths = [Path(line.strip().split(" (", 1)[0]) for line in linked_libraries.splitlines()[1:]
                 if "libgmp" in line and line.strip().startswith("/")]
    linked_gmp_hashes = {str(p.resolve()): sha256(p.resolve()) for p in gmp_paths if p.is_file()}
    output = {
        "run_status": "in_progress",
        "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
        "hardware": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
        "cpu_topology": subprocess.check_output(
            ["sysctl", "hw.ncpu", "hw.physicalcpu", "hw.logicalcpu",
             "hw.perflevel0.physicalcpu", "hw.perflevel1.physicalcpu"], text=True).strip(),
        "os": platform.platform(),
        "compiler": subprocess.check_output(["crystal", "--version"], text=True).strip(),
        "gmp_version": subprocess.check_output(["pkg-config", "--modversion", "gmp"], text=True).strip(),
        "binary_linked_libraries": linked_libraries,
        "linked_gmp_sha256": linked_gmp_hashes,
        "base_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
        "build_command": build_command,
        "build_cache_directory": str(args.cache_dir.resolve()),
        "build_elapsed_seconds": build_elapsed,
        "build_executed_successfully_by_recorder": True,
        "binary_sha256": binary_hash,
        "source_sha256": source_hashes,
        "dependency_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=dependency, text=True).strip(),
        "dependency_source_sha256": dependency_hashes,
        "author_generator": {
            "forum_url": "https://forum.crystal-lang.org/t/optimal-mersenne-primes-search-using-modular-groups/9207/5",
            "source_record": "results/jabari_comparison.json author_sources",
            "source_record_sha256": sha256(author_record),
            "normalization": "Preserve all odd q; replace unavailable original Crystal primes-utils with shared GMP(25), omit logs/output and record exact q.",
        },
        "timing_contract": "Complete finite calls include plan/filtering, pool task preparation, candidate construction, synchronization and GMP work. Pool and Metal initialization, compilation and result comparisons are outside timing and separately recorded. Each method returns an owned ordered classification array.",
        "limitations": [
            "One host, uncontrolled temperature and background load; no confidence interval or universal optimum.",
            "GMP probable-prime agreement is not independent primality certification or original-author-backend execution.",
            "The same-resource post-5 parallel baseline separates thread-count gains from filter gains.",
            "No full-search billion extrapolation, NVIDIA runtime claim or GIMPS comparison.",
        ],
        "host_load_average_before_run": list(os.getloadavg()),
        "cases": [],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def save():
        args.output.write_text(json.dumps(output, indent=2) + "\n")

    save()
    for count, start in cases:
        command = [str(binary), str(count), str(start), str(args.repeats),
                   args.workers, str(args.tile), str(args.chunk)]
        load = list(os.getloadavg())
        completed = subprocess.run(command, cwd=root, text=True, stdout=subprocess.PIPE,
                                   check=True, timeout=600)
        row = json.loads(completed.stdout)
        if not row["all_final_states_and_work_counts_equal"]:
            raise RuntimeError("harness did not confirm matched results")
        row["run_command"] = command
        row["host_load_average_before_case"] = load
        row["host_load_average_after_case"] = list(os.getloadavg())
        output["cases"].append(row)
        save()
        print(json.dumps({"count": count, "start_q": start,
                          "medians_ms": {name: values["median_ms"]
                                         for name, values in row["methods"].items()}}), flush=True)

    output["host_load_average_after_run"] = list(os.getloadavg())
    output["binary_and_sources_unchanged_during_run"] = (
        sha256(binary) == binary_hash
        and source_snapshot(root) == source_hashes
        and dependency_snapshot(dependency) == dependency_hashes
        and all(sha256(Path(name)) == digest for name, digest in linked_gmp_hashes.items())
    )
    output["run_status"] = "complete" if output["binary_and_sources_unchanged_during_run"] else "invalid_source_drift"
    output["completed_at_utc"] = datetime.now(timezone.utc).isoformat()
    save()
    if not output["binary_and_sources_unchanged_during_run"]:
        raise RuntimeError("source/binary changed during measurement")
    print(f"saved {args.output}", flush=True)


if __name__ == "__main__":
    main()
