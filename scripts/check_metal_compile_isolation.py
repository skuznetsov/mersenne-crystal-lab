#!/usr/bin/env python3
"""Inject a window-shader compile failure and check candidate API isolation."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dependency-root", type=Path, required=True)
    parser.add_argument("--apple-linker", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    dependency = args.dependency_root.resolve()
    with tempfile.TemporaryDirectory(prefix="mpgs-metal-failure-") as directory:
        scratch = Path(directory)
        (scratch / "kernels").mkdir()
        shutil.copyfile(root / "kernels/mpgs_sieve.metal",
                        scratch / "kernels/mpgs_sieve.metal")
        (scratch / "kernels/mpgs_window.metal").write_text(
            "#error MPGS_WINDOW_FAILURE_PROBE\n")
        source = (root / "metal_backend.cr").read_text()
        source = source.replace('require "./prepared_sieve"',
                                f'require "{os.path.relpath(root / "prepared_sieve", scratch)}"')
        source = source.replace('require "./exponent_sieve"',
                                f'require "{os.path.relpath(root / "exponent_sieve", scratch)}"')
        source = source.replace('require "../../Crystal/cogni-ml/src/ml/metal/dispatch"',
                                f'require "{os.path.relpath(dependency / "src/ml/metal/dispatch", scratch)}"')
        (scratch / "metal_backend.cr").write_text(source)
        (scratch / "check.cr").write_text('''require "./metal_backend"
backend = MersenneLab::MetalSieve.new
begin
  raise "candidate API failed before window error" unless backend.sieve(32_u32, [1_u64], [3_u32]) == [3_u32]
  begin
    backend.sieve_odd_window(31_u32, 1_u64, 1, [7_u32])
    raise "broken window shader unexpectedly compiled"
  rescue error
    raise error unless error.message == "Failed to compile kernel 'mpgs_window'"
  end
  begin
    backend.sieve_exponents(17_u32, 1, [7_u32])
    raise "broken exponent shader unexpectedly compiled"
  rescue error
    raise error unless error.message == "Failed to compile kernel 'mpgs_window'"
  end
  raise "candidate API failed after window error" unless backend.sieve(32_u32, [1_u64], [3_u32]) == [3_u32]
  puts "window_compile_failure_isolated=true exponent_compile_failure_isolated=true candidate_api_still_usable=true"
ensure
  backend.close
end
''')
        flags = f"{dependency / 'build/bridge.o'} -lc++"
        if args.apple_linker:
            flags += " -fuse-ld=/usr/bin/ld"
        environment = os.environ.copy()
        environment["CRYSTAL_CACHE_DIR"] = str(scratch / "cache")
        binary = scratch / "check"
        subprocess.run(["crystal", "build", str(scratch / "check.cr"),
                        "--release", f"--link-flags={flags}", "-o", str(binary)],
                       env=environment, check=True)
        completed = subprocess.run([str(binary)], text=True, capture_output=True)
        if completed.returncode:
            print(completed.stdout, end="")
            print(completed.stderr, end="")
        completed.check_returncode()
        # The bridge emits compiler details to stderr but exposes a generic
        # Crystal exception. Check both so unrelated failures cannot pass.
        if "MPGS_WINDOW_FAILURE_PROBE" not in completed.stderr:
            raise RuntimeError("expected shader diagnostic was not observed")
        print(completed.stdout, end="")


if __name__ == "__main__":
    main()
