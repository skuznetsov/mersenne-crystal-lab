require "./prepared_sieve"

module MersenneLab
  # A validated exponent-window sieve. Trial primes with the same odd order
  # share one divisibility progression, represented by the earliest input
  # factor for that order.
  class ExponentSievePlan
    MAX_WINDOW_COUNT = 16_777_216_i32

    # Callers validate the factor first; this keeps construction from repeating
    # primality checks or allocating a one-element validation array per factor.
    private class AdmittedOrder
      def self.compute(prime : UInt32) : UInt32
        order = prime - 1_u32
        prime_divisors(order).each do |divisor|
          while order % divisor == 0 && MersenneLab.pow2_mod(order // divisor, prime) == 1_u32
            order //= divisor
          end
        end
        order
      end

      private def self.prime_divisors(number : UInt32) : Array(UInt32)
        divisors = [] of UInt32
        remaining = number
        divisor = 2_u32
        while divisor.to_u64 * divisor.to_u64 <= remaining.to_u64
          if remaining % divisor == 0
            divisors << divisor
            while remaining % divisor == 0
              remaining //= divisor
            end
          else
            divisor = divisor == 2_u32 ? 3_u32 : divisor + 2_u32
          end
        end
        divisors << remaining if remaining > 1
        divisors
      end
    end

    @primes : Array(UInt32)
    @active_primes : Array(UInt32)
    @orders : Array(UInt32)

    def initialize(primes : Array(UInt32))
      @primes = primes.dup
      MersenneLab.validate_inputs!(1_u32, [] of UInt64, @primes)

      @active_primes = [] of UInt32
      @orders = [] of UInt32
      covered_orders = Array(Bool).new(MersenneLab::MAX_TRIAL_PRIME.to_i + 1, false)

      @primes.each do |prime|
        order = AdmittedOrder.compute(prime)
        next if order.even? || covered_orders[order.to_i]

        @active_primes << prime
        @orders << order

        covered_order = order
        odd_multiple_step = 2_u32 * order
        while covered_order <= MersenneLab::MAX_TRIAL_PRIME
          covered_orders[covered_order.to_i] = true
          covered_order += odd_multiple_step
        end
      end
    end

    def prime_count : Int32
      @primes.size
    end

    def active_count : Int32
      @active_primes.size
    end

    def primes : Array(UInt32)
      @primes.dup
    end

    def active_primes : Array(UInt32)
      @active_primes.dup
    end

    def orders : Array(UInt32)
      @orders.dup
    end

    # Computes the exact multiplicative order of 2 modulo an admitted prime.
    # Reducing the initial d-1 exponent by its prime divisors proves minimality.
    def self.order_of_two(prime : UInt32) : UInt32
      MersenneLab.validate_inputs!(1_u32, [] of UInt64, [prime])
      AdmittedOrder.compute(prime)
    end

    # Returns the first proper-hit index for each grouped order, or MAX when
    # that progression has no proper hit inside the window.
    def window_offsets(start : UInt32, count : Int32) : Array(UInt32)
      validate_window!(start, count)
      offsets = Array(UInt32).new(@orders.size, UInt32::MAX)
      return offsets if count == 0

      count_u64 = count.to_u64
      @orders.each_with_index do |order, index|
        offset = first_progression_offset(start, order)
        prime = @active_primes[index]

        while offset < count_u64 && !candidate_exceeds_factor?(window_exponent(start, offset), prime)
          offset += order.to_u64
        end
        offsets[index] = offset.to_u32 if offset < count_u64
      end

      offsets
    end

    # Returns the first proper supplied factor for every odd exponent in the
    # window. Zero means no factor from this plan resolved that candidate.
    def sieve_odd_window(start : UInt32, count : Int32) : Array(UInt32)
      offsets = window_offsets(start, count)
      factors = Array(UInt32).new(count, 0_u32)
      return factors if count == 0

      remaining = count
      @active_primes.each_with_index do |prime, factor_index|
        break if remaining == 0
        first = offsets[factor_index]
        next if first == UInt32::MAX

        index = first.to_u64
        stride = @orders[factor_index].to_u64
        while index < count.to_u64
          candidate_index = index.to_i
          if factors[candidate_index] == 0
            factors[candidate_index] = prime
            remaining -= 1
          end
          index += stride
        end
      end

      factors
    end

    # Checks witness membership, properness, and direct modular divisibility.
    # It deliberately does not check coverage or factor precedence; zero stays
    # unresolved evidence.
    def verify_witnesses_odd_window!(start : UInt32, count : Int32, witnesses : Array(UInt32)) : Nil
      validate_window!(start, count)
      unless witnesses.size == count
        raise ArgumentError.new("witness count must match window count")
      end

      supplied = Hash(UInt32, Bool).new
      @primes.each { |prime| supplied[prime] = true }

      witnesses.each_with_index do |witness, index|
        next if witness == 0
        unless supplied.has_key?(witness)
          raise ArgumentError.new("witness #{witness} is not a supplied trial factor")
        end

        exponent = window_exponent(start, index.to_u64)
        unless candidate_exceeds_factor?(exponent, witness)
          raise ArgumentError.new("witness #{witness} is not smaller than its candidate")
        end
        unless MersenneLab.pow2_mod(exponent, witness) == 1_u32
          raise ArgumentError.new("witness #{witness} does not divide its candidate")
        end
      end

      nil
    end

    private def validate_window!(start : UInt32, count : Int32) : Nil
      raise ArgumentError.new("window start must be positive") if start == 0
      raise ArgumentError.new("window start must be odd") if start.even?
      raise ArgumentError.new("window count must be nonnegative") if count < 0
      if count > MAX_WINDOW_COUNT
        raise ArgumentError.new("window count exceeds #{MAX_WINDOW_COUNT}")
      end

      if count > 0
        last_exponent = start.to_u64 + 2_u64 * (count - 1).to_u64
        if last_exponent > UInt32::MAX.to_u64
          raise ArgumentError.new("window endpoint overflows UInt32")
        end
      end
      nil
    end

    private def first_progression_offset(start : UInt32, order : UInt32) : UInt64
      modulus = order.to_u64
      start_residue = start.to_u64 % modulus
      delta = (modulus - start_residue) % modulus
      inverse_two = (modulus + 1_u64) // 2_u64
      (delta * inverse_two) % modulus
    end

    private def window_exponent(start : UInt32, index : UInt64) : UInt32
      (start.to_u64 + 2_u64 * index).to_u32
    end

    # For exponents >= 16, M_q is at least 65,535, above every admitted prime.
    private def candidate_exceeds_factor?(exponent : UInt32, prime : UInt32) : Bool
      return true if exponent >= 16

      ((1_u64 << exponent) - 1_u64) > prime.to_u64
    end
  end
end
