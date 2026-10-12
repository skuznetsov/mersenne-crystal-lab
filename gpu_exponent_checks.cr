require "big"
require "./metal_backend"

# This oracle does not use the production order or modular-power routines.
# Bounded exponents construct M_q exactly; larger ones use a separate binary
# exponentiation modulo each supplied prime without constructing giant M_q.
def exponent_oracle(start : UInt32, count : Int32, primes : Array(UInt32)) : Array(UInt32)
  Array(UInt32).new(count) do |index|
    q = (start.to_u64 + 2_u64 * index.to_u64).to_u32
    candidate = q <= 4095 ? (BigInt.new(1) << q.to_i) - 1 : nil
    primes.find do |prime|
      if value = candidate
        value > prime.to_big_i && value % prime.to_big_i == 0
      else
        power = q
        base = 2_u64
        residue = 1_u64
        modulus = prime.to_u64
        while power != 0
          residue = residue * base % modulus if power.odd?
          base = base * base % modulus
          power >>= 1
        end
        residue == 1_u64
      end
    end || 0_u32
  end
end

def check_exponents(backend, start, count, primes, tile)
  expected = exponent_oracle(start, count, primes)
  plan = MersenneLab::ExponentSievePlan.new(primes)
  raise "CPU exponent mismatch" unless plan.sieve_odd_window(start, count) == expected
  actual = backend.sieve_exponents(plan, start, count, tile)
  raise "Metal exponent mismatch start=#{start} count=#{count} tile=#{tile}" unless actual == expected
  plan.verify_witnesses_odd_window!(start, count, actual)
end

def trial_primes(cap : Int32) : Array(UInt32)
  composite = Array(Bool).new(cap + 1, false)
  primes = [] of UInt32
  (3..cap).step(2) do |p|
    next if composite[p]
    primes << p.to_u32
    (p*p..cap).step(2*p) { |j| composite[j] = true } if p.to_i64 * p <= cap
  end
  primes
end

backend = MersenneLab::MetalSieve.new
begin
  cases = 0
  factors = [89_u32, 7_u32, 23_u32, 73_u32, 151_u32, 31_u32, 8191_u32, 65521_u32, 3_u32, 5_u32, 89_u32]
  [1, 2, 31, 32, 33, 127, 129, 1024, 1025, 4097].each do |count|
    [17_u32, 136279841_u32, UInt32::MAX - 2_u32 * (count - 1).to_u32].each do |start|
      [factors, factors.reverse, [3_u32, 5_u32], [] of UInt32].each do |primes|
        [1, 127, 1024, 4096, 65536].each do |tile|
          check_exponents(backend, start, count, primes, tile)
          cases += 1
        end
      end
    end
  end
  # The minimum original input rank must win across different order groups.
  check_exponents(backend, 33_u32, 1, [89_u32, 7_u32, 23_u32], 1)
  raise "precedence control failed" unless backend.sieve_exponents(33_u32, 1, [89_u32, 7_u32, 23_u32]) == [89_u32]
  [1024, 4096, 65536].each do |tile|
    check_exponents(backend, 17_u32, 1024, trial_primes(65521), tile)
    cases += 1
  end
  plan = MersenneLab::ExponentSievePlan.new(factors)
  raise "empty endpoint mismatch" unless backend.sieve_exponents(plan, UInt32::MAX, 0).empty?
  # Deduplication means repeated copies cannot overflow the order/tile grid;
  # use the complete set of genuine primes for this negative control.
  grid_plan = MersenneLab::ExponentSievePlan.new(trial_primes(65521))
  invalid_cases = [
    -> { backend.sieve_exponents(plan, UInt32::MAX, 2) },
    -> { backend.sieve_exponents(plan, UInt32::MAX - 2_u32, 3) },
    -> { backend.sieve_exponents(plan, 0_u32, 0) },
    -> { backend.sieve_exponents(plan, 15_u32, 1) },
    -> { backend.sieve_exponents(plan, 18_u32, 0) },
    -> { backend.sieve_exponents(plan, 17_u32, -1) },
    -> { backend.sieve_exponents(plan, 17_u32, 1, 0) },
    -> { backend.sieve_exponents(plan, 17_u32, 1, 65537) },
    -> { backend.sieve_exponents(plan, 17_u32, MersenneLab::ExponentSievePlan::MAX_WINDOW_COUNT + 1) },
    -> { backend.sieve_exponents(grid_plan, 17_u32, MersenneLab::ExponentSievePlan::MAX_WINDOW_COUNT, 1) },
    -> { backend.sieve_exponents(17_u32, 1, [9_u32]) },
  ]
  invalid_cases.each do |invalid|
    begin
      invalid.call
    rescue ArgumentError
      next
    end
    raise "invalid exponent window was accepted"
  end
  other = MersenneLab::MetalSieve.new
  begin
    3.times do
      check_exponents(other, UInt32::MAX - 256_u32, 129, factors, 127)
      check_exponents(backend, 33_u32, 129, factors.reverse, 4096)
      cases += 2
    end
  ensure
    other.close
  end
  backend.close
  backend.close
  [-> { backend.sieve_exponents(plan, 17_u32, 1) },
   -> { backend.sieve_exponents(17_u32, 0, [] of UInt32) }].each do |closed_call|
    begin
      closed_call.call
    rescue error
      raise error unless error.message == "Metal sieve is closed"
      next
    end
    raise "closed Metal backend was accepted"
  end
  puts "metal_exponent_cases=#{cases + 2} independent_outputs_equal=true invalid_cases_rejected=#{invalid_cases.size} closed_state_checked=true"
ensure
  backend.close
end
