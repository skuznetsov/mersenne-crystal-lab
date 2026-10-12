require "json"
require "./jabari_adapters"
require "./metal_backend"

def benchmark_primes(cap : Int32) : Array(UInt32)
  composite = Array(Bool).new(cap + 1, false)
  primes = [] of UInt32
  (3..cap).step(2) do |p|
    next if composite[p]
    primes << p.to_u32
    (p*p..cap).step(2*p) { |j| composite[j] = true } if p.to_i64 * p <= cap
  end
  primes
end

# The same checked finite schedule as the preceding comparison. Its old
# 32-entry compatible-k rebasing stays in the clock for both legacy paths.
def rebased_exponent_factors(backend, use_metal, start, count, primes)
  factors = Array(UInt32).new(count, 0_u32)
  processed = 0
  while processed < count
    size = Math.min(32, count - processed)
    base = start + 2_u32 * processed.to_u32 - 2_u32
    k = 1_u64
    ks = Array(UInt64).new(size)
    size.times do |i|
      ks << k
      k = 4_u64 * k + 1_u64 if i + 1 < size
    end
    batch = use_metal ? backend.sieve(base, ks, primes) : MersenneLab::SievePlan.new(base, primes).sieve(ks)
    batch.each_with_index { |factor, i| factors[processed + i] = factor }
    processed += size
  end
  factors
end

# Rotated/reversed execution order limits simple order bias. Equality and
# screen-call checks are performed after each measured clock is stopped.
def measure_methods(methods : Hash(String, Proc(T)), repeats : Int32, &verify : String, T -> UInt64) forall T
  samples = Hash(String, Array(Float64)).new
  calls = Hash(String, UInt64).new
  methods.each do |name, method|
    samples[name] = [] of Float64
    2.times { calls[name] = verify.call(name, method.call) }
  end
  names = methods.keys
  repeats.times do |iteration|
    order = names.rotate(iteration % names.size)
    order.reverse! if iteration.odd?
    order.each do |name|
      started = Time.instant
      result = methods[name].call
      samples[name] << (Time.instant - started).total_seconds * 1000
      raise "work count changed: #{name}" unless calls[name] == verify.call(name, result)
    end
  end
  {samples, calls}
end

raise ArgumentError.new("usage: exponent_benchmark final|filter [count [start [repeats [tile_size]]]]") unless 1 <= ARGV.size <= 5
mode = ARGV[0]
raise ArgumentError.new("mode must be final or filter") unless {"final", "filter"}.includes?(mode)
count = (ARGV[1]? || "1024").to_i32
start = (ARGV[2]? || "17").to_u32
repeats = (ARGV[3]? || "5").to_i32
tile = (ARGV[4]? || "4096").to_i32
raise ArgumentError.new("count must be positive") if count <= 0
raise ArgumentError.new("repeats must be odd in 3..9") unless repeats.odd? && 3 <= repeats <= 9
raise ArgumentError.new("tile size must be in 1..65536") unless 1 <= tile <= 65536
primes = benchmark_primes(65521)
started = Time.instant
plan = MersenneLab::ExponentSievePlan.new(primes)
preparation_ms = (Time.instant - started).total_seconds * 1000
expected_factors = plan.sieve_odd_window(start, count)
started = Time.instant
backend = MersenneLab::MetalSieve.new
initialization_ms = (Time.instant - started).total_seconds * 1000
begin
  started = Time.instant
  first_gpu_factors = backend.sieve_exponents(plan, start, count, tile)
  first_gpu_call_ms = (Time.instant - started).total_seconds * 1000
  raise "first GPU call factor mismatch" unless first_gpu_factors == expected_factors
  samples = Hash(String, Array(Float64)).new
  screen_calls = Hash(String, UInt64).new
  hits = [] of UInt32
  if mode == "final"
    expected = MersenneLab::JabariAdapters.baseline_mersenne(start, count)
    raise "old CPU factor mismatch" unless rebased_exponent_factors(backend, false, start, count, primes) == expected_factors
    raise "old Metal factor mismatch" unless rebased_exponent_factors(backend, true, start, count, primes) == expected_factors
    expected.states.each_with_index { |state, i| hits << start + 2_u32 * i.to_u32 if state == 2 }
    methods = Hash(String, Proc(MersenneLab::JabariAdapters::Result)).new
    methods["jabari_post5_normalized_gmp"] = -> { MersenneLab::JabariAdapters.baseline_mersenne(start, count) }
    methods["cpu_rebased_full"] = -> { MersenneLab::JabariAdapters.screen_mersenne(start, rebased_exponent_factors(backend, false, start, count, primes)) }
    methods["metal_rebased_full"] = -> { MersenneLab::JabariAdapters.screen_mersenne(start, rebased_exponent_factors(backend, true, start, count, primes)) }
    methods["cpu_direct_full"] = -> { MersenneLab::JabariAdapters.screen_mersenne(start, MersenneLab::ExponentSievePlan.new(primes).sieve_odd_window(start, count)) }
    methods["cpu_direct_prepared"] = -> { MersenneLab::JabariAdapters.screen_mersenne(start, plan.sieve_odd_window(start, count)) }
    methods["metal_direct_full"] = -> { MersenneLab::JabariAdapters.screen_mersenne(start, backend.sieve_exponents(start, count, primes, tile)) }
    methods["metal_direct_prepared"] = -> { MersenneLab::JabariAdapters.screen_mersenne(start, backend.sieve_exponents(plan, start, count, tile)) }
    samples, screen_calls = measure_methods(methods, repeats) do |name, result|
      raise "final state mismatch: #{name}" unless result.states == expected.states
      result.prime_screen_count
    end
  else
    methods = Hash(String, Proc(Array(UInt32))).new
    methods["cpu_direct_full"] = -> { MersenneLab::ExponentSievePlan.new(primes).sieve_odd_window(start, count) }
    methods["cpu_direct_prepared"] = -> { plan.sieve_odd_window(start, count) }
    methods["metal_direct_full"] = -> { backend.sieve_exponents(start, count, primes, tile) }
    methods["metal_direct_prepared"] = -> { backend.sieve_exponents(plan, start, count, tile) }
    samples, screen_calls = measure_methods(methods, repeats) do |name, factors|
      raise "full factor array mismatch: #{name}" unless factors == expected_factors
      0_u64
    end
  end
  puts JSON.build { |json|
    json.object do
      json.field "mode", mode
      json.field "count", count
      json.field "start_q", start
      json.field "last_q", start.to_u64 + 2_u64 * (count - 1).to_u64
      json.field "prime_cap", 65521
      json.field "prime_count", primes.size
      json.field "active_order_count", plan.active_count
      json.field "tile_size", tile
      json.field "repeats", repeats
      json.field "warmups_per_method", 2
      json.field "plan_preparation_ms", preparation_ms
      json.field "backend_initialization_ms", initialization_ms
      json.field "first_gpu_call_including_kernel_compile_ms", first_gpu_call_ms
      json.field "metal_device", backend.device_name
      json.field "all_outputs_equal", true
      json.field "witnesses", count - expected_factors.count(0_u32)
      json.field "unresolved", expected_factors.count(0_u32)
      json.field "probable_mersenne_exponents", hits
      json.field "gmp_repetitions", mode == "final" ? MersenneLab::Schedules::GMP_REPETITIONS : nil
      json.field "methods" do
        json.object do
          samples.each do |name, values|
            json.field name do
              json.object do
                json.field "median_ms", values.sort[repeats // 2]
                json.field "min_ms", values.min
                json.field "max_ms", values.max
                json.field "samples_ms", values
                json.field "gmp_screen_calls", screen_calls[name]
              end
            end
          end
        end
      end
      json.field "scope", mode == "final" ? "Identical finite M_q inputs and shared GMP(25); author's unpublished primes-utils unavailable. Full variants include plan preparation; prepared variants reuse one plan. Both include allocation, transfer, dispatch, readback and survivor GMP tests. GPU initialization/compilation, equality checks and output excluded. Legacy methods include 32-entry compatible-k rebasing." : "Filter only, no BigInt candidate construction or primality test. Complete factor arrays compared on every run. Full variants include plan preparation; prepared variants reuse one plan. Allocation, transfer, dispatch, synchronization and readback included. GPU initialization/compilation, equality checks and output excluded."
    end
  }
ensure
  backend.close
end
