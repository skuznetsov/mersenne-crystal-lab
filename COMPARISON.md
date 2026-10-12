# Matched Jabari comparison

Historical experiment before direct-exponent filtering. The newer implementation, current CPU/Metal/GMP comparison and directly executed billion-exponent stream are documented in [EXPONENT_COMPARISON.md](EXPONENT_COMPARISON.md). The measurements below retain their original inputs and normalization boundaries.

Measured October 12, 2026, on one Apple M2 Max with 64 GiB unified memory. All 12 finite comparisons produced identical final classifications. The direct CPU/Metal billion-item sieve runs also matched every factor entry in all three repetitions at both tested exponents. The arithmetic and equality claims are bounded by these inputs; performance is an observation on a busy host, not a universal ranking.

The useful result is modest acceleration of the normalized PDF progression with a CPU prefilter. Metal accelerates its dense small-factor stage, but adds almost no visible benefit to the complete GMP pipeline. For the author's current Mersenne-only generator, the existing Metal path is slower on every tested interval.

## Sources and admitted claims

- Downloaded PDF, *Optimal Mersenne Primes Search Using Modular Groups*, page 6: odd `k`, `G_p(k)=((3*k+1)<<p)-1`, probable-prime screening followed by the all-one-bit shape check. The original program resets `p` after a Mersenne hit.
- [Forum post 5, updated October 12, 2026](https://forum.crystal-lang.org/t/optimal-mersenne-primes-search-using-modular-groups/9207/5): direct `2^(p+m)-1` with even increasing `m`. Resets preserve the sequence of all subsequent odd exponents. This replaces the PDF's odd-k progression for the Mersenne search.
- The Crystal `primes-utils` implementation used by these snippets is not available in the inspected public sources. The public repository is a Ruby gem; the separate 2024 Crystal gist is a different generator and tester. No run here may be called an unchanged execution of the author's 2026 code or its original primality backend.

The comparison adapts the visible candidate generators to finite matched inputs and supplies the same GMP probable-prime test with API parameter `reps=25` to all paths. CPU and Metal filters pass every unresolved candidate to that same tester. Final arrays distinguish composite, probable prime of another shape, and probable-prime Mersenne; exact arrays agree outside timing. This does not independently certify primality. [GMP's documented tester](https://gmplib.org/manual/Number-Theoretic-Functions) already performs trial divisions and a Baillie-PSW test; `reps=25` does not mean 25 additional Miller-Rabin rounds in GMP 6.3.0.

Artifacts: [`results/jabari_comparison.json`](results/jabari_comparison.json), [`jabari_adapters.cr`](jabari_adapters.cr), [`jabari_benchmark.cr`](jabari_benchmark.cr), [`billion_probe.cr`](billion_probe.cr), and [`scripts/run_jabari_comparison.py`](scripts/run_jabari_comparison.py). The result JSON SHA256 is `f48b2a42ddaf4b51a9ef0459821803063d0cefeb1f1a6d69ada6bb231aa9bb43`.

## Complete normalized PDF progression

Every row uses exactly the same `G_m(k)=2^m*(3*k+1)-1` candidates and GMP tester. The baseline constructs every BigInt candidate. The two filtered paths first residue-sieve every candidate, then construct BigInts and call GMP only for unresolved survivors. Factor validation and plan preparation, sieve output allocation, survivor construction, and final screening are inside their timing. Five repetitions follow two warmups; times below are medians in milliseconds. CPU marking and final GMP screening are single-threaded.

| m | Candidate count | First k | Generator + GMP | Our CPU + GMP | Our Metal + GMP |
|---:|---:|---:|---:|---:|---:|
| 17 | 65,536 | 1 | 27.464 | 19.510 | 19.807 |
| 31 | 65,536 | 1 | 29.909 | 20.275 | 20.410 |
| 31 | 262,144 | 1 | 114.116 | 77.551 | 79.221 |
| 31 | 1,048,576 | 1 | 478.433 | 332.800 | 329.505 |

The positive-control row finds Mersenne exponents 19 and 31, alongside other progression primes. Rows at m=31 starting at k=1 are too short to reach the next Mersenne prime; full-array comparisons also check all other classifications, so agreement is not inferred from empty Mersenne-hit lists.

For the fixed m=31 billion-candidate range, five windows sample the midpoints of five equally sized index strata. Each contains 262,144 candidates; together they cover 1,310,720 candidates (0.131072% of the range). These are deterministic samples, not a random sample or a statistical confidence interval.

| First k | Generator + GMP, ms | Our CPU + GMP, ms | Our Metal + GMP, ms |
|---:|---:|---:|---:|
| 199,737,857 | 129.973 | 91.650 | 88.070 |
| 599,737,857 | 130.182 | 88.672 | 88.501 |
| 999,737,857 | 133.753 | 95.632 | 88.928 |
| 1,399,737,857 | 130.329 | 89.289 | 89.786 |
| 1,799,737,857 | 127.879 | 85.398 | 86.319 |

The mean per-candidate median cost gives this **exploratory extrapolation**, not a directly executed billion-primality-test result:

| Fixed m=31, k=1,3,...,1,999,999,999 | Estimated seconds | Estimated minutes | Throughput relative to generator + GMP |
|---|---:|---:|---:|
| Normalized PDF generator + GMP | 497.5 | 8.29 | 1.00x |
| Our CPU filter + GMP | 343.8 | 5.73 | 1.45x |
| Our Metal filter + GMP | 336.9 | 5.62 | 1.48x |

The individual-stratum extrapolations span 487.8–510.2 seconds for the baseline, 325.8–364.8 seconds for CPU, and 329.3–342.5 seconds for Metal. Those spans are observed variation, not error bounds. The samples omit the low-k endpoint, where integer bit lengths are smaller. Metal's estimated gain over our CPU pipeline is only about 2%; host noise and the sampling method do not justify a strong CPU-versus-Metal ranking for complete processing. Both perform identical survivor GMP work. These figures do not apply to the author's dynamically resetting infinite search.

## Current post-5 Mersenne-only generator

Inputs are the same consecutive odd exponents, including composite exponents. There is no added exponent-primality filter. The UInt64-compatible recurrence limits each rebased run to 32 consecutive exponents: `base=q_first-2`, `k_j=(4^j-1)/3`, so `G_base(k_j)=2^(q_first+2*(j-1))-1`. `k_32` fits UInt64 and `k_33` does not; the sieve API itself accepts larger arbitrary arrays. Rebasing, each plan, each GPU call, survivor BigInt construction, and GMP work are timed.

| Odd exponent interval | Count | Generator + GMP, ms | Our CPU + GMP, ms | Our Metal + GMP, ms |
|---|---:|---:|---:|---:|
| 17..79 | 32 | 0.038 | 1.281 | 18.736 |
| 33..1055 | 512 | 40.825 | 39.327 | 345.567 |
| 17..2063 | 1,024 | 394.068 | 290.811 | 903.138 |

All classifications match. The last row finds exponents 17, 19, 31, 61, 89, 107, 127, 521, 607, and 1279. The CPU prefilter saves about 26% of median elapsed time in that row (1.36x throughput), but is much slower for the small interval. Metal is about 2.29x slower than generator + GMP in the last row and 3.11x slower than our CPU path. The current generic sparse GPU path is therefore unsuitable for these tested intervals.

A billion consecutive odd Mersenne exponents starting at 17 ends at q=2,000,000,015. The final integer alone needs about 250 MB in binary, and primality-test cost grows with q. Multiplying the table's per-candidate times by a billion would be invalid.

## Direct billion-candidate small-factor stage

These are actual executions, not extrapolations. Each round sieves `k=1,3,...,1,999,999,999` in 60 bounded windows, with all 6,541 odd trial primes through 65,521. Tile size is 4096. A prepared plan is reused. Three rounds run both implementations with alternating CPU/GPU order; exact factor arrays are compared outside timing for every candidate in every round.

| m | CPU median, seconds | Metal median, seconds | CPU time / Metal time | Proper-factor witnesses | Unresolved |
|---:|---:|---:|---:|---:|---:|
| 31 | 8.351 | 3.219 | 2.59x | 848,199,471 | 151,800,529 |
| 136,279,841 | 7.726 | 2.877 | 2.69x | 848,159,448 | 151,840,552 |

Across both inputs, six billion CPU/Metal factor entries were compared. A zero is unresolved, not prime. Allocation, transfer, dispatch, synchronization, and readback are included when used. Equality checking, witness counting, GPU initialization/compilation, and final primality testing are excluded. One-time plan preparation was about 0.8 ms. These sieve times cannot be substituted for complete-search times or compared directly to a generator that also tests primality.

## Prediction and falsifiers

The prediction that dense odd-k filtering can help the normalized PDF progression survives these measurements. The attempted transfer of dense-window Metal throughput to the current Mersenne-only generator fails: the latter is sparse in k, and the generic 32-entry path is slower in every measured interval. A new direct-exponent kernel with larger batches would require a fresh experiment before any speed claim.

The decisive correctness falsifier was any differing final classification on identical candidates. None occurred in 12 cases totaling 2,754,080 candidate entries per comparison; equality was checked on both warmups and all five timed repetitions. All 36 CPU specs pass. The six new adapter examples include independent BigInt trial division, positive Mersenne and non-Mersenne controls, strict proper-factor checks, a deliberately false witness that changes classification, UInt64 endpoint handling, and invalid/empty bounds. Existing independent arithmetic tests cover low exponents and candidate-equals-factor guards. The previously executed 767 Metal boundary comparisons remain applicable because the sieve implementations and shaders were unchanged in this experiment.

Shared GMP classification is common evidence, not an independent second primality oracle. Full equality checks prove agreement within tested inputs, not all-range primality correctness or the behavior of the unavailable author backend.

## Measurement boundaries

Progression seed is fixed for matched windows. This measures the original per-candidate body with a substituted common tester, not the original dynamically resetting infinite search. All work needed by each method is inside its matched pipeline timing: construction of all baseline BigInts or only survivor BigInts, full plan preparation, output allocation, and final screening. Console I/O and floating-log reporting are excluded uniformly.

For post-5 candidates, rebase every at most 32 exact compatible-k entries to keep `k` within UInt64. Construction of all baseline BigInts or only survivor BigInts, rebasing, and plan preparation are included. Composite exponents are preserved; adding an exponent-primality filter would change the measured algorithm.

Direct billion-candidate runs measure the CPU/Metal small-factor stage only, in 60 bounded windows. A separate stratified estimate can describe the shared-GMP pipeline for a fixed small exponent and fixed finite odd-k range. A billion successive Mersenne exponents cannot be projected from constant-size candidate timings: both integer sizes and primality costs grow.

The host ran other CPU workloads; load averages were recorded per case, with no temperature or background-load control. Five medians reduce the effect of isolated stalls but do not establish statistical significance. In the 1,024-exponent case, individual baseline and CPU samples reached 590.8 and 821.7 ms; the median comparison should therefore be treated as exploratory. GPU backend initialization was about 40–47 ms in the finite cases and is recorded separately. Console output, floating-log reporting, initial GPU compilation, and final equality checks are excluded uniformly. The author's displayed overflow during reporting is not reproduced by the normalized exact-exponent recorder.

## Reproduce and refresh

Executed environment: Crystal 1.21.0, LLVM 22.1.8, GMP 6.3.0, aarch64 macOS 26.6.2. Both new benchmark binaries used `--release --mcpu=native`. The exact build/run commands, binary and source hashes, author-source hashes, dependency hashes, raw timing samples, GPU device, load averages, and exclusions are in the result JSON. After measurement, adversary review clarified one descriptive string in the Python runner and result metadata. The result retains the executed runner hash and records its current hash in `post_measurement_annotations`; no timing loop, compiled source, binary, or numerical result changed. The consumed cogni-ml HEAD was `7cccdd8bfb02ac388001ab7a61832087d8d1b450`; unrelated local changes were preserved.

From `Math/mersenne-lab`, substituting your cogni-ml bridge path:

```sh
env CRYSTAL_CACHE_DIR=/private/tmp/mpgs-matched-cache crystal spec spec/ --link-flags=-fuse-ld=/usr/bin/ld
env CRYSTAL_CACHE_DIR=/private/tmp/mpgs-matched-cache crystal build jabari_benchmark.cr --release --mcpu=native --link-flags='/absolute/path/to/cogni-ml/build/bridge.o -lc++ -fuse-ld=/usr/bin/ld' -o /tmp/mpgs-jabari-benchmark
env CRYSTAL_CACHE_DIR=/private/tmp/mpgs-matched-cache crystal build billion_probe.cr --release --mcpu=native --link-flags='/absolute/path/to/cogni-ml/build/bridge.o -lc++ -fuse-ld=/usr/bin/ld' -o /tmp/mpgs-billion-probe
/tmp/mpgs-jabari-benchmark progression 262144 1 31 5 65521
/tmp/mpgs-jabari-benchmark mersenne 1024 17 31 5 65521
/tmp/mpgs-billion-probe 1000000000 31 3
/tmp/mpgs-billion-probe 1000000000 136279841 3
```

The Python runner executes all sampled cases and captures source provenance. It additionally requires your downloaded PDF and a local forum JSON snapshot; those third-party documents are not redistributed in the attachment. `--skip-billion` omits the direct billion-item runs. GPU harnesses require Metal; there is no NVIDIA performance comparison in this report.

Rollback: the adapters, harnesses and result files are isolated additions. Existing sieve implementations and the external cogni-ml checkout remain unchanged. Refresh these claims after changes to inputs, code, compiler, GMP, cogni-ml, hardware, or drivers. A mismatch rejects the affected correctness claim; changed conditions require a new performance measurement. Literal comparison with Jabari's backend remains open until its exact Crystal source and configuration are supplied.
