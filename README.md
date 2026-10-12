# Mersenne screening experiments in Crystal

A bounded collaboration experiment for `M_q=2^q-1` and `G_m(k)=2^m*(3*k+1)-1`, with direct CPU/Metal exponent sieving, a modular reference, a CUDA prototype, and matched GMP comparisons. This is small-factor screening. It does not certify primality or establish superiority over GIMPS. `reply.md` is a proposed response; nothing has been posted.

The latest direct-exponent experiment removes the 32-candidate rebasing limit. On one Apple M2 Max, 1,024 identical Mersenne candidates took **267 ms with direct Metal + GMP**, versus **932 ms with our previous Metal adapter**, **262 ms with direct CPU + GMP**, and **391 ms with generator + shared GMP**. A billion-exponent filter was actually executed three times: **3.33 s CPU / 2.83 s Metal**, with every factor entry matching. Those billion timings exclude final primality tests. Background load was uncontrolled.

Start with [EXPONENT_COMPARISON.md](EXPONENT_COMPARISON.md) for inputs, complete/prepared costs, raw measurement links, correctness checks and limitations. [COMPARISON.md](COMPARISON.md) preserves the preceding PDF-progression and rebased-generator experiments. The author's exact Crystal `primes-utils` backend was unavailable; the finite comparisons substitute one common GMP tester.

## Direct exponent API

For an odd trial prime d, `d | M_q` exactly when `ord_d(2) | q`. An immutable plan computes these orders once, omits even orders for odd q, and drops later orders already covered by an earlier retained factor. The 6,541 ascending odd primes through 65,521 reduce to 479 progressions. CPU and Metal preserve the first supplied proper factor; zero means unresolved.

```crystal
require "./exponent_sieve"

plan = MersenneLab::ExponentSievePlan.new([7_u32, 23_u32, 31_u32])
factors = plan.sieve_odd_window(17_u32, 1_048_576)
```

With `require "./metal_backend"` and a constructed backend:

```crystal
begin
  factors = backend.sieve_exponents(plan, 17_u32, 1_048_576, tile_size: 256)
  plan.verify_witnesses_odd_window!(17_u32, 1_048_576, factors)
ensure
  backend.close
end
```

Each call accepts at most 16,777,216 candidates. CPU starts at any positive odd UInt32 q; Metal requires q>=17. The final exponent must fit UInt32. Factors must be genuine odd primes <=65,535. Tiles are 1..65,536, with a checked grid limit. Empty windows and factor lists are supported. Plans copy their inputs and exposed arrays; calls/close are serialized per Metal instance. Shared GPU output is copied into an owned array after synchronous completion.

This bounded table cannot filter Mersenne candidates whose exponent is prime and greater than 32,760. Prime-exponent selection and a specialized final Mersenne tester are necessary future baselines for search-level claims; the matched experiment preserves the visible author's all-odd-q schedule.

## Earlier progression algorithm and contract

For an odd trial prime `d != 3`, compute the class

```text
k mod d = ((2^m)^(-1) - 1) * 3^(-1) mod d.
```

A prepared plan stores one class per supplied factor. Arbitrary candidates can be checked against those classes. For a dense odd window `k = start + 2*i`, solve for the first matching index and mark successive matches at stride `d`. This avoids a divisibility operation for every candidate/factor pair. Residue-class sieving is standard modular arithmetic, not a new primality theorem.

The exception `d = 3` divides every candidate for even `m` and none for odd `m`. With even `m` and first-ranked 3, the window is filled on the CPU. Metal otherwise seeds the rank of 3 and dispatches only the earlier factor prefix. Its parallel kernel minimizes **original factor rank**, preserving unsorted and duplicate lists.

Every result is the first supplied proper divisor or `0` for unresolved. CPU inputs are positive `UInt32` exponents, positive odd `UInt64` candidates, and genuine odd primes through 65,535. GPU inputs additionally require `m >= 15`, so every admitted factor is smaller than `G_m(1)`. CPU code checks this strict inequality at smaller exponents. Reduce `k` before multiplying to handle `UInt64::MAX` safely.

Dense windows have a checked endpoint, nonnegative count at most 16,777,216, and a positive odd start even for an empty window. Metal tiles are 1..65,536 and its factor/tile grid must fit `Int32`. Plan arrays are copied on input and when returned. Keep caller-owned arrays unchanged throughout a backend call.

General odd `k` values are mostly **general progression candidates**. For odd base `m`, the exact Mersenne subset is `k = (4^j - 1)/3`, giving exponent `m + 2*j`. The schedule harness compares that subset, a legacy odd-`k` scan, and prime-exponent selection over identical finite intervals. It uses GMP probable-prime screening, not a primality certificate. Executed ranges require upper exponent <=127 and gap <=16; larger legacy counts have a separate analytic helper with gap <=62.

## Files

- `core.cr`, `spec/core_spec.cr`: unchanged modular reference and independent BigInt checks.
- `prepared_sieve.cr`, `spec/prepared_sieve_spec.cr`: immutable plans, sparse and dense CPU paths, optional witness verification.
- `exponent_sieve.cr`, `spec/exponent_sieve_spec.cr`: immutable direct-exponent plans, directional order pruning, proper-factor guards and CPU marking.
- `metal_backend.cr`, `kernels/mpgs_sieve.metal`, `kernels/mpgs_window.metal`: candidate and residue-marking Metal paths.
- `cuda_backend.cr`, `kernels/mpgs_sieve.ptx`: CUDA candidate path; NVIDIA assembly and execution pending.
- `cpu_demo.cr`, `gpu_demo.cr`, `gpu_window_checks.cr`: demonstrations and executable Metal boundary checks.
- `schedules.cr`, `schedule_demo.cr`, `spec/schedules_spec.cr`: candidate-schedule comparison.
- `benchmark.cr`, `scripts/run_benchmarks.py`, `results/benchmark.json`: release benchmark and raw repeated measurements.
- `scale_probe.cr`, `results/scale.json`: large-window probe through the admitted maximum, using the prepared CPU marker as comparator.
- `jabari_adapters.cr`, `spec/jabari_adapters_spec.cr`, `jabari_benchmark.cr`: finite adaptations of the PDF and current forum generators, sharing one GMP tester with the filtered paths.
- `billion_probe.cr`, `scripts/run_jabari_comparison.py`, `results/jabari_comparison.json`: full classification comparisons, stratified pipeline estimates, and directly executed billion-item sieves.
- `COMPARISON.md`: measured comparison with the visible Jabari generators and its explicit normalization limits.
- `exponent_benchmark.cr`, `exponent_billion_probe.cr`, `scripts/run_exponent_comparison.py`, `results/exponent_comparison.json`: direct-q complete pipelines, tile/scale probes and directly executed billion-exponent filtering.
- `gpu_exponent_checks.cr`, `exponent_order_checks.cr`, `scripts/check_exponent_orders.py`, `results/order_oracle.json`: independent GPU expectations and minimal-order oracle/checks.
- `EXPONENT_DESIGN.md`, `EXPONENT_COMPARISON.md`: direct-exponent contract and the current comparison.
- `scripts/check_metal_compile_isolation.py`: intentional window-shader failure test for both window APIs.
- `DESIGN.md`, `REVIEW.md`, `reply.md`: earlier contract, hostile-review findings, and proposed collaboration message.

## Dependency layout and lifecycle

CPU code needs Crystal and its standard `big` library/GMP. GPU wrappers import [cogni-ml](https://github.com/skuznetsov/cogni-ml) directly and expect:

```text
workspace/
  Crystal/cogni-ml/
  Math/mersenne-lab/
```

To reproduce that layout:

```sh
mkdir -p workspace/Crystal workspace/Math
git clone https://github.com/skuznetsov/cogni-ml.git workspace/Crystal/cogni-ml
git clone https://github.com/skuznetsov/mersenne-crystal-lab.git workspace/Math/mersenne-lab
cd workspace/Math/mersenne-lab
```

Adjust the relative `require` in each GPU wrapper for another layout. Metal needs cogni-ml's `build/bridge.o`; see its build instructions. CUDA needs the NVIDIA driver library. Kernels are embedded at compilation, so a moved executable does not need its source directory.

Use `ensure` to call `close`. Calls and close are serialized per backend instance; closed instances reject sieve operations. Metal initializes the candidate pipeline first and compiles the shared odd-k/direct-q window pipeline lazily; a window compilation failure leaves the candidate API usable. At most two pipelines are cached for process lifetime because the current cogni-ml bridge exposes no pipeline-release operation; `close` releases the instance's usable state, not those cached handles. Per-call Metal buffers are released. External device reset while using these caches is unsupported.

The CUDA wrapper binds its own context for operations, restores the caller's context, uses that context's default stream, and checks context destruction. These lifecycle changes passed Crystal type checking only. CUDA runtime behavior, multi-instance context switching, threaded use, and cleanup errors still require NVIDIA tests. The inherited module/buffer cleanup API does not report every driver cleanup error.

## Run

From `Math/mersenne-lab`:

```sh
crystal spec spec/
crystal run cpu_demo.cr
crystal run exponent_order_checks.cr
crystal run schedule_demo.cr
crystal run schedule_demo.cr -- 31 47
crystal build benchmark.cr --release -o /tmp/mpgs-cpu-benchmark
/tmp/mpgs-cpu-benchmark 65536 65521 5 136279841
```

On macOS, substitute your absolute cogni-ml bridge path:

```sh
crystal build gpu_demo.cr -Dmpgs_metal --link-flags='/absolute/path/to/cogni-ml/build/bridge.o -lc++' -o /tmp/mpgs-metal-demo
/tmp/mpgs-metal-demo 136279841 4096
crystal build gpu_window_checks.cr --release --link-flags='/absolute/path/to/cogni-ml/build/bridge.o -lc++' -o /tmp/mpgs-window-checks
/tmp/mpgs-window-checks
crystal build gpu_exponent_checks.cr --release --link-flags='/absolute/path/to/cogni-ml/build/bridge.o -lc++' -o /tmp/mpgs-exponent-checks
/tmp/mpgs-exponent-checks
crystal build exponent_benchmark.cr --release --mcpu=native --link-flags='/absolute/path/to/cogni-ml/build/bridge.o -lc++' -o /tmp/mpgs-exponent-benchmark
/tmp/mpgs-exponent-benchmark final 1024 17 5 4096
/tmp/mpgs-exponent-benchmark filter 16777216 17 5 256
crystal build benchmark.cr --release -Dmpgs_metal --link-flags='/absolute/path/to/cogni-ml/build/bridge.o -lc++' -o /tmp/mpgs-metal-benchmark
python3 scripts/run_benchmarks.py --binary /tmp/mpgs-metal-benchmark --hardware 'Your GPU and memory' --dependency-root /absolute/path/to/cogni-ml --build-command 'The exact release build command used above'
python3 scripts/check_metal_compile_isolation.py --dependency-root /absolute/path/to/cogni-ml
crystal build scale_probe.cr --release --link-flags='/absolute/path/to/cogni-ml/build/bridge.o -lc++' -o /tmp/mpgs-scale-probe
/tmp/mpgs-scale-probe 16777216
```

On NVIDIA/Linux (not executed here):

```sh
crystal build gpu_demo.cr -Dmpgs_cuda -o /tmp/mpgs-cuda-demo
/tmp/mpgs-cuda-demo 136279841 4096
```

This host's Crystal 1.21.0/Xcode linker combination needed `--link-flags=-fuse-ld=/usr/bin/ld` for CPU builds and the same option appended to Metal link flags. A scratch `CRYSTAL_CACHE_DIR` under `/private/tmp` kept compiler output outside the source tree.

## Optional result checking

With a constructed Metal backend and `require "./metal_backend"`:

```crystal
plan = MersenneLab::SievePlan.new(136279841_u32, [5_u32, 7_u32, 11_u32])
witnesses = backend.sieve_odd_window(plan, 1_u64, 4096)
plan.verify_witnesses_odd_window!(1_u64, 4096, witnesses)
```

Both plan checkers recompute direct modular divisibility without using prepared roots/orders. They reject unsupported, non-dividing, and non-proper witnesses. They accept zeros as unresolved and do **not** verify coverage, first-factor precedence, or primality. Exact reference comparisons remain the stronger check for those sieve-output properties. The earlier benchmark includes the progression checker cost as `metal_window_checked_prepared`.

## Observed validation, 2026-10-12

Crystal 1.21.0, aarch64 macOS, Apple M2 Max with 64 GiB unified memory. The consumed cogni-ml HEAD was `7cccdd8bfb02ac388001ab7a61832087d8d1b450`; existing unrelated changes were preserved.

- Full CPU suite: **45 examples, 0 failures/errors** after adding direct-exponent filtering. Independent BigInt expectations include equality guards, low exponents, factor order/pruning, high candidate values, finite classifications, and compatible-k rebasing.
- Metal: **767 window comparisons matched**, including maximum `UInt64` endpoints, maximum `UInt32` exponent, partial tiles, divisor 3, factor 65,521, duplicate/reversed lists, alternating backend instances, invalid inputs, grid bounds, and use after close. An intentionally invalid window shader was rejected while the candidate API remained usable before and after that failure.
- Direct-exponent Metal: **611 independent comparisons matched**, including maximum UInt32 endpoints, partial tiles, reordered/duplicate factors, invalid inputs and backend lifecycle. The order oracle independently computed all 6,541 minimal orders with 116,098,142 repeated doublings; the Crystal checker found zero mismatches and reproduced the 479 retained groups.
- Direct-q comparison: four finite shared-GMP intervals, five tile probes and four additional scale probes matched. **Three full billion-exponent rounds matched every factor entry**, with 758,662,628 proper-factor witnesses and 241,337,372 unresolved entries per pass. Median prepared filtering: CPU 3.326 s, Metal 2.830 s. No candidate BigInts or final primality tests in the billion run. Full metadata/raw samples: `results/exponent_comparison.json`.
- Candidate Metal demo: controls and a 4,096-candidate batch matched the CPU reference; 2,623 proper-factor witnesses and 1,473 unresolved results at the large seed with primes through 97.
- CUDA: `crystal build gpu_demo.cr -Dmpgs_cuda --no-codegen` passed. PTX assembly, driver linking, and NVIDIA execution remain unverified.
- Release benchmark: ten finite cases, two warmups per method, five timed repetitions in rotating/reversed order, exact result equality outside timing. Raw samples, source hashes, input bounds, and initialization cost are in `results/benchmark.json`.
- Scale probe: 1,048,576, 4,194,304, and 16,777,216 candidates with 6,541 factors matched the prepared CPU marker. Its nonzero factors were checked with direct modular arithmetic; coverage is compared to that CPU marker, not independently reproved. At the maximum count, median full calls were 104.50 ms for CPU and 47.94 ms for Metal. Raw samples and scope are in `results/scale.json`.
- Earlier normalized Jabari comparison: **12 cases, 2,754,080 candidate entries per comparison**, identical final classifications with shared GMP(25). The previous rebased Mersenne-only Metal adapter was slower on all three intervals; the direct-q implementation above supersedes that adapter.
- Earlier odd-k billion-item sieve: **three full rounds at each of two exponents**, every CPU/Metal factor entry matched. At m=31 the median CPU/Metal times were 8.351/3.219 seconds; at m=136279841 they were 7.726/2.877 seconds. These concern the PDF progression, not the direct-q stream, and exclude final primality testing. See `COMPARISON.md` for that experiment and its separately qualified full-pipeline estimates.

Full-call timings include factor validation/preparation; prepared timings reuse a plan. GPU calls include allocation, transfer, dispatch, synchronization, readback/output copying and result mapping when dispatched. Backend initialization and compilation are excluded. Earlier filter-only k-array construction is excluded; matched rebased finite pipelines include that construction. Factor-3 host shortcuts are identified separately. There is no automatic CPU/GPU selection policy and no universal GPU speedup claim. See `REVIEW.md` for measured comparisons and remaining risks.

Measurements are from one host, with no controlled temperature or background load. The matched comparison adds shared GMP probable-prime screening to the filter prototype; primality certificates, specialized large-Mersenne testing, and a substantive new research result remain future joint work. Refresh correctness and performance evidence after source, dependency, compiler, GMP, hardware, or driver changes.
