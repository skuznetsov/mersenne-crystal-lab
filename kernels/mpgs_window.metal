#include <metal_stdlib>
using namespace metal;

// One thread per (original factor rank, index tile). Host solves the residue
// class; this kernel visits only matching indices. UINT_MAX means unresolved.
// Minimize rank, not divisor value, to preserve arbitrary supplied factor order.
// Host guarantees proper factors: progression m >= 15 or Mersenne q >= 17;
// checked odd UInt64 k / UInt32 q window; count <= 2^24; positive strides;
// genuine odd primes <= 65535. Strides can be factor primes or orders of two.
kernel void mpgs_window(
    device const uint* offsets [[buffer(0)]],
    device const uint* strides [[buffer(1)]],
    device atomic_uint* ranks [[buffer(2)]],
    constant uint& count [[buffer(3)]],
    constant uint& factor_count [[buffer(4)]],
    constant uint& tile_size [[buffer(5)]],
    constant uint& tile_count [[buffer(6)]],
    uint tid [[thread_position_in_grid]]) {
  const uint rank = tid / tile_count;
  if (rank >= factor_count) return;
  uint index = offsets[rank];
  if (index == 0xffffffffu) return;
  const uint stride = strides[rank];
  const uint begin = (tid % tile_count) * tile_size;
  const uint end = min(begin + tile_size, count);
  if (index < begin) {
    index += ((begin - index + stride - 1u) / stride) * stride;
  }
  for (; index < end; index += stride) {
    atomic_fetch_min_explicit(&ranks[index], rank, memory_order_relaxed);
  }
}
