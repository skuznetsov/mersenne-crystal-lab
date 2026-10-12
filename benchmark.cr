require "json"
require "./prepared_sieve"
{% if flag?(:mpgs_metal) %}
  require "./metal_backend"
{% end %}

# Release-build, finite-window comparison. Equality checking is outside every
# timed section. No reported value measures primality testing or GIMPS.
raise ArgumentError.new("usage: benchmark [count [prime_cap [repeats [exponent]]]]") if ARGV.size > 4
count = (ARGV[0]? || "65536").to_i32
cap = (ARGV[1]? || "65521").to_i32
repeats = (ARGV[2]? || "5").to_i32
exponent = (ARGV[3]? || "136279841").to_u32
raise ArgumentError.new("count must be in 1..262144") unless 1 <= count <= 262144
raise ArgumentError.new("prime cap must be in 3..65535") unless 3 <= cap <= 65535
raise ArgumentError.new("repeats must be odd and in 3..21") unless 3 <= repeats <= 21 && repeats.odd?

composite = Array(Bool).new(cap + 1, false)
primes = [] of UInt32
(3..cap).step(2) do |p|
  next if composite[p]
  primes << p.to_u32
  if p.to_i64 * p <= cap
    (p*p..cap).step(2*p) { |j| composite[j] = true }
  end
end
ks = Array(UInt64).new(count) { |i| 1_u64 + 2_u64 * i.to_u64 }
plan = MersenneLab::SievePlan.new(exponent, primes)
expected = MersenneLab.sieve(exponent, ks, primes)
methods = {
  "reference_cpu_full"  => -> { MersenneLab.sieve(exponent, ks, primes) },
  "prepared_cpu_sparse" => -> { plan.sieve(ks) },
  "cpu_window_full"     => -> { MersenneLab::SievePlan.new(exponent, primes).sieve_odd_window(1_u64, count) },
  "cpu_window_prepared" => -> { plan.sieve_odd_window(1_u64, count) },
}
initialization_ms = nil.as(Float64?)
backend = {% if flag?(:mpgs_metal) %}
            init_started = Time.instant
            initialized = MersenneLab::MetalSieve.new
            initialization_ms = (Time.instant - init_started).total_seconds * 1000
            initialized
          {% else %}
            nil
          {% end %}
{% if flag?(:mpgs_metal) %}
  methods["metal_candidate_full"] = -> { backend.sieve(exponent, ks, primes) }
  methods["metal_window_full"] = -> { backend.sieve_odd_window(exponent, 1_u64, count, primes) }
  methods["metal_window_checked_prepared"] = -> {
    witnesses = backend.sieve_odd_window(plan, 1_u64, count)
    plan.verify_witnesses_odd_window!(1_u64, count, witnesses)
    witnesses
  }
  [512, 1024, 4096, 16384, 65536].each do |tile|
    # Capture a distinct binding for each closure.
    tile_size = tile
    methods["metal_window_prepared_tile_#{tile}"] = -> { backend.sieve_odd_window(plan, 1_u64, count, tile_size) }
  end
{% end %}

samples = Hash(String, Array(Float64)).new
methods.each_key { |name| samples[name] = [] of Float64 }
plan_samples = [] of Float64

begin
  methods.each do |name, method|
    2.times { raise "warmup mismatch: #{name}" unless method.call == expected }
  end
  names = methods.keys
  repeats.times do |iteration|
    # Rotate and reverse traversal to spread first/last position effects. The
    # order is reproducible, not a claim of thermal or host-noise isolation.
    order = names.rotate(iteration % names.size)
    order.reverse! if iteration.odd?
    order.each do |name|
      started = Time.instant
      actual = methods[name].call
      elapsed_ms = (Time.instant - started).total_seconds * 1000
      raise "measured output mismatch: #{name}" unless actual == expected
      samples[name] << elapsed_ms
    end
    started = Time.instant
    prepared = MersenneLab::SievePlan.new(exponent, primes)
    plan_samples << (Time.instant - started).total_seconds * 1000
    raise "plan preparation mismatch" unless prepared.sieve_odd_window(1_u64, count) == expected
  end

  STDOUT.puts JSON.build { |json|
    json.object do
      json.field "exponent", exponent
      json.field "start_k", 1
      json.field "count", count
      json.field "prime_cap", cap
      json.field "prime_count", primes.size
      json.field "repeats", repeats
      json.field "warmups_per_method", 2
      json.field "proper_factor_witnesses", expected.count { |d| d != 0 }
      json.field "all_outputs_equal", true
      json.field "backend_initialization_ms", initialization_ms
      json.field "plan_preparation_ms", plan_samples
      json.field "methods" do
        json.object do
          samples.each do |name, values|
            sorted = values.sort
            json.field name do
              json.object do
                json.field "median_ms", sorted[sorted.size // 2]
                json.field "min_ms", sorted.first
                json.field "max_ms", sorted.last
                json.field "samples_ms", values
              end
            end
          end
        end
      end
      json.field "scope", "Finite small-factor witnesses only; input k array construction and backend initialization excluded. Lazy window compilation occurs in untimed warmup. Full includes validation/preparation; prepared reuses plan. Dispatched GPU calls include allocation, transfer, synchronization and readback. Checked path additionally includes CPU witness verification. Even exponent with first-ranked 3 uses a host shortcut."
    end
  }
ensure
  {% if flag?(:mpgs_metal) %}
    backend.close
  {% end %}
end
