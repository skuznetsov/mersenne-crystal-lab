require "json"
require "./jabari_adapters"
require "./metal_backend"

# Matched finite candidate sets with one visible GMP probable-prime backend.
# The author's unpublished Crystal primes-utils is NOT reproduced here.
raise ArgumentError.new("usage: jabari_benchmark progression|mersenne [count [start [exponent [repeats [prime_cap]]]]]") if ARGV.empty? || ARGV.size > 6
mode = ARGV[0]
raise ArgumentError.new("mode must be progression or mersenne") unless {"progression", "mersenne"}.includes?(mode)
count = (ARGV[1]? || "65536").to_i32
start = (ARGV[2]? || (mode == "progression" ? "1" : "17")).to_u64
exponent = (ARGV[3]? || "31").to_u32
repeats = (ARGV[4]? || "5").to_i32
cap = (ARGV[5]? || "65521").to_i32
raise ArgumentError.new("count must be positive and at most 1048576") unless 1 <= count <= 1_048_576
raise ArgumentError.new("repeats must be odd in 3..9") unless repeats.odd? && 3 <= repeats <= 9
raise ArgumentError.new("prime cap must be in 3..65535") unless 3 <= cap <= 65535
raise ArgumentError.new("Mersenne start exponent exceeds UInt32") if mode == "mersenne" && start > UInt32::MAX

composite = Array(Bool).new(cap + 1, false)
primes = [] of UInt32
(3..cap).step(2) do |p|
  next if composite[p]
  primes << p.to_u32
  (p*p..cap).step(2*p) { |j| composite[j] = true } if p.to_i64 * p <= cap
end
expected = if mode == "progression"
             MersenneLab::JabariAdapters.baseline_progression(exponent, start, count)
           else
             MersenneLab::JabariAdapters.baseline_mersenne(start.to_u32, count)
           end
init_start = Time.instant
backend = MersenneLab::MetalSieve.new
initialization_ms = (Time.instant - init_start).total_seconds * 1000

# A rebased compatible-k batch has at most 32 entries, since k_32 fits
# UInt64 and k_33 does not. Its construction and plans stay inside timing.
mersenne_witnesses = ->(use_metal : Bool) {
  witnesses = Array(UInt32).new(count, 0_u32)
  processed = 0
  while processed < count
    batch_count = Math.min(32, count - processed)
    first_q = start.to_u32 + 2_u32 * processed.to_u32
    base = first_q - 2_u32
    k = 1_u64
    ks = Array(UInt64).new(batch_count)
    batch_count.times do |i|
      ks << k
      k = 4_u64 * k + 1_u64 if i + 1 < batch_count
    end
    batch = if use_metal
              backend.sieve(base, ks, primes)
            else
              MersenneLab::SievePlan.new(base, primes).sieve(ks)
            end
    batch.each_with_index { |factor, i| witnesses[processed + i] = factor }
    processed += batch_count
  end
  witnesses
}
methods = Hash(String, Proc(MersenneLab::JabariAdapters::Result)).new
if mode == "progression"
  methods["jabari_pdf_normalized_gmp"] = -> { MersenneLab::JabariAdapters.baseline_progression(exponent, start, count) }
  methods["ours_cpu_full_pipeline"] = -> {
    factors = MersenneLab::SievePlan.new(exponent, primes).sieve_odd_window(start, count)
    MersenneLab::JabariAdapters.screen_progression(exponent, start, factors)
  }
  methods["ours_metal_full_pipeline_tile4096"] = -> {
    factors = backend.sieve_odd_window(exponent, start, count, primes, 4096)
    MersenneLab::JabariAdapters.screen_progression(exponent, start, factors)
  }
else
  methods["jabari_post5_normalized_gmp"] = -> { MersenneLab::JabariAdapters.baseline_mersenne(start.to_u32, count) }
  methods["ours_cpu_rebased_full_pipeline"] = -> {
    MersenneLab::JabariAdapters.screen_mersenne(start.to_u32, mersenne_witnesses.call(false))
  }
  methods["ours_metal_rebased_full_pipeline"] = -> {
    MersenneLab::JabariAdapters.screen_mersenne(start.to_u32, mersenne_witnesses.call(true))
  }
end
samples = Hash(String, Array(Float64)).new
screen_calls = Hash(String, UInt64).new
methods.each_key { |name| samples[name] = [] of Float64 }
begin
  methods.each do |name, method|
    2.times do
      result = method.call
      raise "warmup final-state mismatch: #{name}" unless result.states == expected.states
      screen_calls[name] = result.prime_screen_count
    end
  end
  names = methods.keys
  repeats.times do |iteration|
    order = names.rotate(iteration % names.size)
    order.reverse! if iteration.odd?
    order.each do |name|
      started = Time.instant
      result = methods[name].call
      elapsed = (Time.instant - started).total_seconds * 1000
      raise "measured final-state mismatch: #{name}" unless result.states == expected.states
      raise "screen count changed: #{name}" unless screen_calls[name] == result.prime_screen_count
      samples[name] << elapsed
    end
  end
  hits = [] of UInt64
  expected.states.each_with_index do |state, index|
    next unless state == 2
    q = if mode == "mersenne"
          start + 2_u64 * index.to_u64
        else
          candidate_k = start + 2_u64 * index.to_u64
          ((candidate_k.to_big_i * 3 + 1) << exponent).bit_length.to_u64 - 1_u64
        end
    hits << q
  end
  STDOUT.puts JSON.build { |json|
    json.object do
      json.field "mode", mode
      json.field "count", count
      json.field "start", start
      json.field "progression_exponent", mode == "progression" ? exponent : nil
      json.field "prime_cap", cap
      json.field "prime_count", primes.size
      json.field "gmp_repetitions", MersenneLab::Schedules::GMP_REPETITIONS
      json.field "repeats", repeats
      json.field "warmups_per_method", 2
      json.field "backend_initialization_ms", initialization_ms
      json.field "metal_device", backend.device_name
      json.field "all_final_states_equal", true
      json.field "probable_primes", expected.states.count { |state| state != 0 }
      json.field "probable_mersenne_exponents", hits
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
      json.field "scope", "Finite matched candidate sets; shared GMP probable-prime(25), not the author's unavailable Crystal primes-utils. Full filter preparation, candidate construction and survivor GMP tests included; console I/O, dynamic seed changes, GPU initialization/compilation and final equality checks excluded. Progression seed fixed. Mersenne paths preserve every odd exponent and include 32-candidate rebasing overhead; existing dense odd-k optimization cannot apply to this sparse sequence."
    end
  }
ensure
  backend.close
end
