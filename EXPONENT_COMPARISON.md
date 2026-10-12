# Direct exponent sieve: matched CPU, Metal and GMP comparison

Measured October 12, 2026, on an Apple M2 Max with 64 GiB unified memory, Crystal 1.21.0 / LLVM 22.1.8 and GMP 6.3.0. The direct exponent path removes the previous 32-candidate compatible-k rebasing. At 1,024 candidates, the complete Metal + GMP pipeline fell from 932.386 ms to 267.287 ms, a 3.49x throughput improvement over our previous Metal adapter. Direct CPU + GMP took 262.241 ms; generator + shared GMP took 390.569 ms. CPU and Metal are close here, with a slight CPU lead.

The billion-exponent small-factor stage was executed in full three times: median CPU 3.326 s, Metal 2.830 s. Every factor entry matched. This is a measured 1.18x throughput ratio for filtering on this host, not a billion-primality-test result. Background load and temperature were uncontrolled; all timings are exploratory.

## Candidate stream and normalization

[Jabari's current forum generator](https://forum.crystal-lang.org/t/optimal-mersenne-primes-search-using-modular-groups/9207/5) visits `M_q=2^q-1` for consecutive odd q. Resetting the seed after a hit preserves the next exponent q+2. Every compared method consumes the same q window, including composite exponents.

The author's exact Crystal `primes-utils` source was unavailable. The finite baseline reproduces the visible candidate schedule with the same GMP probable-prime tester, `reps=25`, as all filtered paths. Exact exponent recording replaces floating-log reporting, and console output is excluded. This measures a normalized generator, not unchanged execution of the author's primality backend. [GMP documents the tester's behavior](https://gmplib.org/manual/Number-Theoretic-Functions); the parameter is not a claim of 25 additional Miller–Rabin rounds.

The historical progression experiment and its source records remain in [COMPARISON.md](COMPARISON.md) and [results/jabari_comparison.json](results/jabari_comparison.json). Its odd-k billion measurements concern a different stream and must not be substituted for the direct-exponent measurements below.

## What changed

For each odd trial prime d, compute `r=ord_d(2)`. Then `d | M_q` exactly when `r | q`. Even r cannot divide odd q. The plan computes each order once, preserves input-factor precedence, and marks q indices at stride r. It omits a later order when an earlier retained order divides it, because every later hit already has an earlier witness. This pruning is directional, preserving reversed and unsorted input behavior.

All 6,541 odd trial primes through 65,521 yield 1,914 odd-order factors, 1,824 distinct odd orders and **479 retained progressions**. The GPU reuses the existing window kernel with these offsets and strides. Atomic minimum selects the retained rank in original input order. One dispatch handles a whole window, up to 16,777,216 candidates. Explicitly shared output storage allows CPU initialization and result copying after synchronous GPU completion; the returned array owns its data.

The CPU supports every positive odd UInt32 start, including low exponents with a strict proper-factor guard. Metal requires q>=17. Count, final exponent, tile and dispatch-grid bounds are checked. Zero means unresolved, never prime.

## Complete finite pipelines

Two warmups per method and five timed repetitions in rotated/reversed order. All rows use 6,541 supplied primes and Metal tile size 4096. Times are medians in milliseconds. The final classification arrays matched on every warmup and timed call.

| Odd q interval | Count | Generator + GMP | Old CPU + GMP | Old Metal + GMP | Direct CPU + GMP | Direct Metal + GMP |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 17..79 | 32 | 0.037 | 0.882 | 18.771 | 2.146 | 3.391 |
| 33..1055 | 512 | 40.340 | 39.543 | 363.253 | 26.802 | 29.358 |
| 17..2063 | 1,024 | 390.569 | 290.012 | 932.386 | 262.241 | 267.287 |
| 17..4095 | 2,040 | 4694.296 | 3561.317 | 4791.222 | 3448.367 | 3517.424 |

These **full** paths include plan preparation on every call. The old paths also include compatible-k construction and rebasing every 32 candidates. All filtered paths include output allocation, survivor BigInt construction and survivor GMP tests. The baseline constructs and tests every candidate. GPU calls include input transfers, shared-output initialization, dispatch, synchronization and copying/mapping the completed output. Backend initialization, first kernel compilation and equality checking are outside the clock and separately recorded.

Reusing one plan gives these **prepared** complete-pipeline medians:

| Count | Direct CPU + GMP, ms | Direct Metal + GMP, ms | GMP calls after filtering / baseline |
| ---: | ---: | ---: | ---: |
| 32 | 0.015 | 0.651 | 7 / 32 |
| 512 | 24.890 | 46.001 | 110 / 512 |
| 1,024 | 261.259 | 262.912 | 220 / 1,024 |
| 2,040 | 3540.045 | 3580.035 | 449 / 2,040 |

At 1,024 candidates, the baseline range was 388.020–391.703 ms, direct full CPU 258.058–266.017 ms, and direct full Metal 261.791–307.852 ms. The 512 prepared Metal range was 24.508–50.122 ms; its slower median than the full path exposes host/allocator variation. Prepared/full comparisons are separate repeated measurements, not a precise subtraction of preparation cost. Full plan preparation is about 2.1–2.2 ms; backend initialization is about 48–62 ms.

At 1,024 candidates, 804 proper-factor witnesses leave 220 GMP calls. Both paths find the same probable-Mersenne exponents: 17, 19, 31, 61, 89, 107, 127, 521, 607 and 1279. At 2,040 candidates they additionally find 2203, 2281 and 3217. These are probable-prime classifications under a shared tester, not independent primality certificates.

## Large filter-only windows

No candidate BigInts or GMP tests occur in these rows. Every complete factor array is compared after every call. Full paths prepare a plan inside timing; prepared paths reuse one plan.

| Count | Start q | CPU full, ms | Metal full, ms | CPU prepared, ms | Metal prepared, ms |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 65,536 | 17 | 2.242 | 3.337 | 0.101 | 0.745 |
| 1,048,576 | 17 | 4.514 | 6.156 | 2.110 | 3.771 |
| 1,048,576 | 136,279,841 | 4.564 | 5.756 | 2.349 | 3.775 |
| 4,194,304 | 17 | 13.893 | 15.809 | 11.170 | 12.841 |
| 16,777,216 | 17 | 64.284 | 49.075 | 61.497 | 49.214 |

Tile size 256 was selected from a five-setting probe at 1,048,576 candidates. Prepared Metal medians for tiles 256, 1024, 4096, 16384 and 65536 were respectively 3.771, 3.783, 4.029, 5.228 and 7.483 ms. The first two are effectively tied under these conditions. The selected tile was then used at the other window sizes and in the billion stream; it is not a universal optimum or an automatic dispatch policy. The public API retains its configurable default of 1024.

## Direct execution of a billion-exponent small-factor filter

The complete interval is `q=17,19,...,2,000,000,015`, with the same 6,541 trial primes and one reused 479-progression plan. Each round uses 60 windows of at most 16,777,216 candidates and tile size 256. CPU/GPU order alternates per window and round. Equality and counting occur outside timing.

| Method | Median seconds | Observed minimum–maximum seconds |
| --- | ---: | ---: |
| Direct CPU, prepared | 3.326 | 3.276–3.417 |
| Direct Metal, prepared | 2.830 | 2.799–2.854 |

Three billion factor entries were compared across three rounds. One pass returns **758,662,628 proper-factor witnesses** and **241,337,372 unresolved entries**. The observed difference is 0.497 s per billion, about 15% less elapsed filter time or 1.18x throughput. One-time plan preparation is 2.153 ms and excluded from the prepared timing.

The sum of window call times includes output allocation, transfers, dispatch, synchronization and owned output copying/mapping. It excludes equality/counting, initialization, compilation and final primality work; it is not total harness wall time. GPU output storage is at most 64 MiB per window; owned CPU/Metal arrays, GC retention and other overhead are additional memory.

The final Mersenne candidate alone has about 250 MB of binary digits. No growing BigInts were constructed in this stream. There is no linear extrapolation from the finite GMP table to a billion consecutive exponents, and no GIMPS comparison.

## Correctness, hostile review and boundaries

- **45 CPU examples passed**, including independent BigInt expectations, low-q equality guards, copied plans, dominance/precedence and integer bounds.
- **611 direct-exponent Metal cases matched independent BigInt or separate modular-power expectations**, covering partial tiles, UInt32 endpoints, unsorted/reversed/duplicate factors, multiple instances and close. All 11 invalid inputs were rejected.
- **767 existing odd-k Metal cases still matched** after integration. Intentional window-shader failure was isolated for both window APIs, while the candidate API remained usable.
- An independent first-return doubling oracle computed minimal orders for all **6,541 primes**, using **116,098,142 modular doublings**, and checked the divisibility law in **98,115 cases**. The Crystal order checker found zero mismatches, reproduced all 479 retained groups, and passed 128 bounded q checks, 11 precedence probes and endpoint guards.
- Four finite classification intervals, five tile probes, four additional scale probes and all three billion-stream rounds matched within their stated comparison scopes.

Adversary verdict: **ROBUST within the admitted input contract and executed correctness checks**. CPU/Metal billion-array equality uses the production CPU plan as comparator; it is not an independently recomputed coverage proof for every billion entry. The separate arithmetic expectations and order oracle provide independent evidence within their bounded scopes. The optional witness checker accepts zeros and verifies nonzero-factor soundness only, not coverage, precedence or primality.

Performance generalization remains **VULNERABLE**: one busy host, no controlled temperature, no confidence interval, and CPU is faster in several tested sizes. Shared GMP final-state equality is agreement under one tester, not an independent primality oracle. Calling this an original-author-backend benchmark or a billion full-primality search would be **BROKEN**.

There is a further research boundary: an odd order divides `(d-1)/2`, which is at most 32,760 for the supplied primes d<=65,521. For odd prime q, a hit requires `ord_d(2)=q>1`, so no supplied factor can hit a prime exponent q>32,760. This bounded filter therefore eliminates composite-exponent candidates and supplies small-factor witnesses; it does not trial-factor large Mersenne candidates with prime exponents. Selecting only prime exponents is a separate, stronger schedule baseline that should be included before claiming search-level value. It was deliberately not added to these matched runs because the author's visible schedule visits all odd q.

NVIDIA execution, a large-exponent Mersenne final tester, automatic CPU/GPU selection and mathematical novelty remain open. Source-level CUDA repairs/type checking do not validate NVIDIA runtime behavior. A substantive joint study needs those baselines and a well-defined research question.

## Reproduce and refresh

From the lab directory, with the dependency layout in [README.md](README.md), substitute your bridge path:

```sh
env CRYSTAL_CACHE_DIR=/tmp/mpgs-exponent-cache crystal spec spec/ --link-flags=-fuse-ld=/usr/bin/ld
env CRYSTAL_CACHE_DIR=/tmp/mpgs-exponent-cache crystal run exponent_order_checks.cr --link-flags=-fuse-ld=/usr/bin/ld
env CRYSTAL_CACHE_DIR=/tmp/mpgs-exponent-cache crystal build gpu_exponent_checks.cr --release --mcpu=native --link-flags='/absolute/path/to/cogni-ml/build/bridge.o -lc++ -fuse-ld=/usr/bin/ld' -o /tmp/mpgs-exponent-checks
/tmp/mpgs-exponent-checks
python3 scripts/check_metal_compile_isolation.py --dependency-root /absolute/path/to/cogni-ml --apple-linker
env CRYSTAL_CACHE_DIR=/tmp/mpgs-exponent-cache crystal build exponent_benchmark.cr --release --mcpu=native --link-flags='/absolute/path/to/cogni-ml/build/bridge.o -lc++ -fuse-ld=/usr/bin/ld' -o /tmp/mpgs-exponent-benchmark
env CRYSTAL_CACHE_DIR=/tmp/mpgs-exponent-cache crystal build exponent_billion_probe.cr --release --mcpu=native --link-flags='/absolute/path/to/cogni-ml/build/bridge.o -lc++ -fuse-ld=/usr/bin/ld' -o /tmp/mpgs-exponent-billion-probe
/tmp/mpgs-exponent-benchmark final 1024 17 5 4096
/tmp/mpgs-exponent-benchmark filter 16777216 17 5 256
/tmp/mpgs-exponent-billion-probe 1000000000 17 3 256
```

`scripts/run_exponent_comparison.py` records all intervals and raw samples. Required options are `--binary`, `--billion-binary`, `--dependency-root`, `--order-oracle results/order_oracle.json`, `--build-command` and `--billion-build-command`; the last two are the exact commands used to compile the binaries. Use `--output results/exponent_comparison.regenerated.json` to preserve the recorded result and `--skip-billion` for finite cases only. To independently regenerate the oracle, run `python3 scripts/check_exponent_orders.py --output /tmp/mpgs-order-oracle.json`, then give that path to `exponent_order_checks.cr`.

[results/exponent_comparison.json](results/exponent_comparison.json) contains source/binary/dependency hashes, exact build/run commands, every sample, load averages, preparation/init costs and the hashed author-source record. [results/order_oracle.json](results/order_oracle.json) records the independently computed orders. Its canonical core SHA256 is `38f15f40d9e0604117103be3ce08ed4ad5ba7e5569177ad33fbc1450749d0f8a`.

After measurement, only descriptive metadata was clarified: finite equality is named `all_final_states_equal`, the referenced author-source record is hashed, and the Python recorder was updated to emit those fields. Executed source hashes remain intact; `post_measurement_annotations` records the current recorder hash and newly added standalone oracle checks. No compiled timing loop, sieve source, kernel, executed binary, sample or numerical result changed.

Refresh correctness and performance evidence after relevant source, dependency, compiler, GMP, hardware, driver or benchmark-condition changes. A differing witness/classification rejects the affected path. The original CPU reference and the pre-change local source snapshot provide fallbacks; the external cogni-ml checkout was not edited.
