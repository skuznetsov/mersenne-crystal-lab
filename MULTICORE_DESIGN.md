# Multicore Mersenne screening

Status: verified within the bounded pool contract. The complete CPU suite
passed 55 examples, and all matched finite measurements passed. See
[MULTICORE_COMPARISON.md](MULTICORE_COMPARISON.md) and its raw result record.

The current direct CPU and Metal pipelines screen each surviving candidate with
GMP on one thread. The admitted improvement is a reusable CPU worker pool for
independent candidate tests. This preserves the post-5 all-odd-exponent stream
and the shared GMP(25) tester, with the existing finite q=17..4095 boundary.

## Contract and ownership

- `ParallelMersenne` admits 1..64 workers and chunks of 1..4096 work entries.
- Each worker has its own BigInt/GMP values. Immutable task inputs and fixed
  output storage may be shared; each candidate output has exactly one writer.
- An atomic cursor assigns work dynamically, starting at the largest q. The
  ordered result and actual GMP call count must equal the serial adapter.
- Calls and close are serialized. Close is idempotent, rejects later work,
  and waits for workers. Every worker completion is drained on errors before
  propagation; a failed call must never return partial classifications.
- Input witnesses are copied on admission. A caller must not mutate its array
  concurrently with that copy. A nonzero supplied witness has the same trusted
  upstream-factor meaning as in the existing serial adapter.
- Crystal 1.21 isolated execution contexts own worker threads; the default
  execution context and GMP memory hooks are not changed.

No prime-exponent preselection, primality certification, unbounded searches,
parallel testing of one candidate, CUDA runtime claim, or automatic choice of
worker count is admitted in this slice. Metal may supply factors to the same
parallel final tester, but its dispatch remains serialized.

## Falsifiers and completion signals

The likely correctness failure is duplicate or missing work at uneven chunk
boundaries; the likely lifecycle failure is a worker exception that prevents
completion or close. Specs must attack both, along with empty/no-survivor
inputs, invalid endpoints, repeated calls, concurrent callers, and close.

Run the focused pool specs and the complete CPU suite with the Apple linker.
The matched benchmark must compare every final state and the expected test
count outside timing on every warmup and measured call. Benchmark the serial
post-5 normalized generator and current serial CPU/Metal again in the same
executable, then worker counts 1, 2, 4, 8 and 12. Also parallelize the normalized
generator so that any filter-specific advantage is separated from added CPU
resources. Include task preparation, factor filtering, candidate construction,
scheduling, synchronization and survivor GMP work in complete call timing;
record pool/backend creation separately. Record raw samples and source hashes.

Prediction: independent GMP calls should reduce finite-window wall time, but
one expensive prime candidate, asymmetric M2 cores, allocator/GC effects and
host load can limit scaling. A slower setting remains a measured result; it
does not justify weakening the timing contract. No billion-test extrapolation.

Rollback is the existing Git commit `d78c249`; this slice adds a separate pool
and benchmark without replacing the serial adapter or editing cogni-ml. Refresh
the evidence after pool, caller, compiler, GMP, hardware or workload changes.
