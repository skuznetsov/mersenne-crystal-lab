require "./core"
require "./prepared_sieve"

{% if flag?(:mpgs_metal) %}
  require "./metal_backend"
{% elsif flag?(:mpgs_cuda) %}
  require "./cuda_backend"
{% else %}
  {% raise "Select exactly one GPU backend: -Dmpgs_metal or -Dmpgs_cuda" %}
{% end %}
{% if flag?(:mpgs_metal) && flag?(:mpgs_cuda) %}
  {% raise "Select exactly one GPU backend" %}
{% end %}

raise ArgumentError.new("usage: gpu_demo [exponent [count]]") if ARGV.size > 2
seed = (ARGV[0]? || "136279841").to_u32
raise ArgumentError.new("GPU demo requires exponent >= 15") if seed < 15
count = (ARGV[1]? || "4096").to_i32
raise ArgumentError.new("count must be in 1..262144") unless 1 <= count <= 262144
primes = [3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61,
          67, 71, 73, 79, 83, 89, 97].map(&.to_u32)

backend = {% if flag?(:mpgs_metal) %}
            MersenneLab::MetalSieve.new
          {% else %}
            MersenneLab::CUDASieve.new
          {% end %}

begin
  # Positive controls and high-k boundaries keep an all-zero/broken kernel
  # from looking successful. CPU core has separate BigInt reference specs.
  control_ks = [1_u64, 3_u64, 5_u64, 21_u64, 85_u64, 357913941_u64,
                UInt64::MAX - 2, UInt64::MAX]
  [15_u32, 31_u32, 32_u32, 33_u32, 61_u32, 1279_u32, 136279841_u32].each do |m|
    expected = MersenneLab.sieve(m, control_ks, primes)
    actual = backend.sieve(m, control_ks, primes)
    raise "GPU/CPU control mismatch at seed #{m}" unless actual == expected
  end
  # Exercise the largest admitted trial prime without smaller factors masking it.
  boundary_primes = [65521_u32]
  boundary_expected = MersenneLab.sieve(32_u32, control_ks, boundary_primes)
  raise "GPU/CPU large-factor mismatch" unless backend.sieve(32_u32, control_ks, boundary_primes) == boundary_expected
  raise "large-factor positive control wrong" unless backend.sieve(32_u32, [26111_u64], boundary_primes) == [65521_u32]
  raise "positive-control CPU result wrong" unless MersenneLab.sieve(32_u32, [1_u64], [3_u32]) == [3_u32]
  raise "positive-control GPU result wrong" unless backend.sieve(32_u32, [1_u64], [3_u32]) == [3_u32]
  begin
    backend.sieve(14_u32, [1_u64], primes)
    raise "GPU accepted a seed below the proper-factor guard"
  rescue ArgumentError
    # The bounded GPU implementation requires m >= 15.
  end
  raise "empty-input result wrong" unless backend.sieve(seed, [] of UInt64, primes).empty?
  raise "empty-factor result wrong" unless backend.sieve(seed, [1_u64], [] of UInt32) == [0_u32]
  puts "control_batches_match_cpu=true"

  ks = Array(UInt64).new(count) { |i| i.to_u64 * 2 + 1 }
  started = Time.instant
  expected = MersenneLab.sieve(seed, ks, primes)
  cpu_seconds = (Time.instant - started).total_seconds
  started = Time.instant
  actual = backend.sieve(seed, ks, primes)
  gpu_wall_seconds = (Time.instant - started).total_seconds
  raise "GPU/CPU batch mismatch" unless actual == expected

  rejected = actual.count { |d| d != 0 }
  puts "backend=#{backend.class}"
  puts "seed=#{seed} candidates=#{count} trial_primes=#{primes.size}"
  puts "proper_factor_witnesses=#{rejected} unresolved=#{count - rejected}"
  puts "batch_matches_cpu=true"
  {% if flag?(:mpgs_metal) %}
    raise "Metal dense batch mismatch" unless backend.sieve_odd_window(seed, 1_u64, count, primes) == expected
    puts "dense_window_matches_cpu=true"
  {% end %}
  puts "cpu_wall_seconds=#{cpu_seconds}"
  puts "gpu_sieve_wall_seconds=#{gpu_wall_seconds}"
  puts "GPU wall time includes validation, residue preparation, allocation, transfer, dispatch, synchronization, and readback."
  puts "One batch is a correctness demonstration, not a performance conclusion. Unresolved candidates are not certified primes."
  shown = 0
  actual.each_with_index do |d, i|
    next if d == 0
    puts "witness: seed=#{seed} k=#{ks[i]} proper_divisor=#{d}"
    shown += 1
    break if shown == 5
  end
ensure
  backend.close
end
