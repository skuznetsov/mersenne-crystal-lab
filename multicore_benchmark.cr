require "json"
require "./parallel_mersenne"
require "./metal_backend"

def multicore_primes(cap : Int32) : Array(UInt32)
  composite = Array(Bool).new(cap + 1, false)
  primes = [] of UInt32
  (3..cap).step(2) do |p|
    next if composite[p]
    primes << p.to_u32
    (p*p..cap).step(2*p) { |j| composite[j] = true } if p.to_i64 * p <= cap
  end
  primes
end

def multicore_cpu_method(pool, primes, start, count)
  -> {
    factors = MersenneLab::ExponentSievePlan.new(primes).sieve_odd_window(start, count)
    pool.screen_mersenne(start, factors)
  }
end

def multicore_metal_method(pool, backend, primes, start, count, tile)
  -> {
    factors = backend.sieve_exponents(start, count, primes, tile)
    pool.screen_mersenne(start, factors)
  }
end

def multicore_baseline_method(pool, start, count)
  -> { pool.baseline_mersenne(start, count) }
end

raise ArgumentError.new("usage: multicore_benchmark [count [start [repeats [workers_csv [tile [chunk]]]]]]") unless ARGV.size <= 6
count = (ARGV[0]? || "1024").to_i32
start = (ARGV[1]? || "17").to_u32
repeats = (ARGV[2]? || "5").to_i32
workers = (ARGV[3]? || "1,2,4,8,12").split(',').map(&.to_i32)
tile = (ARGV[4]? || "4096").to_i32
chunk = (ARGV[5]? || "1").to_i32
raise ArgumentError.new("count must be positive") if count <= 0
raise ArgumentError.new("repeats must be odd in 3..9") unless repeats.odd? && 3 <= repeats <= 9
raise ArgumentError.new("workers must be distinct values in 1..64") unless !workers.empty? && workers.uniq == workers && workers.all? { |w| 1 <= w <= 64 }
raise ArgumentError.new("tile must be in 1..65536") unless 1 <= tile <= 65536
raise ArgumentError.new("chunk must be in 1..4096") unless 1 <= chunk <= 4096

# Validation, correctness oracle and backend creation precede all timed calls.
expected = MersenneLab::JabariAdapters.baseline_mersenne(start, count)
primes = multicore_primes(65521)
plan = MersenneLab::ExponentSievePlan.new(primes)
factors = plan.sieve_odd_window(start, count)
survivors = factors.count(0_u32).to_u64
serial_filtered = MersenneLab::JabariAdapters.screen_mersenne(start, factors)
raise "serial factor classification mismatch" unless serial_filtered.states == expected.states && serial_filtered.prime_screen_count == survivors
started = Time.instant
backend = MersenneLab::MetalSieve.new
backend_init_ms = (Time.instant - started).total_seconds * 1000
pools = [] of MersenneLab::ParallelMersenne
pool_init_ms = Hash(Int32, Float64).new
methods = Hash(String, Proc(MersenneLab::JabariAdapters::Result)).new
expected_calls = Hash(String, UInt64).new
samples = Hash(String, Array(Float64)).new
warmup_samples = Hash(String, Array(Float64)).new
hits = [] of UInt32
expected.states.each_with_index { |state, i| hits << start + 2_u32 * i.to_u32 if state == MersenneLab::JabariAdapters::PROBABLE_PRIME_MERSENNE }

begin
  started = Time.instant
  gpu_factors = backend.sieve_exponents(plan, start, count, tile)
  first_gpu_ms = (Time.instant - started).total_seconds * 1000
  raise "GPU factor mismatch" unless gpu_factors == factors

  methods["post5_serial_shared_gmp"] = -> { MersenneLab::JabariAdapters.baseline_mersenne(start, count) }
  expected_calls["post5_serial_shared_gmp"] = count.to_u64
  methods["cpu_serial_full"] = -> { MersenneLab::JabariAdapters.screen_mersenne(start, MersenneLab::ExponentSievePlan.new(primes).sieve_odd_window(start, count)) }
  expected_calls["cpu_serial_full"] = survivors
  methods["metal_serial_full"] = -> { MersenneLab::JabariAdapters.screen_mersenne(start, backend.sieve_exponents(start, count, primes, tile)) }
  expected_calls["metal_serial_full"] = survivors

  workers.each do |worker_count|
    started = Time.instant
    pool = MersenneLab::ParallelMersenne.new(worker_count, chunk)
    pool_init_ms[worker_count] = (Time.instant - started).total_seconds * 1000
    pools << pool
    cpu_name = "cpu_parallel_#{worker_count}_full"
    methods[cpu_name] = multicore_cpu_method(pool, primes, start, count)
    expected_calls[cpu_name] = survivors
    # A parallelized post-5 schedule is a required same-resource baseline.
    baseline_name = "post5_parallel_#{worker_count}_shared_gmp"
    methods[baseline_name] = multicore_baseline_method(pool, start, count)
    expected_calls[baseline_name] = count.to_u64
    if worker_count == workers.max
      metal_name = "metal_parallel_#{worker_count}_full"
      methods[metal_name] = multicore_metal_method(pool, backend, primes, start, count, tile)
      expected_calls[metal_name] = survivors
    end
  end

  verify = ->(name : String, result : MersenneLab::JabariAdapters::Result) {
    raise "final classification mismatch: #{name}" unless result.states == expected.states
    raise "GMP call count mismatch: #{name}" unless result.prime_screen_count == expected_calls[name]
  }
  methods.each do |name, method|
    samples[name] = [] of Float64
    warmup_samples[name] = [] of Float64
    2.times do
      started = Time.instant
      result = method.call
      warmup_samples[name] << (Time.instant - started).total_seconds * 1000
      verify.call(name, result)
    end
  end
  names = methods.keys
  repeats.times do |iteration|
    order = names.rotate(iteration % names.size)
    order.reverse! if iteration.odd?
    order.each do |name|
      started = Time.instant
      result = methods[name].call
      samples[name] << (Time.instant - started).total_seconds * 1000
      verify.call(name, result)
    end
  end

  puts JSON.build { |json|
    json.object do
      json.field "count", count
      json.field "start_q", start
      json.field "last_q", start.to_u64 + 2_u64 * (count - 1).to_u64
      json.field "worker_counts", workers
      json.field "chunk_size", chunk
      json.field "tile_size", tile
      json.field "repeats", repeats
      json.field "warmups_per_method", 2
      json.field "prime_count", primes.size
      json.field "active_order_count", plan.active_count
      json.field "unresolved", survivors
      json.field "probable_mersenne_exponents", hits
      json.field "gmp_repetitions", MersenneLab::Schedules::GMP_REPETITIONS
      json.field "backend_initialization_ms", backend_init_ms
      json.field "first_gpu_call_including_kernel_compile_ms", first_gpu_ms
      json.field "pool_initialization_ms", pool_init_ms
      json.field "all_final_states_and_work_counts_equal", true
      json.field "methods" do
        json.object do
          samples.each do |name, times|
            json.field name do
              json.object do
                json.field "median_ms", times.sort[times.size // 2]
                json.field "min_ms", times.min
                json.field "max_ms", times.max
                json.field "samples_ms", times
                json.field "warmup_samples_ms", warmup_samples[name]
                json.field "gmp_screen_calls", expected_calls[name]
              end
            end
          end
        end
      end
      json.field "scope", "Same odd q and GMP(25). Full CPU/Metal paths include factor-plan preparation, sieving, task preparation, allocation, candidate construction, scheduling, synchronization and GMP screening. Pool/backend initialization, kernel compilation, equality checks and output excluded and first-call costs separately recorded. Parallel post-5 paths use the same worker pools. No original primes-utils or billion full-test claim."
    end
  }
ensure
  pools.each(&.close)
  backend.close
end
