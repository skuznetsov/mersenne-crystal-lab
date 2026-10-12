# Bounded sieve contract

Status: bounded CPU and Metal residue-class extension executed and checked; CUDA remains type-checked only. Evidence and residual risks are recorded in `REVIEW.md`.

The reference computes proper-factor witnesses for `G_m(k) = 2^m(3k+1)-1`. The extension must return exactly the same first supplied factor, including unsorted and duplicate factor lists. Zero means unresolved. No path may infer primality from zero.

## Admitted and rejected inputs

- CPU: positive UInt32 exponent; positive odd UInt64 candidates; genuine odd primes through 65,535.
- Dense windows: `k = start + 2*i`, positive odd start, nonnegative Int32 count, and a checked UInt64 endpoint. Empty windows are valid, but do not bypass input validation.
- GPU: the same factor domain and exponent at least 15. Backend operations are serialized per instance. Metal uses process-lifetime cached pipelines; CUDA operations must bind and restore their own context.
- Rejected: wrapping window endpoints, composite factors, even/zero candidates, exponent zero, windows larger than 16,777,216 candidates, an unbounded search, and a claimed NVIDIA execution result without NVIDIA hardware. Each backend serializes its operations; caller-owned input arrays must stay unchanged for a call's duration.

## Residue-class law

For an odd prime `d != 3`, `2^m` and 3 are invertible, so divisibility is equivalent to

`k mod d = ((2^m)^(-1) - 1) * 3^(-1) mod d`.

For `d = 3`, all candidates are divisible when `m` is even, and none when `m` is odd. Small CPU exponents still require `G_m(k) > d`; this excludes a candidate equal to its purported factor.

In a dense odd window, multiplication by 2 is invertible modulo every admitted factor. Solve for the first matching index, then mark indices at stride `d`. Factor order determines witness precedence. A parallel marker must minimize the original factor rank, not the numerical divisor. Input arrays must not mutate a prepared plan.

For even `m`, a first-ranked factor 3 resolves the entire window on the host after input validation. With a later factor 3, Metal seeds its rank and dispatches only earlier factors; ranks after that first 3 cannot change the required witness. An optional checker recomputes direct modular divisibility of each nonzero witness without consulting prepared roots. It verifies soundness, not coverage, first-factor precedence, or primality.

## Falsifiers and measurements

Before admitting the extension, compare it against independently constructed BigInt candidates over small exponents and bounded windows, including candidate-equals-factor, divisor 3, reversed/duplicate lists, no hits, empty inputs, and the UInt64 endpoint. Cross-check large exponents against the unchanged modular reference. Verify invalid inputs and use after close.

Run CPU specs, Metal correctness controls, and CUDA Crystal type checking. CUDA assembly, driver linking, execution, context switching, and concurrency remain pending on NVIDIA. PTX is embedded at build time so a moved binary does not depend on its source directory.

Measure release builds using warmups, repeated rotating method order, identical inputs, equality checks outside timed sections, and separate plan preparation from execution. Report full-call timings alongside prepared-plan timings and allocation scope. A small-factor sieve benchmark cannot establish end-to-end primality performance or superiority over GIMPS.

Rollback: a source-only pre-review snapshot is retained locally. The unchanged reference is also a fallback for checking optimized results. The external `cogni-ml` checkout is read-only throughout this work.
