require "./core"

module MersenneLab
  # A validated, immutable CPU sieve plan. Residues encode the unique
  # divisibility class for each supplied factor; list order is preserved.
  class SievePlan
    MAX_WINDOW_COUNT = 16_777_216_i32

    @exponent : UInt32
    @primes : Array(UInt32)
    @roots : Array(UInt32)
    @strides : Array(UInt32)

    def initialize(exponent : UInt32, primes : Array(UInt32))
      @exponent = exponent
      @primes = primes.dup
      MersenneLab.validate_inputs!(@exponent, [] of UInt64, @primes)

      @roots = Array(UInt32).new(@primes.size)
      @strides = Array(UInt32).new(@primes.size)
      @primes.each do |prime|
        root, stride = prepare_factor(prime)
        @roots << root
        @strides << stride
      end
    end

    def exponent : UInt32
      @exponent
    end

    def prime_count : Int32
      @primes.size
    end

    # Snapshots deliberately copy their backing arrays so callers cannot
    # mutate the plan through a returned reference.
    def primes : Array(UInt32)
      @primes.dup
    end

    def roots : Array(UInt32)
      @roots.dup
    end

    def strides : Array(UInt32)
      @strides.dup
    end

    # Returns the first supplied proper factor for each candidate, or zero
    # when no prepared factor divides it. Candidate order does not affect
    # factor precedence.
    def sieve(ks : Array(UInt64)) : Array(UInt32)
      validate_candidates!(ks)
      factors = Array(UInt32).new(ks.size, 0_u32)

      ks.each_with_index do |k, candidate_index|
        @primes.each_with_index do |prime, factor_index|
          next unless candidate_exceeds_factor?(@exponent, k, prime)
          next unless residue_hit?(k, factor_index)

          factors[candidate_index] = prime
          break
        end
      end

      factors
    end

    # Returns the first matching window index per factor, or UInt32::MAX if
    # that factor has no proper hit in the requested window.
    def window_offsets(start : UInt64, count : Int32) : Array(UInt32)
      validate_window!(start, count)
      window_offsets_validated(start, count)
    end

    # Marks the arithmetic progressions in an odd-k window. Iterating factors
    # in supplied order preserves the same witness precedence as #sieve.
    def sieve_odd_window(start : UInt64, count : Int32) : Array(UInt32)
      validate_window!(start, count)
      return [] of UInt32 if count == 0
      if @exponent.even? && @primes.first? == 3_u32
        return Array(UInt32).new(count, 3_u32)
      end

      offsets = window_offsets_validated(start, count)
      factors = Array(UInt32).new(count, 0_u32)
      remaining = count

      @primes.each_with_index do |prime, factor_index|
        break if remaining == 0
        first = offsets[factor_index]
        next if first == UInt32::MAX

        index = first.to_u64
        stride = @strides[factor_index].to_u64
        while index < count.to_u64
          if factors[index.to_i] == 0
            factors[index.to_i] = prime
            remaining -= 1
          end
          index += stride
        end
      end

      factors
    end

    # Verifies witness soundness only. It does not check coverage, first-factor
    # precedence, or candidate primality; zero remains unresolved evidence.
    def verify_witnesses_odd_window!(start : UInt64, count : Int32, witnesses : Array(UInt32)) : Nil
      validate_window!(start, count)
      unless witnesses.size == count
        raise ArgumentError.new("witness count must match window count")
      end

      first_indices = Hash(UInt32, Int32).new
      @primes.each_with_index do |prime, index|
        first_indices[prime] = index unless first_indices.has_key?(prime)
      end
      factor_powers = Hash(UInt32, UInt32).new

      witnesses.each_with_index do |witness, index|
        next if witness == 0

        factor_index = first_indices[witness]?
        unless factor_index
          raise ArgumentError.new("witness #{witness} is not a supplied trial factor")
        end

        k = start + 2_u64 * index.to_u64
        unless candidate_exceeds_factor?(@exponent, k, witness)
          raise ArgumentError.new("witness #{witness} is not smaller than its candidate")
        end

        power = factor_powers[witness]?
        unless power
          power = MersenneLab.pow2_mod(@exponent, witness)
          factor_powers[witness] = power
        end
        modulus = witness.to_u64
        k_term = ((k % modulus) * 3_u64 + 1_u64) % modulus
        divides = (power.to_u64 * k_term) % modulus == 1_u64
        unless divides
          raise ArgumentError.new("witness #{witness} does not divide its candidate")
        end
      end

      nil
    end

    private def window_offsets_validated(start : UInt64, count : Int32) : Array(UInt32)
      offsets = Array(UInt32).new(@primes.size, UInt32::MAX)
      return offsets if count == 0

      count_u64 = count.to_u64
      @primes.each_with_index do |prime, factor_index|
        root = @roots[factor_index]
        next if root == prime # d=3 with odd exponent has no solution.

        stride = @strides[factor_index].to_u64
        offset = if root == prime + 1_u32 # d=3 with even exponent: every k.
                   0_u64
                 else
                   odd_window_root_offset(start, prime, root)
                 end

        while offset < count_u64 && !candidate_exceeds_factor?(@exponent, start + 2_u64 * offset, prime)
          offset += stride
        end
        offsets[factor_index] = offset.to_u32 if offset < count_u64
      end

      offsets
    end

    private def prepare_factor(prime : UInt32) : Tuple(UInt32, UInt32)
      if prime == 3
        if @exponent.even?
          return {4_u32, 1_u32} # All odd k are in the class; root sentinel d+1.
        else
          return {3_u32, 3_u32} # No odd k is in the class; root sentinel d.
        end
      end

      period = prime - 1_u32
      exponent_residue = @exponent % period
      inverse_power_exponent = if exponent_residue == 0
                                 period
                               else
                                 period - exponent_residue
                               end
      inverse_power = MersenneLab.pow2_mod(inverse_power_exponent, prime).to_u64
      modulus = prime.to_u64
      inverse_three = if prime % 3_u32 == 2
                        (modulus + 1_u64) // 3_u64
                      else
                        (2_u64 * modulus + 1_u64) // 3_u64
                      end
      root = (((inverse_power + modulus - 1_u64) % modulus) * inverse_three % modulus).to_u32
      {root, prime}
    end

    private def validate_candidates!(ks : Array(UInt64)) : Nil
      ks.each do |k|
        raise ArgumentError.new("k values must be positive") if k == 0
        raise ArgumentError.new("k values must be odd") if k.even?
      end
      nil
    end

    private def validate_window!(start : UInt64, count : Int32) : Nil
      raise ArgumentError.new("window start must be positive") if start == 0
      raise ArgumentError.new("window start must be odd") if start.even?
      raise ArgumentError.new("window count must be nonnegative") if count < 0
      if count > MAX_WINDOW_COUNT
        raise ArgumentError.new("window count exceeds #{MAX_WINDOW_COUNT}")
      end

      if count > 0
        steps = 2_u64 * (count - 1).to_u64
        if start > UInt64::MAX - steps
          raise ArgumentError.new("window endpoint overflows UInt64")
        end
      end
      nil
    end

    private def odd_window_root_offset(start : UInt64, prime : UInt32, root : UInt32) : UInt64
      modulus = prime.to_u64
      root_residue = root.to_u64
      start_residue = start % modulus
      delta = (root_residue + modulus - start_residue) % modulus
      inverse_two = (modulus + 1_u64) // 2_u64
      (delta * inverse_two) % modulus
    end

    private def residue_hit?(k : UInt64, factor_index : Int32) : Bool
      prime = @primes[factor_index]
      root = @roots[factor_index]
      return @exponent.even? if prime == 3
      (k % prime.to_u64).to_u32 == root
    end

    # The same strict candidate > factor guard used by the reference sieve.
    # For exponent >= 15 every admitted trial factor is smaller than G_m(1).
    private def candidate_exceeds_factor?(exponent : UInt32, k : UInt64, prime : UInt32) : Bool
      return true if exponent >= 15

      power_of_two = 1_u64 << exponent
      threshold = (prime.to_u64 + 1_u64) // power_of_two
      return true if threshold == 0
      k > (threshold - 1_u64) // 3_u64
    end
  end
end
