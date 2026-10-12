require "spec"
require "big"
require "../prepared_sieve"
require "../schedules"
require "../jabari_adapters"

module JabariAdaptersOracle
  def self.progression_candidate(exponent : UInt32, k : BigInt) : BigInt
    ((BigInt.new(3) * k + 1) << exponent.to_i) - 1
  end

  def self.mersenne_candidate(exponent : UInt32) : BigInt
    (BigInt.new(1) << exponent.to_i) - 1
  end

  def self.state(candidate : BigInt) : UInt8
    return 0_u8 unless trial_prime?(candidate)
    mersenne_shape?(candidate) ? 2_u8 : 1_u8
  end

  def self.trial_prime?(candidate : BigInt) : Bool
    return false if candidate < 2
    return true if candidate == 2
    return false if candidate.even?

    divisor = BigInt.new(3)
    while divisor * divisor <= candidate
      return false if candidate % divisor == 0
      divisor += 2
    end
    true
  end

  def self.mersenne_shape?(candidate : BigInt) : Bool
    return false if candidate < 1

    successor = candidate + 1
    while successor > 1
      return false if successor.odd?
      successor //= 2
    end
    true
  end

  def self.primes_through(limit : UInt32) : Array(UInt32)
    primes = [] of UInt32
    candidate = 3_u32
    while candidate <= limit
      prime = true
      divisor = 3_u32
      while divisor.to_u64 * divisor.to_u64 <= candidate.to_u64
        if candidate % divisor == 0
          prime = false
          break
        end
        divisor += 2_u32
      end
      primes << candidate if prime
      candidate += 2_u32
    end
    primes
  end
end

describe MersenneLab::JabariAdapters do
  it "matches an independent trial-division oracle for a finite progression" do
    result = MersenneLab::JabariAdapters.baseline_progression(15_u32, 1_u64, 32)
    result.states.size.should eq(32)
    result.prime_screen_count.should eq(32_u64)

    k = BigInt.new(1)
    expected = Array(UInt8).new(32) do
      candidate = JabariAdaptersOracle.progression_candidate(15_u32, k)
      k += 2
      JabariAdaptersOracle.state(candidate)
    end
    result.states.should eq(expected)
    result.states[0].should eq(2_u8) # G_15(1) = 2^17 - 1.
    result.states[2].should eq(2_u8) # G_15(5) = 2^19 - 1.
    result.states[4].should eq(1_u8) # G_15(9) is prime but is not Mersenne.
  end

  it "matches dense witnesses while screening only unresolved progression candidates" do
    exponent = 15_u32
    start = 1_u64
    count = 32
    plan = MersenneLab::SievePlan.new(exponent, JabariAdaptersOracle.primes_through(3_000_u32))
    witnesses = plan.sieve_odd_window(start, count)
    plan.verify_witnesses_odd_window!(start, count, witnesses)

    baseline = MersenneLab::JabariAdapters.baseline_progression(exponent, start, count)
    screened = MersenneLab::JabariAdapters.screen_progression(exponent, start, witnesses)
    screened.states.should eq(baseline.states)
    screened.prime_screen_count.should eq(witnesses.count(0_u32).to_u64)
    baseline.prime_screen_count.should eq(count.to_u64)

    witnesses.each_with_index do |witness, index|
      next if witness == 0
      k = start + 2_u64 * index.to_u64
      candidate = JabariAdaptersOracle.progression_candidate(exponent, k.to_big_i)
      candidate.should be > witness.to_big_i
      (candidate % witness.to_big_i).should eq(0)
      baseline.states[index].should eq(0_u8)
    end
  end

  it "preserves exact compatible Mersenne values for 32 bounded UInt64 k terms" do
    base_exponent = 15_u32
    q = 17_u32
    k = 1_u64

    32.times do |index|
      JabariAdaptersOracle.progression_candidate(base_exponent, k.to_big_i).should eq(
        JabariAdaptersOracle.mersenne_candidate(q)
      )
      if index < 31
        q += 2_u32
        k = k * 4_u64 + 1_u64
      end
    end
  end

  it "classifies direct Mersenne candidates and skips witnessed composites" do
    exponents = [17_u32, 19_u32, 21_u32, 23_u32, 25_u32, 27_u32, 29_u32, 31_u32]
    witnesses = [0_u32, 0_u32, 127_u32, 47_u32, 31_u32, 7_u32, 233_u32, 0_u32]
    baseline = MersenneLab::JabariAdapters.baseline_mersenne(17_u32, exponents.size)
    screened = MersenneLab::JabariAdapters.screen_mersenne(17_u32, witnesses)

    expected = exponents.map do |exponent|
      JabariAdaptersOracle.state(JabariAdaptersOracle.mersenne_candidate(exponent))
    end
    baseline.states.should eq(expected)
    screened.states.should eq(expected)
    baseline.states.should eq([2_u8, 2_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 2_u8])
    baseline.prime_screen_count.should eq(exponents.size.to_u64)
    screened.prime_screen_count.should eq(3_u64)

    exponents.each_with_index do |exponent, index|
      witness = witnesses[index]
      next if witness == 0
      candidate = JabariAdaptersOracle.mersenne_candidate(exponent)
      candidate.should be > witness.to_big_i
      (candidate % witness.to_big_i).should eq(0)
      baseline.states[index].should eq(0_u8)
    end
  end

  it "makes a false composite witness observable against a known Mersenne prime" do
    baseline = MersenneLab::JabariAdapters.baseline_mersenne(19_u32, 1)
    corrupted = MersenneLab::JabariAdapters.screen_mersenne(19_u32, [5_u32])

    baseline.states.should eq([2_u8]) # 2^19 - 1 = 524287 is prime.
    corrupted.states.should eq([0_u8])
    corrupted.states.should_not eq(baseline.states)
  end

  it "validates finite progression and direct-Mersenne boundaries" do
    adapter = MersenneLab::JabariAdapters

    expect_raises(ArgumentError) { adapter.baseline_progression(14_u32, 1_u64, 1) }
    expect_raises(ArgumentError) { adapter.baseline_progression(4_097_u32, 1_u64, 1) }
    expect_raises(ArgumentError) { adapter.baseline_progression(15_u32, 0_u64, 0) }
    expect_raises(ArgumentError) { adapter.baseline_progression(15_u32, 2_u64, 1) }
    expect_raises(ArgumentError) { adapter.baseline_progression(15_u32, 1_u64, -1) }
    expect_raises(ArgumentError) do
      adapter.baseline_progression(15_u32, 1_u64, MersenneLab::SievePlan::MAX_WINDOW_COUNT + 1)
    end
    expect_raises(ArgumentError) { adapter.baseline_progression(15_u32, UInt64::MAX, 2) }
    expect_raises(ArgumentError) { adapter.screen_progression(15_u32, UInt64::MAX, [0_u32, 0_u32]) }
    expect_raises(ArgumentError) { adapter.baseline_mersenne(15_u32, 1) }
    expect_raises(ArgumentError) { adapter.baseline_mersenne(18_u32, 1) }
    expect_raises(ArgumentError) { adapter.baseline_mersenne(4_097_u32, 1) }
    expect_raises(ArgumentError) { adapter.baseline_mersenne(4_095_u32, 2) }
    expect_raises(ArgumentError) { adapter.baseline_mersenne(17_u32, -1) }
    expect_raises(ArgumentError) { adapter.screen_mersenne(4_095_u32, [0_u32, 0_u32]) }
    adapter.baseline_progression(15_u32, 1_u64, 0).states.should eq([] of UInt8)
    adapter.baseline_mersenne(4_095_u32, 0).states.should eq([] of UInt8)
    adapter.screen_progression(15_u32, UInt64::MAX, [0_u32]).states.should eq(
      adapter.baseline_progression(15_u32, UInt64::MAX, 1).states
    )
  end
end
