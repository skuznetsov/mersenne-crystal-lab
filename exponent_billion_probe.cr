require "json"
require "./metal_backend"

# Executes the complete odd-exponent interval in bounded streaming windows.
# This times only small-factor screening, never billion growing BigInts/PRPs.
raise ArgumentError.new("usage: exponent_billion_probe [count [start_q [repeats [tile_size]]]]") if ARGV.size > 4
total = (ARGV[0]? || "1000000000").to_u64
start = (ARGV[1]? || "17").to_u32
repeats = (ARGV[2]? || "3").to_i32
tile = (ARGV[3]? || "4096").to_i32
raise ArgumentError.new("count must be in 1..1000000000") unless 1 <= total <= 1_000_000_000
raise ArgumentError.new("start must be odd and at least 17") unless start.odd? && start >= 17
raise ArgumentError.new("last exponent overflows UInt32") if start.to_u64 + 2_u64 * (total - 1) > UInt32::MAX.to_u64
raise ArgumentError.new("repeats must be odd in 3..5") unless repeats.odd? && 3 <= repeats <= 5
raise ArgumentError.new("tile size must be in 1..65536") unless 1 <= tile <= 65536
cap = 65521
composite = Array(Bool).new(cap + 1, false)
primes = [] of UInt32
(3..cap).step(2) do |p|
  next if composite[p]
  primes << p.to_u32
  (p*p..cap).step(2*p) { |j| composite[j] = true } if p.to_i64 * p <= cap
end
started = Time.instant
plan = MersenneLab::ExponentSievePlan.new(primes)
preparation_ms = (Time.instant - started).total_seconds * 1000
backend = MersenneLab::MetalSieve.new
cpu_samples = [] of Float64
metal_samples = [] of Float64
factor_count = 0_u64
limit = MersenneLab::ExponentSievePlan::MAX_WINDOW_COUNT
windows = (total + limit - 1) // limit
begin
  warm_count = Math.min(total, 65536_u64).to_i32
  2.times do
    warm = plan.sieve_odd_window(start, warm_count)
    raise "warmup mismatch" unless backend.sieve_exponents(plan, start, warm_count, tile) == warm
  end
  repeats.times do |round|
    processed = 0_u64
    cpu_ms = 0.0
    metal_ms = 0.0
    while processed < total
      count = Math.min(limit.to_u64, total - processed).to_i32
      q = (start.to_u64 + 2_u64 * processed).to_u32
      cpu_factors = [] of UInt32
      metal_factors = [] of UInt32
      order = (round + (processed // limit).to_i32).even? ? {0, 1} : {1, 0}
      order.each do |method|
        started = Time.instant
        if method == 0
          cpu_factors = plan.sieve_odd_window(q, count)
          cpu_ms += (Time.instant - started).total_seconds * 1000
        else
          metal_factors = backend.sieve_exponents(plan, q, count, tile)
          metal_ms += (Time.instant - started).total_seconds * 1000
        end
      end
      raise "streaming factor mismatch at q=#{q}" unless cpu_factors == metal_factors
      factor_count += cpu_factors.count { |d| d != 0 }.to_u64 if round == 0
      processed += count.to_u64
    end
    cpu_samples << cpu_ms
    metal_samples << metal_ms
    STDERR.puts "round #{round + 1}/#{repeats}: #{total} odd exponents equal, CPU #{cpu_ms.round(2)} ms, Metal #{metal_ms.round(2)} ms"
  end
  puts JSON.build { |json|
    json.object do
      json.field "count", total
      json.field "start_q", start
      json.field "last_q", start.to_u64 + 2_u64 * (total - 1)
      json.field "prime_cap", cap
      json.field "prime_count", primes.size
      json.field "active_order_count", plan.active_count
      json.field "window_limit", limit
      json.field "windows_per_round", windows
      json.field "tile_size", tile
      json.field "metal_device", backend.device_name
      json.field "warmups", 2
      json.field "repeats", repeats
      json.field "checked_candidates", total * repeats.to_u64
      json.field "all_factor_arrays_equal", true
      json.field "proper_factor_witnesses", factor_count
      json.field "unresolved", total - factor_count
      json.field "one_plan_preparation_ms", preparation_ms
      json.field "cpu_prepared" do
        json.object do
          json.field "median_ms", cpu_samples.sort[repeats // 2]
          json.field "samples_ms", cpu_samples
        end
      end
      json.field "metal_prepared" do
        json.object do
          json.field "median_ms", metal_samples.sort[repeats // 2]
          json.field "samples_ms", metal_samples
        end
      end
      json.field "scope", "Complete streaming direct-exponent small-factor sieve; every entry compared outside timing. Reused plan; allocation, transfers, dispatch, synchronization, readback and result mapping included. Equality/counting, initialization and kernel compilation excluded. No BigInt candidate construction or final primality tests; no constant-cost full billion-exponent extrapolation."
    end
  }
ensure
  backend.close
end
