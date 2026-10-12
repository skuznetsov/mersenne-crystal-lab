require "./core"

def odd_primes_through(limit : UInt32) : Array(UInt32)
  composite = Array.new(limit.to_i + 1, false)
  primes = [] of UInt32
  candidate = 3_u32

  while candidate <= limit
    unless composite[candidate.to_i]
      primes << candidate
      multiple = candidate.to_u64 * candidate.to_u64
      while multiple <= limit.to_u64
        composite[multiple.to_i] = true
        multiple += candidate.to_u64
      end
    end
    candidate += 2
  end

  primes
end

puts "MPGS modular factor prototype"
puts "A zero result means unresolved by the supplied factors, never prime."

small_primes = [3_u32, 5_u32, 7_u32, 11_u32]
small_factor = MersenneLab.sieve(2_u32, [1_u64], small_primes).first
puts "G_2(1) = 15; first proper factor from #{small_primes}: #{small_factor}"

prime_candidate = (2_u64 * (3_u64 * 13_u64 + 1_u64)) - 1_u64
prime_result = MersenneLab.sieve(1_u32, [13_u64], small_primes).first
puts "G_1(13) = #{prime_candidate}; result #{prime_result} (unresolved, not certified prime)"

exponent = 136_279_841_u32
ks = [1_u64, 5_u64, 17_u64, 25_u64, 101_u64]
trial_primes = odd_primes_through(MersenneLab::MAX_TRIAL_PRIME)
factors = MersenneLab.sieve(exponent, ks, trial_primes)
puts "G_#{exponent}(k), k in #{ks}; tried #{trial_primes.size} odd primes through #{trial_primes.last}:"
ks.each_with_index do |k, index|
  factor = factors[index]
  status = factor == 0 ? "unresolved" : "factor #{factor}"
  puts "  k=#{k}: #{status}"
end
