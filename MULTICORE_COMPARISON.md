# Multicore Mersenne screening comparison

Measured on 2026-10-12 in New York (2026-10-13 00:51–00:55 UTC), on one
Apple M2 Max with 64 GiB unified memory, 8 performance cores and 4 efficiency
cores. Crystal 1.21.0, GMP 6.3.0. Raw build/source/dependency metadata, linked
GMP digest, all samples and initialization costs are in
[results/multicore_comparison.json](results/multicore_comparison.json).

The additive worker pool preserves the previous all-odd-q experiment and the
finite q=17..4095 boundary. It distributes descending chunks dynamically,
constructs BigInts separately in each worker, and retains ordered results.
It does not parallelize a single GMP test or change the primality algorithm.

## Complete pipelines

Five timed repetitions per method, two separately recorded warmups, and
rotating/reversed method order. Medians in milliseconds:

| Candidates (q interval) | Serial generator | Serial CPU | Serial Metal | CPU, 8 workers | CPU, 12 workers | Generator, 8 workers | Generator, 12 workers | Metal + 12 workers |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 32 (17..79) | 0.039 | 2.151 | 3.135 | 2.224 | 2.214 | 0.106 | 0.075 | 2.924 |
| 512 (33..1055) | 41.213 | 27.095 | 28.013 | 6.281 | 6.212 | 6.869 | 6.255 | 6.899 |
| 1024 (17..2063) | 392.274 | 263.626 | 265.430 | 46.228 | 47.419 | 64.171 | 66.909 | 50.396 |
| 2040 (17..4095) | 4929.691 | 3662.372 | 3634.563 | 619.219 | 572.385 | 862.465 | 879.638 | 672.966 |

For 1,024 candidates, the 8-worker CPU median is **5.70x faster than our serial
CPU** and **8.49x faster than the serial normalized generator**. Comparing the
same 8-worker pool instead gives **1.39x** for the sieve's added contribution.
For 2,040 candidates, 12 workers give **6.40x**, **8.61x** and **1.54x**,
respectively. These are ratios of measured medians, not confidence intervals.

The author's [post 5](https://forum.crystal-lang.org/t/optimal-mersenne-primes-search-using-modular-groups/9207/5)
uses direct Mersenne candidates. We preserve its visible all-odd-q schedule,
substitute shared GMP(25) for the unavailable original Crystal `primes-utils`
backend, omit logging/output and record exact q. The parallel generator is an
additional adapter using exactly the same pool instance as the filtered path.
These are not timings of the author's original tester. Author source/version
and normalization records remain in `results/jabari_comparison.json`.

At 512 candidates, 12-worker filtered and unfiltered medians are almost equal.
At 32 candidates, factor-plan preparation overwhelms the tiny primality work;
our filtered calls are much slower than the normalized generator. Twelve
workers do not always beat eight. These results do not establish a universal
worker count or a CPU/GPU dispatch rule. The 12-worker hybrid did not improve
the 12-worker CPU median on any of these four windows.

## Worker scaling

### 1024 candidates: q=17..2063

| Workers | CPU sieve + pool (ms) | Generator + same pool (ms) | Generator / filtered |
|---:|---:|---:|---:|
| 1 | 261.206 | 390.185 | 1.49x |
| 2 | 133.273 | 195.158 | 1.46x |
| 4 | 68.310 | 101.004 | 1.48x |
| 8 | 46.228 | 64.171 | 1.39x |
| 12 | 47.419 | 66.909 | 1.41x |

### 2040 candidates: q=17..4095

| Workers | CPU sieve + pool (ms) | Generator + same pool (ms) | Generator / filtered |
|---:|---:|---:|---:|
| 1 | 3567.020 | 4702.310 | 1.32x |
| 2 | 1784.183 | 2436.999 | 1.37x |
| 4 | 945.536 | 1291.549 | 1.37x |
| 8 | 619.219 | 862.465 | 1.39x |
| 12 | 572.385 | 879.638 | 1.54x |

## Timing and attribution

Each full filtered call includes factor-plan validation/preparation, CPU or
Metal filtering, witness copying, task preparation, allocation, candidate
construction, scheduling, synchronization, GMP work and owned ordered output.
The generator calls include all candidate construction and GMP work. Calls
and methods do not overlap. All worker pools are initialized before warmup;
the inactive pools stay idle while a method runs.

Compilation, pool construction, Metal initialization, first GPU kernel
compilation, equality checks and JSON output are outside the steady-state
samples. Constructor timings and both complete warmup times per method are
recorded, including the first use of each pool. Reusable plans are supported
by the API; these full-call measurements deliberately prepare a plan each
call, rather than reporting prepared throughput as a complete pipeline.

The recorder builds the executable itself from a source/dependency snapshot,
checks stability after building, hashes the binary and linked GMP library,
then rechecks everything after the run. The run is `complete` and
`binary_and_sources_unchanged_during_run` is true. The recorded base commit is
`d78c249`; source hashes identify this additive feature as built before its
atomic commit. The dependency checkout had unrelated local changes; it was
not edited, and the recorder captures source hashes plus `build/bridge.o`.

Background load and temperature were uncontrolled. The pre-run load average
was about 10.27. Variation is substantial: for 1,024 candidates, the 8-worker
CPU samples span 43.3–60.0 ms; for 2,040, the 12-worker CPU spans
497.1–722.8 ms. The rankings of close results should not be treated as a
statistically established optimum. No processes were stopped for this run.

## Correctness and adversarial checks

Every warmup and timed call compares all final classification states to the
serial normalized baseline and the actual GMP call count to its path's expected
count (all candidates for the generator, only unresolved ones after filtering).
All comparisons
passed: 392 complete calls, covering 353,584 result entries across the four
windows. The filtered paths made 7, 110, 220 and 449 GMP calls per window;
the corresponding generator paths made 32, 512, 1,024 and 2,040. Initial
CPU/Metal factor arrays also matched exactly for each window.

The complete CPU suite passed **55 examples, 0 failures/errors**. Ten pool
specs cover uneven chunks, exact candidate/thread ownership on four distinct
native threads, empty and entirely witnessed windows, bounds, repeated calls,
concurrent callers, post-admission witness mutation, in-flight close, worker
failure draining and reuse. The witness snapshot test mutates the caller's
array only after a worker has entered, not during the copy.

The source review verdict is **ROBUST within this bounded API**. It inspected
disjoint cursor claims/result writes, completion/error publication, input
ownership and shutdown serialization. A hypothesized loop-closure capture
bug was refuted by a small gated Crystal 1.21 probe. The review led to stronger
multiworker/close tests, earlier input validation and source-bound build/output
guards. Same-lineage assistant review is correlated evidence; the executed
checks carry the correctness claim. The close test's short absence timeout
retains a scheduling caveat; source locking and the gated worker provide the
stronger lifecycle anchor.

This is probable-prime agreement, not independent primality certification.
There is no billion-candidate full-test extrapolation, new CUDA runtime result,
GIMPS comparison or new primality theorem. The bounded factor table cannot
screen large prime exponents. Prime-exponent selection and a suitable final
Mersenne tester remain required search-level baselines.

## Reproduce

CPU-only verification and use of `parallel_mersenne.cr` need Crystal 1.21 and
GMP, without Metal or cogni-ml:

```sh
env CRYSTAL_CACHE_DIR=/private/tmp/mpgs-multicore-cache crystal spec spec/ --link-flags=-fuse-ld=/usr/bin/ld
crystal tool format --check parallel_mersenne.cr spec/parallel_mersenne_spec.cr multicore_benchmark.cr
```

The matched Metal/CPU comparison needs the README dependency layout and a
built cogni-ml Metal bridge. From the repository root:

```sh
python3 scripts/run_multicore_comparison.py --binary /private/tmp/mpgs-multicore-benchmark --dependency-root /Users/sergey/Projects/Crystal/cogni-ml
```

The recorder executes the release/native Crystal build, with the bridge and
Apple linker, before measuring. The default cases, five worker counts, five
repetitions, tile size 4,096 and chunk size 1 reproduce this run. Adjust the
absolute dependency path for your workspace; the actual relative import must
still match it. The Apple linker option addresses this host's Crystal/Xcode
combination. This recorder is specifically for macOS/Metal. On Linux, use the
CPU-only pool with the platform's normal Crystal linker settings.

Refresh tests and measurements after pool/caller, dependency, compiler, GMP,
hardware, driver or workload changes. Rollback is the preceding Git state;
the serial adapter and cogni-ml implementation were preserved.
