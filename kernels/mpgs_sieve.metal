#include <metal_stdlib>
using namespace metal;

// Exact small-factor sieve for G_m(k) = 2^m * (3*k + 1) - 1.
// The host supplies powers[j] = 2^m mod primes[j]. Each thread returns a
// proper divisor or 0 (unresolved). Host contract: m >= 15, k positive odd,
// every primes[j] an odd prime <= 65535. This is not a primality test.
kernel void mpgs_sieve(
    device const ulong* ks [[buffer(0)]],
    device const uint* primes [[buffer(1)]],
    device const uint* powers [[buffer(2)]],
    device uint* witnesses [[buffer(3)]],
    constant uint& count [[buffer(4)]],
    constant uint& factor_count [[buffer(5)]],
    uint tid [[thread_position_in_grid]]) {
  if (tid >= count) return;
  const ulong k = ks[tid];
  uint witness = 0;
  for (uint j = 0; j < factor_count; ++j) {
    const uint d = primes[j];
    const uint reduced_k = uint(k % ulong(d));
    const uint t = (3u * reduced_k + 1u) % d;
    // Both operands <= 65534, so the exact product fits uint.
    if ((powers[j] * t) % d == 1u) {
      witness = d;
      break;
    }
  }
  witnesses[tid] = witness;
}
