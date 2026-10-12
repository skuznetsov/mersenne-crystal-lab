require "json"
require "./metal_backend"

# Direct streaming measurement of the small-factor stage, not primality.
raise ArgumentError.new("usage: billion_probe [count [exponent [repeats]]]") if ARGV.size > 3
total = (ARGV[0]? || "1000000000").to_u64
exponent = (ARGV[1]? || "31").to_u32
repeats = (ARGV[2]? || "3").to_i32
raise ArgumentError.new("count must be in 1..1000000000") unless 1 <= total <= 1_000_000_000
raise ArgumentError.new("exponent must be at least 15") if exponent < 15
raise ArgumentError.new("repeats must be odd and in 3..5") unless repeats.odd? && 3 <= repeats <= 5
cap = 65521
composite = Array(Bool).new(cap + 1, false)
primes = [] of UInt32
(3..cap).step(2) do |p|
  next if composite[p]
  primes << p.to_u32
  (p*p..cap).step(2*p) { |j| composite[j] = true } if p.to_i64 * p <= cap
end
prepared_at = Time.instant
plan = MersenneLab::SievePlan.new(exponent, primes)
preparation_ms = (Time.instant - prepared_at).total_seconds * 1000
backend = MersenneLab::MetalSieve.new
cpu_samples = [] of Float64
metal_samples = [] of Float64
factor_count = 0_u64
windows = (total + MersenneLab::SievePlan::MAX_WINDOW_COUNT - 1) // MersenneLab::SievePlan::MAX_WINDOW_COUNT
begin
  # Force both pipelines and the equality comparator before streaming timing.
  warm = plan.sieve_odd_window(1_u64, 65536)
  raise "warmup mismatch" unless backend.sieve_odd_window(plan, 1_u64, 65536, 4096) == warm
  repeats.times do |round|
    processed = 0_u64
    cpu_ms = 0.0
    metal_ms = 0.0
    while processed < total
      n = Math.min(MersenneLab::SievePlan::MAX_WINDOW_COUNT.to_u64, total - processed).to_i32
      start_k = 1_u64 + 2_u64 * processed
      cpu_result = [] of UInt32
      metal_result = [] of UInt32
      order = (round + (processed // MersenneLab::SievePlan::MAX_WINDOW_COUNT).to_i32).even? ? {0, 1} : {1, 0}
      order.each do |method|
        started = Time.instant
        if method == 0
          cpu_result = plan.sieve_odd_window(start_k, n)
          cpu_ms += (Time.instant - started).total_seconds * 1000
        else
          metal_result = backend.sieve_odd_window(plan, start_k, n, 4096)
          metal_ms += (Time.instant - started).total_seconds * 1000
        end
      end
      raise "streaming factor mismatch at #{start_k}" unless cpu_result == metal_result
      factor_count += cpu_result.count { |d| d != 0 }.to_u64 if round == 0
      processed += n.to_u64
    end
    cpu_samples << cpu_ms
    metal_samples << metal_ms
    STDERR.puts "round #{round + 1}/#{repeats}: #{total} candidates equal, CPU #{cpu_ms.round(2)} ms, Metal #{metal_ms.round(2)} ms"
  end
  STDOUT.puts JSON.build { |json|
    json.object do
      json.field "count", total
      json.field "exponent", exponent
      json.field "start_k", 1
      json.field "prime_cap", cap
      json.field "prime_count", primes.size
      json.field "window_limit", MersenneLab::SievePlan::MAX_WINDOW_COUNT
      json.field "windows_per_round", windows
      json.field "tile_size", 4096
      json.field "metal_device", backend.device_name
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
      json.field "scope", "Direct streaming small-factor sieve: every billion-candidate round executed, factor arrays compared outside timing. Plan reused; allocation, transfers, dispatch, synchronization and readback included. Equality checks/counting, backend initialization and pipeline compilation excluded. Not final primality and not a run of Jabari's unpublished backend."
    end
  }
ensure
  backend.close
end
