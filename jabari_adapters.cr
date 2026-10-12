require "big"
require "./prepared_sieve"
require "./schedules"

module MersenneLab
  # Finite normalized versions of the two CPU loops attributed to Jabari.
  # They preserve the candidate formulas and use the lab's shared GMP
  # probable-prime backend; they do not execute the original primes-utils
  # implementation.
  module JabariAdapters
    MAX_PROGRESSION_EXPONENT = 4_096_u32
    MAX_MERSENNE_EXPONENT    = 4_095_u32

    COMPOSITE                   = 0_u8
    PROBABLE_PRIME_NON_MERSENNE = 1_u8
    PROBABLE_PRIME_MERSENNE     = 2_u8

    struct Result
      getter states : Array(UInt8)
      getter prime_screen_count : UInt64

      def initialize(@states : Array(UInt8), @prime_screen_count : UInt64)
      end
    end

    # Matches the paper's k += 2 loop over one checked odd-k window. Every
    # candidate receives one GMP probable-prime screen before the original
    # all-one-bit Mersenne check is applied.
    def self.baseline_progression(exponent : UInt32, start : UInt64, count : Int32) : Result
      validate_progression_window!(exponent, start, count)
      states = Array(UInt8).new(count, COMPOSITE)
      k = start.to_big_i
      three = BigInt.new(3)
      one = BigInt.new(1)
      prime_screens = 0_u64

      count.times do |index|
        candidate = ((three * k + one) << exponent.to_i) - 1
        prime_screens += 1_u64
        if Schedules.gmp_probable_prime?(candidate)
          states[index] = all_one_bits?(candidate) ? PROBABLE_PRIME_MERSENNE : PROBABLE_PRIME_NON_MERSENNE
        end
        k += 2
      end

      Result.new(states, prime_screens)
    end

    # A nonzero witness means an upstream sieve already established a proper
    # divisor for that aligned candidate; only zero entries receive GMP work.
    def self.screen_progression(exponent : UInt32, start : UInt64, witnesses : Array(UInt32)) : Result
      count = witnesses.size
      validate_progression_window!(exponent, start, count)
      states = Array(UInt8).new(count, COMPOSITE)
      three = BigInt.new(3)
      one = BigInt.new(1)
      prime_screens = 0_u64

      witnesses.each_with_index do |witness, index|
        if witness == 0
          # The checked endpoint bounds this UInt64 index expression. Avoid
          # allocating a BigInt k for candidates the sieve already rejected.
          k = start + 2_u64 * index.to_u64
          candidate = ((three * k.to_big_i + one) << exponent.to_i) - 1
          prime_screens += 1_u64
          if Schedules.gmp_probable_prime?(candidate)
            states[index] = all_one_bits?(candidate) ? PROBABLE_PRIME_MERSENNE : PROBABLE_PRIME_NON_MERSENNE
          end
        end
      end

      Result.new(states, prime_screens)
    end

    # Screens a finite sequence of odd Mersenne exponents q, starting at q.
    # Each candidate is exactly 2^q - 1 and receives one GMP probable-prime
    # call, matching the updated forum loop's candidate work after freezing
    # its seed and removing its unbounded control flow and output.
    def self.baseline_mersenne(start_exponent : UInt32, count : Int32) : Result
      validate_mersenne_window!(start_exponent, count)
      states = Array(UInt8).new(count, COMPOSITE)
      q = start_exponent.to_u64
      prime_screens = 0_u64

      count.times do |index|
        candidate = (BigInt.new(1) << q.to_i) - 1
        prime_screens += 1_u64
        if Schedules.gmp_probable_prime?(candidate)
          states[index] = PROBABLE_PRIME_MERSENNE
        end
        q += 2_u64
      end

      Result.new(states, prime_screens)
    end

    # Preserves the direct-Mersenne candidate sequence while skipping entries
    # that already have a known proper-divisor witness.
    def self.screen_mersenne(start_exponent : UInt32, witnesses : Array(UInt32)) : Result
      count = witnesses.size
      validate_mersenne_window!(start_exponent, count)
      states = Array(UInt8).new(count, COMPOSITE)
      q = start_exponent.to_u64
      prime_screens = 0_u64

      witnesses.each_with_index do |witness, index|
        if witness == 0
          candidate = (BigInt.new(1) << q.to_i) - 1
          prime_screens += 1_u64
          if Schedules.gmp_probable_prime?(candidate)
            states[index] = PROBABLE_PRIME_MERSENNE
          end
        end
        q += 2_u64
      end

      Result.new(states, prime_screens)
    end

    private def self.all_one_bits?(candidate : BigInt) : Bool
      value = candidate
      loop do
        value >>= 1
        return true if value <= 0
        return false if value.even?
      end
    end

    private def self.validate_progression_window!(exponent : UInt32, start : UInt64, count : Int32) : Nil
      if exponent < 15_u32 || exponent > MAX_PROGRESSION_EXPONENT
        raise ArgumentError.new("progression exponent must be from 15 through #{MAX_PROGRESSION_EXPONENT}")
      end
      validate_count!(count)
      raise ArgumentError.new("window start must be positive") if start == 0
      raise ArgumentError.new("window start must be odd") if start.even?

      if count > 0
        steps = 2_u64 * (count - 1).to_u64
        if start > UInt64::MAX - steps
          raise ArgumentError.new("window endpoint overflows UInt64")
        end
      end
      nil
    end

    private def self.validate_mersenne_window!(start_exponent : UInt32, count : Int32) : Nil
      if start_exponent < 17_u32 || start_exponent > MAX_MERSENNE_EXPONENT || start_exponent.even?
        raise ArgumentError.new("Mersenne start exponent must be odd and from 17 through #{MAX_MERSENNE_EXPONENT}")
      end
      validate_count!(count)

      if count > 0
        last_exponent = start_exponent.to_u64 + 2_u64 * (count - 1).to_u64
        if last_exponent > MAX_MERSENNE_EXPONENT.to_u64
          raise ArgumentError.new("Mersenne window exceeds exponent #{MAX_MERSENNE_EXPONENT}")
        end
      end
      nil
    end

    private def self.validate_count!(count : Int32) : Nil
      raise ArgumentError.new("window count must be nonnegative") if count < 0
      if count > SievePlan::MAX_WINDOW_COUNT
        raise ArgumentError.new("window count exceeds #{SievePlan::MAX_WINDOW_COUNT}")
      end
      nil
    end
  end
end
