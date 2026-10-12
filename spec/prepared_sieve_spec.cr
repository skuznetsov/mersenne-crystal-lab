require "spec"
require "big"
require "../prepared_sieve"

module PreparedSieveOracle
  def self.candidate(exponent : UInt32, k : UInt64) : BigInt
    (BigInt.new(1) << exponent) * (BigInt.new(3) * k.to_big_i + 1) - 1
  end

  def self.first_factor(exponent : UInt32, k : UInt64, primes : Array(UInt32)) : UInt32
    value = candidate(exponent, k)
    primes.each do |prime|
      return prime if value > prime.to_big_i && value % prime.to_big_i == 0
    end
    0_u32
  end

  def self.offset(exponent : UInt32, start : UInt64, count : Int32, prime : UInt32) : UInt32
    count.times do |index|
      k = start + 2_u64 * index.to_u64
      value = candidate(exponent, k)
      return index.to_u32 if value > prime.to_big_i && value % prime.to_big_i == 0
    end
    UInt32::MAX
  end
end

describe MersenneLab::SievePlan do
  it "copies and validates its factor list and returns isolated snapshots" do
    factors = [5_u32, 3_u32, 5_u32]
    plan = MersenneLab::SievePlan.new(2_u32, factors)
    factors[0] = 7_u32

    plan.primes.should eq([5_u32, 3_u32, 5_u32])
    plan.prime_count.should eq(3)
    plan.exponent.should eq(2_u32)

    prime_snapshot = plan.primes
    root_snapshot = plan.roots
    stride_snapshot = plan.strides
    prime_snapshot[0] = 7_u32
    root_snapshot[0] = 7_u32
    stride_snapshot[0] = 7_u32

    plan.primes.should eq([5_u32, 3_u32, 5_u32])
    plan.roots.should_not eq(root_snapshot)
    plan.strides.should_not eq(stride_snapshot)
    plan.sieve([1_u64]).should eq([5_u32])
  end

  it "rejects invalid exponent and trial factors during preparation" do
    expect_raises(ArgumentError) { MersenneLab::SievePlan.new(0_u32, [] of UInt32) }
    expect_raises(ArgumentError) { MersenneLab::SievePlan.new(2_u32, [0_u32]) }
    expect_raises(ArgumentError) { MersenneLab::SievePlan.new(2_u32, [2_u32]) }
    expect_raises(ArgumentError) { MersenneLab::SievePlan.new(2_u32, [9_u32]) }
    expect_raises(ArgumentError) { MersenneLab::SievePlan.new(2_u32, [65_537_u32]) }
  end

  it "validates arbitrary candidate boundaries and supports empty inputs" do
    plan = MersenneLab::SievePlan.new(2_u32, [3_u32])
    plan.sieve([] of UInt64).should eq([] of UInt32)
    expect_raises(ArgumentError) { plan.sieve([0_u64]) }
    expect_raises(ArgumentError) { plan.sieve([2_u64]) }

    empty = MersenneLab::SievePlan.new(1_u32, [] of UInt32)
    empty.prime_count.should eq(0)
    empty.primes.should eq([] of UInt32)
    empty.roots.should eq([] of UInt32)
    empty.strides.should eq([] of UInt32)
    empty.sieve([1_u64, 3_u64]).should eq([0_u32, 0_u32])
    empty.sieve_odd_window(1_u64, 3).should eq([0_u32, 0_u32, 0_u32])
  end

  it "matches an independent BigInt oracle over small odd windows and preserves factor order" do
    factors = [5_u32, 3_u32, 7_u32, 11_u32, 5_u32, 13_u32, 3_u32]
    (1_u32..10_u32).each do |exponent|
      [1_u64, 3_u64, 9_u64].each do |start|
        count = 40
        plan = MersenneLab::SievePlan.new(exponent, factors)
        ks = Array(UInt64).new(count) { |index| start + 2_u64 * index.to_u64 }
        expected = ks.map { |k| PreparedSieveOracle.first_factor(exponent, k, factors) }

        plan.sieve(ks).should eq(expected)
        plan.sieve(ks).should eq(MersenneLab.sieve(exponent, ks, factors))
        plan.sieve_odd_window(start, count).should eq(expected)

        offsets = plan.window_offsets(start, count)
        offsets.size.should eq(factors.size)
        factors.each_with_index do |prime, index|
          offsets[index].should eq(PreparedSieveOracle.offset(exponent, start, count, prime))
        end
      end
    end
  end

  it "preserves first-supplied factors for reversed and duplicate factor lists" do
    [[5_u32, 3_u32, 5_u32, 3_u32], [3_u32, 5_u32, 3_u32, 5_u32]].each do |factors|
      plan = MersenneLab::SievePlan.new(2_u32, factors)
      plan.sieve([1_u64]).should eq([factors[0]])
      plan.sieve_odd_window(1_u64, 1).should eq([factors[0]])
    end

    MersenneLab::SievePlan.new(2_u32, [3_u32, 5_u32, 3_u32, 5_u32]).sieve([1_u64]).should eq([3_u32])
  end

  it "handles the special divisor-three all-hit and no-hit cases" do
    even = MersenneLab::SievePlan.new(2_u32, [3_u32])
    even.roots.should eq([4_u32])
    even.strides.should eq([1_u32])
    even.window_offsets(1_u64, 8).should eq([0_u32])
    even.sieve_odd_window(1_u64, 8).should eq(Array.new(8, 3_u32))

    odd = MersenneLab::SievePlan.new(3_u32, [3_u32])
    odd.roots.should eq([3_u32])
    odd.strides.should eq([3_u32])
    odd.window_offsets(1_u64, 8).should eq([UInt32::MAX])
    odd.sieve_odd_window(1_u64, 8).should eq(Array.new(8, 0_u32))
  end

  it "short-circuits even windows only when three is first and still validates inputs" do
    even_first = MersenneLab::SievePlan.new(2_u32, [3_u32, 5_u32, 7_u32])
    even_first.sieve_odd_window(1_u64, 8).should eq(Array.new(8, 3_u32))
    even_first.sieve_odd_window(UInt64::MAX, 0).should eq([] of UInt32)

    odd_first = MersenneLab::SievePlan.new(3_u32, [3_u32, 5_u32])
    odd_first.sieve_odd_window(1_u64, 4).should eq([0_u32, 0_u32, 0_u32, 5_u32])

    later_three = MersenneLab::SievePlan.new(16_u32, [5_u32, 3_u32])
    MersenneLab.proper_factor?(16_u32, 5_u64, 5_u32).should be_true
    later_three.sieve_odd_window(1_u64, 3).should eq([3_u32, 3_u32, 5_u32])

    expect_raises(ArgumentError) { even_first.sieve_odd_window(0_u64, 0) }
    expect_raises(ArgumentError) { even_first.sieve_odd_window(2_u64, 1) }
    expect_raises(ArgumentError) { even_first.sieve_odd_window(1_u64, -1) }
    expect_raises(ArgumentError) { even_first.sieve_odd_window(1_u64, MersenneLab::SievePlan::MAX_WINDOW_COUNT + 1) }
    expect_raises(ArgumentError) { even_first.sieve_odd_window(UInt64::MAX, 2) }
  end

  it "skips candidate-equals-factor when calculating the first dense offset" do
    plan = MersenneLab::SievePlan.new(1_u32, [7_u32])
    plan.window_offsets(1_u64, 8).should eq([7_u32])
    plan.sieve_odd_window(1_u64, 8).should eq([0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 7_u32])
    plan.sieve([1_u64, 15_u64]).should eq([0_u32, 7_u32])
  end

  it "matches the unchanged sieve on fixed-seed random candidates and dense windows" do
    factors = [97_u32, 3_u32, 11_u32, 5_u32, 97_u32, 7_u32]
    plan = MersenneLab::SievePlan.new(136_279_841_u32, factors)
    state = 0x9e37_79b9_7f4a_7c15_u64
    ks = Array(UInt64).new(512) do
      state = state &* 6_364_136_223_846_793_005_u64 &+ 1_442_695_040_888_963_407_u64
      ((state >> 17) % 500_000).to_u64 * 2_u64 + 1_u64
    end

    plan.sieve(ks).should eq(MersenneLab.sieve(plan.exponent, ks, factors))
    plan.sieve_odd_window(1_000_001_u64, 512).should eq(
      MersenneLab.sieve(plan.exponent, Array(UInt64).new(512) { |index| 1_000_001_u64 + 2_u64 * index.to_u64 }, factors)
    )
  end

  it "prepares roots at maximum UInt32 exponent and handles maximum UInt64 k" do
    exponent = UInt32::MAX
    factors = [65_521_u32, 3_u32, 65_519_u32]
    plan = MersenneLab::SievePlan.new(exponent, factors)

    factors.each_with_index do |prime, index|
      root = plan.roots[index]
      if prime == 3
        root.should eq(exponent.even? ? 4_u32 : 3_u32)
      else
        power = MersenneLab.pow2_mod(exponent, prime).to_u64
        ((power * (3_u64 * root.to_u64 + 1_u64)) % prime.to_u64).should eq(1_u64)
      end
    end

    ks = [UInt64::MAX, UInt64::MAX - 2_u64, 1_u64]
    plan.sieve(ks).should eq(MersenneLab.sieve(exponent, ks, factors))
  end

  it "validates empty and bounded dense windows before returning snapshots" do
    plan = MersenneLab::SievePlan.new(2_u32, [3_u32, 5_u32])
    plan.window_offsets(UInt64::MAX, 0).should eq([UInt32::MAX, UInt32::MAX])
    plan.sieve_odd_window(UInt64::MAX, 0).should eq([] of UInt32)
    plan.window_offsets(UInt64::MAX, 1).should eq([0_u32, UInt32::MAX])
    plan.sieve_odd_window(UInt64::MAX, 1).should eq([3_u32])
    plan.window_offsets(1_u64, 0).should eq([UInt32::MAX, UInt32::MAX])

    expect_raises(ArgumentError) { plan.window_offsets(0_u64, 0) }
    expect_raises(ArgumentError) { plan.sieve_odd_window(2_u64, 0) }
    expect_raises(ArgumentError) { plan.window_offsets(1_u64, -1) }
    expect_raises(ArgumentError) { plan.sieve_odd_window(1_u64, MersenneLab::SievePlan::MAX_WINDOW_COUNT + 1) }
    expect_raises(ArgumentError) { plan.window_offsets(1_u64, MersenneLab::SievePlan::MAX_WINDOW_COUNT + 1) }
    expect_raises(ArgumentError) { plan.window_offsets(UInt64::MAX, 2) }
    expect_raises(ArgumentError) { plan.sieve_odd_window(UInt64::MAX, 2) }
  end

  describe "#verify_witnesses_odd_window!" do
    it "accepts sound dense witnesses at small exponents, equality boundaries, UInt64 max, and large exponents" do
      small = MersenneLab::SievePlan.new(1_u32, [7_u32])
      small_witnesses = small.sieve_odd_window(1_u64, 8)
      small_witnesses.should eq([0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 7_u32])
      small.verify_witnesses_odd_window!(1_u64, 8, small_witnesses).should be_nil

      equality_only = small.sieve_odd_window(1_u64, 1)
      equality_only.should eq([0_u32])
      small.verify_witnesses_odd_window!(1_u64, 1, equality_only).should be_nil

      endpoint = MersenneLab::SievePlan.new(2_u32, [3_u32, 5_u32])
      endpoint_witnesses = endpoint.sieve_odd_window(UInt64::MAX, 1)
      endpoint_witnesses.should eq([3_u32])
      endpoint.verify_witnesses_odd_window!(UInt64::MAX, 1, endpoint_witnesses).should be_nil

      large = MersenneLab::SievePlan.new(136_279_841_u32, [97_u32, 3_u32, 11_u32, 5_u32])
      large_witnesses = large.sieve_odd_window(1_000_001_u64, 128)
      large.verify_witnesses_odd_window!(1_000_001_u64, 128, large_witnesses).should be_nil
    end

    it "rejects unsupported, non-dividing, equality, and misaligned witnesses" do
      plan = MersenneLab::SievePlan.new(2_u32, [3_u32, 5_u32])
      expect_raises(ArgumentError) { plan.verify_witnesses_odd_window!(1_u64, 1, [7_u32]) }
      expect_raises(ArgumentError) { plan.verify_witnesses_odd_window!(3_u64, 1, [5_u32]) }

      equality = MersenneLab::SievePlan.new(1_u32, [7_u32])
      expect_raises(ArgumentError) { equality.verify_witnesses_odd_window!(1_u64, 1, [7_u32]) }
      expect_raises(ArgumentError) { plan.verify_witnesses_odd_window!(1_u64, 2, [3_u32]) }
      expect_raises(ArgumentError) { plan.verify_witnesses_odd_window!(2_u64, 0, [] of UInt32) }
    end

    it "accepts zeros as unresolved without checking coverage or inferring primality" do
      plan = MersenneLab::SievePlan.new(2_u32, [3_u32, 5_u32])
      plan.sieve_odd_window(1_u64, 4).should eq([3_u32, 3_u32, 3_u32, 3_u32])
      plan.verify_witnesses_odd_window!(1_u64, 4, [0_u32, 0_u32, 0_u32, 0_u32]).should be_nil
      plan.verify_witnesses_odd_window!(UInt64::MAX, 0, [] of UInt32).should be_nil
    end
  end
end
