# Direct exponent sieve

Status: VERIFIED within the admitted contract and executed checks, 2026-10-12. Scoped adversary verdict: ROBUST. Performance remains a one-host exploratory observation.

The current Mersenne generator visits `M_q=2^q-1` for consecutive odd q. The former GPU adapter rebuilt compatible-k runs every 32 exponents; at 1,024 candidates it took 903 ms including survivor GMP, versus 394 ms for generator + GMP. The requested change is direct exponent-window filtering with one GPU dispatch per window.

## Admitted design and boundary

For an odd trial prime d, let r be the multiplicative order of 2 modulo d. Then d divides M_q exactly when r divides q. An even r cannot divide an odd q. Prepare each odd r once, retain the earliest supplied factor for duplicate orders, and mark indices in `q=start+2*i` at stride r. A later order r can also be omitted when an earlier retained order a divides r: all its hits already have an earlier witness. This optimization is directional; a divisor order appearing later cannot replace an earlier witness. The 6,541 ascending trial primes through 65,521 have 1,824 distinct odd orders and retain 479 after this pruning.

For strict a<r and r|q, the earlier prime divides M_a and M_a<M_q, so its witness is proper even at low q. For a=r, equal-order grouping is safe: if the first factor equals M_q then M_q is prime, and no other same-order prime can be a smaller proper factor. CPU still suppresses self-witnesses at q=3,5,7,13.

The GPU reuses the existing residue-marking kernel with exponent offsets and order strides; it needs no candidate BigInts, UInt64 k values, or additional retained pipeline. Its output uses explicitly shared Metal storage. The CPU initializes that storage before synchronous dispatch, then constructs an owned factor array after commit-and-wait and before releasing the buffer. This removes the separate output upload/readback copies and rank-mapping pass without letting a pointer escape the buffer lifetime.

Inputs: genuine odd trial primes through 65,535; positive odd UInt32 starting exponent; nonnegative Int32 count at most 16,777,216; checked UInt32 final exponent. CPU supports low exponents with a strict candidate-greater-than-factor guard. GPU requires start >=17, so every supplied factor is smaller than every candidate. Returned witnesses preserve the first supplied proper factor; zero remains unresolved. Plans copy inputs and exposed arrays. Metal call/close serialization and existing allocation cleanup remain applicable.

Reject even/zero exponents, overflowing endpoints, unsupported/composite factors, invalid counts/tiles, and oversized dispatch grids. Keep primality certification, arbitrary exponent arrays, even-exponent windows, and NVIDIA execution outside this slice. Preserve every odd q, including composite q; this is factor screening, not an added exponent-primality selector.

## Discriminators and completion signal

- Independently compute exact factor arrays with bounded BigInts and separate modular exponentiation at large exponents. Attack equal-factor cases, same-order and dominated factors, reversed precedence, unsorted duplicates, empty inputs, UInt32 endpoints, partial tiles, shared-buffer lifetime, and closed backends.
- Check preparation's orders against minimal orders from repeated doubling over all admitted trial primes used in benchmarks.
- Require exact CPU/Metal witness equality and full GMP classification equality on identical finite intervals. Qualify positive controls and a deliberately false witness.
- Compare the old rebased path, direct CPU, direct Metal, and generator + shared GMP with warmups, rotating repeated measurements, preparation and survivor BigInt/GMP costs visible. Separately measure large filter-only windows; do not extrapolate full growing-exponent primality work.
- Run all CPU specs and old Metal boundary checks after integration. A mismatch rejects the affected path; a slower GPU result is recorded without weakening the timing boundary.

Rollback: a source-only local snapshot precedes edits; new plan/tests/harnesses are isolated additions and the existing Metal backend change is one API addition. The external cogni-ml checkout is read-only. The lab started outside Git; the user subsequently requested a public repository for the completed experiment.

## Executed closure signals

The full CPU suite passed 45 examples. `exponent_order_checks.cr` compared all 6,541 orders against an independently generated repeated-doubling oracle with zero mismatches, reproduced 479 retained groups, and passed 128 q cases, 11 precedence probes and endpoint guards. `gpu_exponent_checks.cr` passed 611 independent output comparisons and rejected 11 invalid cases. Existing `gpu_window_checks.cr` passed 767 comparisons after integration. Intentional window compilation failure was isolated for both window APIs.

The matched harness ran four finite shared-GMP windows, five tile probes and four additional filter-scale windows. The streaming harness executed a billion odd exponents per round for three rounds; every CPU/Metal factor entry matched. Commands, raw samples, timing boundaries, hashes and residual risks are in [EXPONENT_COMPARISON.md](EXPONENT_COMPARISON.md) and its linked results. CPU/Metal streaming agreement uses the production CPU comparator; independent coverage evidence is bounded by the oracle and separate arithmetic probes.

The table cannot screen prime exponents above 32,760 with these trial factors. Prime-exponent selection, specialized final Mersenne testing, NVIDIA execution and search-level superiority remain outside this completed slice. Refresh after source, dependency, compiler, GMP, hardware, driver or input changes; a mismatch reopens the affected claim.
