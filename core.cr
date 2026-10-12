module MersenneLab
  # Trial factors are deliberately bounded. With d <= 65,535, the product of
  # two reduced residues is smaller than 2^32, which also fits GPU UInt32 math.
  MAX_TRIAL_PRIME = 65_535_u32

  # Validates the shared CPU/GPU input contract. An empty candidate or prime
  # list is allowed; it yields no factor evidence.
  def self.validate_inputs!(exponent : UInt32, ks : Array(UInt64), primes : Array(UInt32)) : Nil
    raise ArgumentError.new("exponent must be at least 1") if exponent == 0

    ks.each do |k|
      raise ArgumentError.new("k values must be positive") if k == 0
      raise ArgumentError.new("k values must be odd") if k.even?
    end

    primes.each do |prime|
      if prime < 3 || prime > MAX_TRIAL_PRIME || prime.even?
        raise ArgumentError.new("trial factors must be odd primes from 3 through #{MAX_TRIAL_PRIME}")
      end
      raise ArgumentError.new("trial factor #{prime} is composite") unless prime32?(prime)
    end
    nil
  end

  # Returns 2^exponent modulo d using repeated squaring. d may be any positive
  # UInt32 modulus; the sieve separately requires genuine odd prime factors.
  def self.pow2_mod(exponent : UInt32, d : UInt32) : UInt32
    raise ArgumentError.new("modulus must be positive") if d == 0

    modulus = d.to_u64
    power = exponent.to_u64
    base = 2_u64 % modulus
    result = 1_u64 % modulus

    while power > 0
      result = (result * base) % modulus if power.odd?
      power >>= 1
      base = (base * base) % modulus
    end

    result.to_u32
  end

  # Computes G_m(k) mod d without constructing the exponentially large value.
  # The caller may use any positive modulus here; factor APIs validate primes.
  def self.residue(exponent : UInt32, k : UInt64, d : UInt32) : UInt32
    raise ArgumentError.new("modulus must be positive") if d == 0

    modulus = d.to_u64
    power = pow2_mod(exponent, d).to_u64
    k_term = ((k % modulus) * 3_u64 + 1_u64) % modulus
    product = (power * k_term) % modulus
    ((product + modulus - 1_u64) % modulus).to_u32
  end

  # True only when d is a supplied-domain prime, divides G_m(k), and is
  # strictly smaller than the candidate. A candidate equal to d is not a
  # proper factor (for example, G_1(1) = 7 and G_3(1) = 31).
  def self.proper_factor?(exponent : UInt32, k : UInt64, d : UInt32) : Bool
    validate_inputs!(exponent, [k], [d])
    proper_factor_with_power?(exponent, k, d, pow2_mod(exponent, d))
  end

  # Returns the first proper factor from the supplied list for each k, or 0
  # when none of those factors divides the candidate. Zero means unresolved,
  # never “prime.” Prime-list ordering determines which factor is returned.
  def self.sieve(exponent : UInt32, ks : Array(UInt64), primes : Array(UInt32)) : Array(UInt32)
    validate_inputs!(exponent, ks, primes)
    factors = Array.new(ks.size, 0_u32)

    primes.each do |d|
      power = pow2_mod(exponent, d)
      ks.each_with_index do |k, index|
        next unless factors[index] == 0
        if proper_factor_with_power?(exponent, k, d, power)
          factors[index] = d
        end
      end
    end

    factors
  end

  private def self.proper_factor_with_power?(exponent : UInt32, k : UInt64, d : UInt32, power : UInt32) : Bool
    return false unless candidate_exceeds_factor?(exponent, k, d)

    modulus = d.to_u64
    k_term = ((k % modulus) * 3_u64 + 1_u64) % modulus
    product = (power.to_u64 * k_term) % modulus
    (product + modulus - 1_u64) % modulus == 0
  end

  # Compare 2^m(3k+1)-1 with d without overflowing UInt64 or building G_m(k).
  # For m >= 15, k >= 1 implies G_m(k) >= 4*2^15-1 > MAX_TRIAL_PRIME.
  private def self.candidate_exceeds_factor?(exponent : UInt32, k : UInt64, d : UInt32) : Bool
    return true if exponent >= 15

    power_of_two = 1_u64 << exponent
    threshold = (d.to_u64 + 1_u64) // power_of_two
    return true if threshold == 0

    # 3k + 1 > threshold, expressed without multiplying a potentially huge k.
    k > (threshold - 1_u64) // 3_u64
  end

  private def self.prime32?(number : UInt32) : Bool
    return false if number < 2
    return number == 2 if number.even?

    divisor = 3_u32
    while divisor.to_u64 * divisor.to_u64 <= number.to_u64
      return false if number % divisor == 0
      divisor += 2
    end
    true
  end
end
