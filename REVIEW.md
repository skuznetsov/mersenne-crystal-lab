# Hostile self-review and measured optimization

Date: 2026-10-12. CPU and Metal verdict: **ROBUST within the executed checks and admitted input contract**. CUDA execution: **IN_PROGRESS**; source-level repairs and Crystal type checking do not establish NVIDIA correctness. This is a small-factor research prototype, not a complete Mersenne-prime search or a new number-theory result.

## Current direct-exponent slice

The latest implementation and measurements are in [EXPONENT_COMPARISON.md](EXPONENT_COMPARISON.md); the older progression results below retain their original scope. The direct-q path marks `ord_d(2)|q` progressions, preserves first-factor precedence, and removes the 32-entry rebasing limit. Directional dominance pruning reduces 1,824 distinct odd orders to 479 retained progressions for the benchmark's 6,541 ascending primes. Shared output is initialized before dispatch and copied into owned storage after synchronous completion, before buffer release.

The independent order audit found zero mismatches over all 6,541 primes, using a separate first-return doubling algorithm rather than the production order-reduction algorithm. The full CPU suite passes 45 examples. Direct-q Metal passed 611 comparisons against independently constructed BigInts or separate modular powers and rejected 11 invalid cases. The existing 767 odd-k cases still pass. Shader failure injection now exercises both window APIs while preserving candidate calls.

Four finite shared-GMP intervals matched final classification arrays; the exact old CPU/Metal factor arrays also matched the direct plan before timing. Five tile probes and four additional scale probes matched complete factor arrays on every call. Three billion-entry streaming rounds matched every CPU/Metal factor entry. The latter uses the production CPU comparator, not an independently recomputed billion-entry coverage oracle.

At 1,024 identical odd exponents, full direct Metal + GMP took 267.287 ms versus 932.386 ms for the previous Metal adapter, direct CPU 262.241 ms and generator + shared GMP 390.569 ms. The billion filter medians were CPU 3.326 s and Metal 2.830 s. This is a small one-host filter-stage advantage, with CPU leading in several smaller windows and final pipelines largely occupied by GMP. Host load was uncontrolled; no universal GPU superiority or complete-search extrapolation is supported.

Adversary verdict: **ROBUST within the tested arithmetic, lifecycle and matched-input scopes**. Output wording was narrowed to `all_final_states_equal`, and the referenced author-source record was hashed. Executed source identities remain recorded; post-measurement metadata clarifications are explicit. Broad performance claims remain **VULNERABLE**. Original-backend execution, billion final primality tests and GIMPS superiority would be **BROKEN** claims.

The highest-value remaining mathematical baseline is prime-exponent selection: for these trial primes d<=65,521, an odd order divides (d-1)/2 and is at most 32,760, so no prime exponent above 32,760 can match this bounded table. Keeping the author's all-odd-q stream is necessary for the present comparison, but does not establish value against a search that selects prime exponents first. NVIDIA execution, specialized final Mersenne tests and substantive novelty remain open.

## Highest-risk assumptions and repairs

| Finding | Response and evidence |
| --- | --- |
| A correct candidate/factor scan can still waste almost all its work. | Derive one residue class per factor; mark arithmetic progressions in dense windows. Keep the unchanged pairwise CPU implementation as a comparator and include the better prepared sparse baseline. |
| Parallel factor marking can return the numerically smallest divisor instead of the first supplied divisor. | Atomically minimize original factor rank. Reversed and duplicate lists are compared with exact expectations. For example, G_2(1)=15 with factors [5,3] must return 5. |
| Inversion of 3 is invalid at divisor 3. | Explicit all-hit/no-hit cases for even/odd exponents. First-ranked 3 resolves even windows on the host; later 3 seeds its rank and only earlier factors are dispatched. |
| Candidate-equals-factor can be misreported as composite. | Preserve the strict proper-divisor guard on CPU. Require m>=15 on GPU, making every admitted trial factor strictly smaller than every candidate. G_1(1)=7 and G_3(1)=31 remain protected controls. |
| Repeated Metal constructors could accumulate retained pipeline handles. | Cache at most two fixed pipelines per process. The current bridge provides no release API for these handles; this bounds growth but does not promise pipeline release on close. Per-call buffers are released. |
| A new window shader compilation failure could disable the established candidate API. | Compile the window pipeline lazily. A real fault-injection test deliberately supplies an invalid shader, observes the expected compiler diagnostic, and successfully calls the candidate API both before and after that failure. |
| CUDA operations can use another backend's ambient context or stream. | Bind/push the owned context, restore/pop it, use its default stream, serialize calls and close, embed PTX at compilation, and check context destruction. These repairs are type-checked; their runtime behavior still needs NVIDIA tests. |
| An even-sized sample set made the reported upper-middle value an incorrect conventional median. | Benchmark requires odd repeat counts in 3..21. Five repetitions are used in the recorded run. |
| An all-zero or partially written GPU result can look successful. | Positive controls and exact reference comparisons remain required. Window rank UINT_MAX means unresolved, not proof that all jobs executed. The optional witness checker establishes nonzero-factor soundness only. |
| A shared prepared-root bug could fool both GPU and its checker. | The checker uses direct modular divisibility with independently recomputed powers, without consulting prepared roots. BigInt expectations remain the stronger bounded arithmetic check. |

No arithmetic defect was found in the original CPU reference. The largest improvement comes from reducing the amount of work, rather than GPU instruction tuning.

## Why the transformation preserves output

For each admitted prime d other than 3, both 2^m and 3 are invertible. Therefore G_m(k) is divisible by d exactly when

```text
k = ((2^m)^(-1) - 1) * 3^(-1)  (mod d).
```

For k=start+2*i, inversion of 2 gives the first matching index. All further indices occur at stride d. Small CPU exponents skip initial matches until G_m(k)>d. CPU visits factors in supplied order; Metal minimizes their supplied rank. Duplicate factors leave this order unchanged. For even m, 3 divides every candidate and is always proper; no factor after its first supplied rank can improve the required answer.

UInt64 k is reduced before multiplication. Trial factors <=65,535 bound residue products; the window-count, tile-size, endpoint and dispatch-grid checks bound kernel index arithmetic. There is no wrapping arithmetic used to accept a window endpoint.

## Executed checks

- Full CPU suite: 45 examples, zero failures/errors, including independent BigInt expectations, exact scheduling, validation, optional checker rejection tests, normalized-generator adapters and direct-exponent plans.
- Metal: 767 exact window comparisons. Four bounded exponent groups use constructed BigInt candidates; large exponents use the unchanged modular CPU reference. Inputs include UInt64::MAX endpoints, UInt32::MAX exponent, partial tiles, empty lists/windows, reordered/duplicate factors, d=3 and d=65,521. Invalid starts/counts/tiles, oversized grids and use after close were rejected; alternating instances and idempotent close were exercised.
- Intentional Metal window compilation failure: isolated successfully; candidate API remained usable. Script: scripts/check_metal_compile_isolation.py.
- Candidate Metal demo: control batches and 4,096 candidates at m=136279841 matched. With 24 primes through 97, outputs contained 2,623 proper-factor witnesses and 1,473 unresolved candidates.
- CUDA wrapper/demo: crystal build gpu_demo.cr -Dmpgs_cuda --no-codegen passed. This checks Crystal types only.
- CPU-only benchmark executed at a small exponent and rejected an even repeat count. Crystal formatting and Python syntax checks passed.
- Maximum dense window: 16,777,216 candidates ran on CPU and Metal. Full arrays matched the previously tested prepared CPU marker; its 14,230,529 nonzero factors also passed direct modular checks. This is an additional load/scale check, not an independent proof of coverage.

The exact commands and dependency layout are in README.md. CPU builds on this host used the Apple linker workaround. Tested hardware/compiler: Apple M2 Max, 64 GiB unified memory, Crystal 1.21.0. Dependency HEAD and relevant dependency/bridge hashes, actual build commands and raw samples are recorded in the result JSON files. The external cogni-ml working tree was not edited.

## Release measurements

Two warmups per method, five rotating/reversed timed repetitions, identical inputs, and exact output comparisons outside timed sections. Full calls include factor validation/preparation. Prepared calls reuse an immutable plan. Calls include output allocation; dispatched Metal calls include transfer, synchronization, readback and mapping. Backend initialization and lazy window compilation occur outside measured calls. Candidate input-array materialization is excluded. There is no host-temperature/background-load control and no statistical confidence interval.

Case: m=136279841, k=1+2*i, 262,144 candidates, 6,541 ascending odd primes through 65,521. Milliseconds:

| Method | Median | Observed min–max |
| --- | ---: | ---: |
| Original pairwise CPU, full | 3071.677 | 2999.365–3077.550 |
| Prepared sparse CPU, reused plan | 227.329 | 223.130–228.402 |
| Residue window CPU, full | 1.844 | 1.791–2.262 |
| Residue window CPU, reused plan | 1.420 | 0.997–1.586 |
| Original candidate Metal, full | 112.451 | 107.017–113.082 |
| Residue window Metal, full | 2.489 | 1.970–2.662 |
| Residue window Metal, reused plan, tile 1024 | 1.442 | 0.878–1.790 |
| Metal reused plan plus CPU witness check | 4.384 | 3.721–4.624 |

The large ratio to the original pairwise CPU implementation is an implementation comparison. Its factor-outer loop continues visiting already-resolved slots; it is not a state-of-the-art baseline. The prepared sparse comparator makes that limitation visible. At this size, the full CPU window path is faster than the full Metal path.

Large-window probe, same exponent and factors. Correctness comparator is the already-tested CPU marker; its nonzero outputs were directly checked. Milliseconds:

| Candidates | CPU full | Metal full, tile 1024 | Metal reused plan, tile 4096 |
| --- | ---: | ---: | ---: |
| 1,048,576 | 4.747 | 4.403 | 3.292 |
| 4,194,304 | 18.433 | 13.745 | 10.976 |
| 16,777,216 | 104.499 | 47.936 | 40.350 |

At the admitted maximum, the full Metal call is about 2.18 times faster than the full optimized CPU call on this host. Tile 4096 was the best of five measured prepared settings for the three large windows; that is tuning evidence, not an automatically selected or independently validated policy. Small-window measurements often favor CPU. Allocation and GC variation are visible in raw samples, including cases where prepared timings exceed full timings. No universal threshold or GPU superiority is claimed.

## Later matched-generator comparison

See `COMPARISON.md` and `results/jabari_comparison.json` for 12 finite generator comparisons and six directly executed billion-item sieve rounds. All final classifications agree under the substituted common GMP tester; every billion-round CPU/Metal factor entry agrees. Source and executed-binary identities were checked against the recorded hashes.

Adversary verdict: **ROBUST within the tested normalized classification and sieve-equality scope**; **VULNERABLE as a whole-pipeline billion-item extrapolation**. Calling these results an execution of Jabari's unavailable Crystal backend or a directly timed billion-primality-test search would be **BROKEN**. Five deterministic midpoint samples on a busy host do not support statistical confidence bounds. They do not sample the low-k endpoint and do not reproduce the PDF's dynamic seed resets.

In that earlier experiment, the attempted transfer of dense odd-k GPU throughput to the direct-Mersenne generator was rejected: the generic path was slower on all three intervals, with a UInt64 recurrence requiring small rebased runs. This motivated the separately tested direct-exponent implementation described above; the old generic-path limitation must not be restated as a verdict on the newer implementation.

## Remaining hedgehogs and research boundary

1. NVIDIA PTX assembly, driver linking, execution, context restoration, multiple instances, threaded calls and cleanup failures remain open. The inherited module/buffer cleanup API ignores some driver cleanup errors. Source inspection cannot close these runtime obligations.
2. Metal evidence covers this device/toolchain. External device reset, process-wide cogni-ml interference, allocation failure injection and arbitrary threaded use were not tested. Per-instance serialization does not establish safety against those external actions.
3. Nonzero witness checking shares the existing modular-power helper, accepts missing hits and does not check first-factor precedence. It is useful soundness validation, not a primality certificate or a complete dispatch certificate. Exact comparisons provide the tested coverage/precedence evidence.
4. UInt64 k, UInt32 m and small factors define a finite screening API. The arbitrary odd-k batches mostly contain general progression candidates. They must not be advertised as batches of Mersenne candidates.
5. The schedule harness uses GMP probable-prime screening in bounded intervals. It has no large-exponent Lucas–Lehmer/PRP implementation, error checking or complete factoring pipeline.
6. Residue-class sieving is standard. Neither these speedups nor the code alone establish mathematical novelty, publication merit, or superiority over GIMPS. A joint paper needs a substantive new result or a carefully justified experimental contribution.

A useful next collaboration is to choose the target, verify exact Mersenne coverage, agree on matched established baselines, validate NVIDIA, and test whether the modular-group formulation yields an additional sound filter. Only a complete pipeline comparison can address a GIMPS performance claim.

Evidence decays after relevant source, dependency, compiler, GPU/driver or benchmark-condition changes. Source identities at measurement time are in results/benchmark.json and results/scale.json; rerun the corresponding commands after such changes. The original CPU reference remains a fallback, and a local source-only pre-review snapshot supplies rollback. No forum response was sent.
