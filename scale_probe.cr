require "json"
require "./metal_backend"

# Large-window load/performance probe. The correctness comparator is the
# already-tested prepared CPU marker, not the quadratic original reference.
raise ArgumentError.new("usage: scale_probe [count]") if ARGV.size > 1
count = (ARGV[0]? || "16777216").to_i32
raise ArgumentError.new("count must be in 1..16777216") unless 1 <= count <= MersenneLab::SievePlan::MAX_WINDOW_COUNT
exponent = 136279841_u32
cap = 65521
composite = Array(Bool).new(cap + 1, false)
primes = [] of UInt32
(3..cap).step(2) do |p|
  next if composite[p]
  primes << p.to_u32
  (p*p..cap).step(2*p) { |j| composite[j] = true } if p.to_i64 * p <= cap
end
plan = MersenneLab::SievePlan.new(exponent, primes)
expected = plan.sieve_odd_window(1_u64, count)
plan.verify_witnesses_odd_window!(1_u64, count, expected)
backend = MersenneLab::MetalSieve.new
methods = {
  "cpu_window_full"     => -> { MersenneLab::SievePlan.new(exponent, primes).sieve_odd_window(1_u64, count) },
  "cpu_window_prepared" => -> { plan.sieve_odd_window(1_u64, count) },
  "metal_window_full"   => -> { backend.sieve_odd_window(exponent, 1_u64, count, primes) },
}
[512, 1024, 4096, 16384, 65536].each do |tile|
  tile_size = tile
  methods["metal_window_prepared_tile_#{tile}"] = -> { backend.sieve_odd_window(plan, 1_u64, count, tile_size) }
end
samples = Hash(String, Array(Float64)).new
methods.each_key { |name| samples[name] = [] of Float64 }
begin
  methods.each do |name, method|
    2.times { raise "warmup mismatch: #{name}" unless method.call == expected }
  end
  names = methods.keys
  5.times do |iteration|
    order = names.rotate(iteration % names.size)
    order.reverse! if iteration.odd?
    order.each do |name|
      started = Time.instant
      actual = methods[name].call
      elapsed_ms = (Time.instant - started).total_seconds * 1000
      raise "measured mismatch: #{name}" unless actual == expected
      samples[name] << elapsed_ms
    end
  end
  STDOUT.puts JSON.build { |json|
    json.object do
      json.field "count", count
      json.field "exponent", exponent
      json.field "start_k", 1
      json.field "prime_cap", cap
      json.field "prime_count", primes.size
      json.field "repeats", 5
      json.field "warmups_per_method", 2
      json.field "proper_factor_witnesses", expected.count { |d| d != 0 }
      json.field "all_outputs_equal", true
      json.field "correctness_comparator", "Prepared CPU marker; comparator nonzero factors additionally checked with direct modular arithmetic. Not an independent coverage proof."
      json.field "methods" do
        json.object do
          samples.each do |name, values|
            json.field name do
              json.object do
                json.field "median_ms", values.sort[2]
                json.field "min_ms", values.min
                json.field "max_ms", values.max
                json.field "samples_ms", values
              end
            end
          end
        end
      end
      json.field "scope", "Large finite-window scale probe; allocation, dispatch and readback included. Backend initialization and lazy pipeline compilation excluded. One host, uncontrolled background load."
    end
  }
ensure
  backend.close
end
