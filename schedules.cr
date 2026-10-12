require "big"

# Crystal's standard `big` library already links GMP for BigInt. Keep the
# probable-prime binding local to the schedule experiment instead of adding a
# globally visible BigInt#prime? method.
lib LibGMP
  fun probab_prime_p = __gmpz_probab_prime_p(number : MPZ*, repetitions : Int32) : Int32
end

module MersenneLab
  module Schedules
    MAX_EXPONENT      = 127_u32
    MAX_EXECUTION_GAP =  16_u32
    GMP_REPETITIONS   =      25

    # Each count refers to work done by this schedule only. A hit is a
    # GMP-probable-prime candidate that also has exact Mersenne shape; it is
    # not a primality proof.
    struct ScheduleResult
      getter name : String
      getter candidate_count : UInt64
      getter candidate_prime_screens : UInt64
      getter exponent_prime_screens : UInt64
      getter selected_prime_exponents : Array(UInt32)
      getter mersenne_hits : Array(UInt32)
      getter wall_time : Time::Span

      def initialize(
        @name : String,
        @candidate_count : UInt64,
        @candidate_prime_screens : UInt64,
        @exponent_prime_screens : UInt64,
        @selected_prime_exponents : Array(UInt32),
        @mersenne_hits : Array(UInt32),
        @wall_time : Time::Span,
      )
      end
    end

    struct Comparison
      getter base_exponent : UInt32
      getter upper_exponent : UInt32
      getter odd_k_max : UInt64
      getter odd_k_count : UInt64
      getter odd_k_scan : ScheduleResult
      getter compatible_k_recurrence : ScheduleResult
      getter prime_exponent_selection : ScheduleResult

      def initialize(
        @base_exponent : UInt32,
        @upper_exponent : UInt32,
        @odd_k_max : UInt64,
        @odd_k_count : UInt64,
        @odd_k_scan : ScheduleResult,
        @compatible_k_recurrence : ScheduleResult,
        @prime_exponent_selection : ScheduleResult,
      )
      end
    end

    # These are formula-derived counts. In particular, no candidates from the
    # legacy odd-k range are built or screened by #analytic_counts.
    struct AnalyticCounts
      getter legacy_max_odd_k : UInt64
      getter legacy_gmp_screen_calls : UInt64
      getter compatible_k_candidates : UInt64
      getter prime_exponent_candidates : UInt64
      getter selected_prime_exponents : Array(UInt32)

      def initialize(
        @legacy_max_odd_k : UInt64,
        @legacy_gmp_screen_calls : UInt64,
        @compatible_k_candidates : UInt64,
        @prime_exponent_candidates : UInt64,
        @selected_prime_exponents : Array(UInt32),
      )
      end
    end

    # Runs three candidate schedules over one inclusive exponent ceiling.
    # The arbitrary odd-k scan stops at G_m(k) <= 2^upper_exponent - 1.
    # This Mersenne experiment admits odd base exponents only.
    def self.run_experiment(base_exponent : UInt32, upper_exponent : UInt32) : Comparison
      validate_execution_range!(base_exponent, upper_exponent)
      odd_k_max = max_odd_k(base_exponent, upper_exponent)
      odd_k_count = (odd_k_max + 1_u64) // 2_u64

      odd_scan = measure do
        hits = [] of UInt32
        k = 1_u64
        while k <= odd_k_max
          consider_candidate(base_exponent, k, upper_exponent, hits)
          k += 2_u64
        end
        ScheduleResult.new("odd-k scan", odd_k_count, odd_k_count, 0_u64,
          [] of UInt32, hits, Time::Span.zero)
      end

      compatible_scan = measure do
        compatible = build_compatible_k_sequence(base_exponent, upper_exponent)
        hits = [] of UInt32
        compatible.each do |_q, k|
          consider_candidate(base_exponent, k, upper_exponent, hits)
        end
        count = compatible.size.to_u64
        ScheduleResult.new("exact compatible-k recurrence", count, count, 0_u64,
          [] of UInt32, hits, Time::Span.zero)
      end

      prime_selection = measure do
        compatible = build_compatible_k_sequence(base_exponent, upper_exponent)
        hits = [] of UInt32
        selected = [] of UInt32
        candidate_screens = 0_u64
        exponent_screens = compatible.size.to_u64
        compatible.each do |q, k|
          next unless gmp_probable_prime?(BigInt.new(q.to_i))

          selected << q
          candidate_screens += 1_u64
          consider_candidate(base_exponent, k, upper_exponent, hits)
        end
        ScheduleResult.new("prime-exponent selection", candidate_screens,
          candidate_screens, exponent_screens, selected, hits, Time::Span.zero)
      end

      Comparison.new(base_exponent, upper_exponent, odd_k_max, odd_k_count,
        odd_scan, compatible_scan, prime_selection)
    end

    # Exact progression candidates whose value is 2^q - 1, with q in the
    # inclusive range and q > m. The recurrence k_(j+1) = 4*k_j + 1 starts at
    # k_1 = 1, so q = m + 2*j.
    def self.compatible_k_sequence(base_exponent : UInt32, upper_exponent : UInt32) : Array(Tuple(UInt32, UInt64))
      validate_execution_range!(base_exponent, upper_exponent)
      build_compatible_k_sequence(base_exponent, upper_exponent)
    end

    private def self.build_compatible_k_sequence(base_exponent : UInt32, upper_exponent : UInt32) : Array(Tuple(UInt32, UInt64))
      pairs = [] of Tuple(UInt32, UInt64)
      q = base_exponent + 2_u32
      k = 1_u64
      while q <= upper_exponent
        pairs << {q, k}
        q += 2_u32
        k = k * 4_u64 + 1_u64
      end
      pairs
    end

    # Recognizes exact Mersenne shape without floating point or logarithms.
    # Returns q only when candidate + 1 is a power of two.
    def self.mersenne_exponent(candidate : BigInt) : UInt32?
      return nil if candidate < 1

      successor = candidate + 1
      bits = successor.bit_length
      return nil unless successor == (BigInt.new(1) << (bits - 1))

      (bits - 1).to_u32
    end

    # Estimates the legacy scan size and counts the much smaller exact and
    # prime-exponent schedules. This intentionally permits a larger gap than
    # #run_experiment because it never runs the legacy scan or builds G_m(k).
    def self.analytic_counts(base_exponent : UInt32, upper_exponent : UInt32) : AnalyticCounts
      validate_analytic_range!(base_exponent, upper_exponent)
      gap = upper_exponent - base_exponent
      max_k = max_odd_k(base_exponent, upper_exponent)
      odd_calls = (max_k + 1_u64) // 2_u64
      exact_count = (gap // 2_u32).to_u64

      selected = [] of UInt32
      q = base_exponent + 2_u32
      while q <= upper_exponent
        selected << q if gmp_probable_prime?(BigInt.new(q.to_i))
        q += 2_u32
      end

      AnalyticCounts.new(max_k, odd_calls, exact_count, selected.size.to_u64, selected)
    end

    # Same GMP probable-prime test for every executed schedule. GMP's result is
    # a screening result, not a certificate; callers must preserve that label.
    def self.gmp_probable_prime?(number : BigInt) : Bool
      number > 1 && LibGMP.probab_prime_p(number.to_unsafe, GMP_REPETITIONS) > 0
    end

    private def self.validate_execution_range!(base_exponent : UInt32, upper_exponent : UInt32) : Nil
      validate_exponents!(base_exponent, upper_exponent)
      gap = upper_exponent - base_exponent
      raise ArgumentError.new("execution exponent gap must be at most #{MAX_EXECUTION_GAP}") if gap > MAX_EXECUTION_GAP
      nil
    end

    private def self.validate_analytic_range!(base_exponent : UInt32, upper_exponent : UInt32) : Nil
      validate_exponents!(base_exponent, upper_exponent)
      gap = upper_exponent - base_exponent
      # 62 is a conservative UInt64 shift limit for the analytic k bound.
      raise ArgumentError.new("analytic exponent gap must be at most 62") if gap > 62_u32
      nil
    end

    private def self.validate_exponents!(base_exponent : UInt32, upper_exponent : UInt32) : Nil
      raise ArgumentError.new("base exponent must be at least 1") if base_exponent == 0
      raise ArgumentError.new("base exponent must be odd") if base_exponent.even?
      raise ArgumentError.new("upper exponent must be at least the base exponent") if upper_exponent < base_exponent
      raise ArgumentError.new("exponents must not exceed #{MAX_EXPONENT}") if upper_exponent > MAX_EXPONENT
      nil
    end

    private def self.max_odd_k(base_exponent : UInt32, upper_exponent : UInt32) : UInt64
      gap = upper_exponent - base_exponent
      return 0_u64 if gap < 2

      bound = ((1_u64 << gap) - 1_u64) // 3_u64
      bound.even? ? bound - 1_u64 : bound
    end

    private def self.consider_candidate(base_exponent : UInt32, k : UInt64, upper_exponent : UInt32, hits : Array(UInt32)) : Nil
      candidate = (BigInt.new(1) << base_exponent.to_i) * (BigInt.new(3) * k + 1) - 1
      return unless gmp_probable_prime?(candidate)

      q = mersenne_exponent(candidate)
      return unless q
      return unless q > base_exponent && q <= upper_exponent
      return unless (q - base_exponent).even?

      hits << q unless hits.includes?(q)
      nil
    end

    private def self.measure(&block : -> ScheduleResult) : ScheduleResult
      start = Time.instant
      result = yield
      elapsed = Time.instant - start
      ScheduleResult.new(result.name, result.candidate_count, result.candidate_prime_screens,
        result.exponent_prime_screens, result.selected_prime_exponents, result.mersenne_hits, elapsed)
    end
  end
end
