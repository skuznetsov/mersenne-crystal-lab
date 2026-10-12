require "spec"
require "big"
require "../exponent_sieve"

module ExponentSieveOracle
  def self.candidate(exponent : UInt32) : BigInt
    (BigInt.new(1) << exponent.to_i) - 1
  end

  def self.first_factor(start : UInt32, count : Int32, primes : Array(UInt32)) : Array(UInt32)
    Array(UInt32).new(count) do |index|
      exponent = start + 2_u32 * index.to_u32
      value = candidate(exponent)
      factor = 0_u32
      primes.each do |prime|
        if value > prime.to_big_i && value % prime.to_big_i == 0
          factor = prime
          break
        end
      end
      factor
    end
  end

  def self.first_offset(start : UInt32, count : Int32, prime : UInt32) : UInt32
    count.times do |index|
      exponent = start + 2_u32 * index.to_u32
      value = candidate(exponent)
      return index.to_u32 if value > prime.to_big_i && value % prime.to_big_i == 0
    end
    UInt32::MAX
  end

  # Independent minimal-order oracle: visit 2, 2^2, ... by repeated doubling.
  def self.order_by_repeated_doubling(prime : UInt32) : UInt32
    residue = 1_u64
    exponent = 1_u32
    while exponent < prime
      residue = (residue * 2_u64) % prime.to_u64
      return exponent if residue == 1_u64
      exponent += 1_u32
    end
    raise "no order found for prime #{prime}"
  end

  # Independent Eratosthenes enumeration for the complete admitted prime set.
  def self.odd_primes_through(limit : UInt32) : Array(UInt32)
    prime = Array(Bool).new(limit.to_i + 1, true)
    prime[0] = false
    prime[1] = false
    divisor = 2_u32
    while divisor.to_u64 * divisor.to_u64 <= limit.to_u64
      if prime[divisor.to_i]
        multiple = divisor * divisor
        while multiple <= limit
          prime[multiple.to_i] = false
          multiple += divisor
        end
      end
      divisor += 1_u32
    end

    result = [] of UInt32
    number = 3_u32
    while number <= limit
      result << number if prime[number.to_i]
      number += 2_u32
    end
    result
  end
end

describe MersenneLab::ExponentSievePlan do
  it "validates factors and reports exact minimal orders, including the upper domain prime" do
    factors = [3_u32, 5_u32, 7_u32, 13_u32, 23_u32, 31_u32, 89_u32, 8_191_u32, 65_521_u32]
    factors.each do |prime|
      MersenneLab::ExponentSievePlan.order_of_two(prime).should eq(
        ExponentSieveOracle.order_by_repeated_doubling(prime)
      )
    end

    MersenneLab::ExponentSievePlan.order_of_two(3_u32).should eq(2_u32)
    MersenneLab::ExponentSievePlan.order_of_two(5_u32).should eq(4_u32)
    MersenneLab::ExponentSievePlan.order_of_two(7_u32).should eq(3_u32)
    MersenneLab::ExponentSievePlan.order_of_two(13_u32).should eq(12_u32)
    expect_raises(ArgumentError) { MersenneLab::ExponentSievePlan.order_of_two(0_u32) }
    expect_raises(ArgumentError) { MersenneLab::ExponentSievePlan.order_of_two(2_u32) }
    expect_raises(ArgumentError) { MersenneLab::ExponentSievePlan.order_of_two(9_u32) }
    expect_raises(ArgumentError) { MersenneLab::ExponentSievePlan.order_of_two(65_537_u32) }
  end

  it "groups equal odd orders, omits even orders, and preserves earliest input order" do
    factors = [89_u32, 7_u32, 23_u32, 5_u32, 3_u32, 89_u32, 31_u32, 7_u32]
    plan = MersenneLab::ExponentSievePlan.new(factors)

    plan.prime_count.should eq(8)
    plan.active_count.should eq(3)
    plan.primes.should eq(factors)
    plan.active_primes.should eq([89_u32, 7_u32, 31_u32])
    plan.orders.should eq([11_u32, 3_u32, 5_u32])

    empty = MersenneLab::ExponentSievePlan.new([] of UInt32)
    empty.prime_count.should eq(0)
    empty.active_count.should eq(0)
    empty.primes.should eq([] of UInt32)
    empty.active_primes.should eq([] of UInt32)
    empty.orders.should eq([] of UInt32)
  end

  it "drops only later odd orders covered by an earlier retained order" do
    ascending = MersenneLab::ExponentSievePlan.new([7_u32, 73_u32, 151_u32])
    ascending.active_primes.should eq([7_u32])
    ascending.orders.should eq([3_u32])
    # M_3 equals 7, so the first proper hit is at q=9 and remains covered.
    ascending.sieve_odd_window(1_u32, 5).should eq([0_u32, 0_u32, 0_u32, 0_u32, 7_u32])

    reverse_order = MersenneLab::ExponentSievePlan.new([73_u32, 7_u32])
    reverse_order.active_primes.should eq([73_u32, 7_u32])
    reverse_order.orders.should eq([9_u32, 3_u32])
    reverse_order.sieve_odd_window(1_u32, 5).should eq([0_u32, 0_u32, 0_u32, 0_u32, 73_u32])

    overlap = MersenneLab::ExponentSievePlan.new([89_u32, 7_u32, 23_u32])
    overlap.active_primes.should eq([89_u32, 7_u32])
    overlap.orders.should eq([11_u32, 3_u32])
    overlap.sieve_odd_window(33_u32, 1).should eq([89_u32])
  end

  it "reduces the independently enumerated full trial-prime domain to 479 odd-order groups" do
    factors = ExponentSieveOracle.odd_primes_through(MersenneLab::MAX_TRIAL_PRIME)
    factors.size.should eq(6_541)

    plan = MersenneLab::ExponentSievePlan.new(factors)
    plan.prime_count.should eq(6_541)
    plan.active_count.should eq(479)

    plan.active_primes.each_with_index do |prime, index|
      plan.orders[index].should eq(ExponentSieveOracle.order_by_repeated_doubling(prime))
    end
  end

  it "copies constructor inputs and every exposed factor and order array" do
    factors = [89_u32, 23_u32, 7_u32, 5_u32, 3_u32, 31_u32]
    plan = MersenneLab::ExponentSievePlan.new(factors)
    factors[0] = 3_u32

    prime_snapshot = plan.primes
    active_snapshot = plan.active_primes
    order_snapshot = plan.orders
    prime_snapshot[0] = 3_u32
    active_snapshot[0] = 3_u32
    order_snapshot[0] = 1_u32

    plan.primes.should eq([89_u32, 23_u32, 7_u32, 5_u32, 3_u32, 31_u32])
    plan.active_primes.should eq([89_u32, 7_u32, 31_u32])
    plan.orders.should eq([11_u32, 3_u32, 5_u32])
  end

  it "matches an independent BigInt oracle for offsets and original-factor precedence" do
    factors = [89_u32, 7_u32, 23_u32, 5_u32, 3_u32, 89_u32, 31_u32, 13_u32, 17_u32, 19_u32]
    plan = MersenneLab::ExponentSievePlan.new(factors)

    [1_u32, 3_u32, 11_u32, 17_u32].each do |start|
      count = 32
      expected = ExponentSieveOracle.first_factor(start, count, factors)
      plan.sieve_odd_window(start, count).should eq(expected)

      expected_offsets = plan.active_primes.map do |prime|
        ExponentSieveOracle.first_offset(start, count, prime)
      end
      plan.window_offsets(start, count).should eq(expected_offsets)
    end
  end

  it "skips equality at low Mersenne exponents and returns only later proper factors" do
    [{3_u32, 7_u32}, {5_u32, 31_u32}, {7_u32, 127_u32}, {13_u32, 8_191_u32}].each do |exponent, prime|
      plan = MersenneLab::ExponentSievePlan.new([prime])
      equality_index = (exponent - 1_u32) // 2_u32
      proper_index = (3_u32 * exponent - 1_u32) // 2_u32

      plan.sieve_odd_window(1_u32, (equality_index + 1_u32).to_i32)[equality_index.to_i].should eq(0_u32)
      plan.window_offsets(1_u32, (proper_index + 1_u32).to_i32).should eq([proper_index])
      plan.sieve_odd_window(1_u32, (proper_index + 1_u32).to_i32)[proper_index.to_i].should eq(prime)
    end

    MersenneLab::ExponentSievePlan.new([7_u32]).sieve_odd_window(1_u32, 1).should eq([0_u32])
  end

  it "handles UInt32 maximum endpoints and rejects overflow or invalid windows" do
    plan = MersenneLab::ExponentSievePlan.new([7_u32])

    plan.window_offsets(UInt32::MAX, 1).should eq([0_u32])
    plan.sieve_odd_window(UInt32::MAX, 1).should eq([7_u32])
    plan.window_offsets(UInt32::MAX - 2_u32, 2).should eq([1_u32])
    plan.sieve_odd_window(UInt32::MAX - 2_u32, 2).should eq([0_u32, 7_u32])
    plan.window_offsets(UInt32::MAX, 0).should eq([UInt32::MAX])

    expect_raises(ArgumentError) { plan.window_offsets(0_u32, 0) }
    expect_raises(ArgumentError) { plan.sieve_odd_window(2_u32, 0) }
    expect_raises(ArgumentError) { plan.window_offsets(1_u32, -1) }
    expect_raises(ArgumentError) { plan.sieve_odd_window(1_u32, MersenneLab::ExponentSievePlan::MAX_WINDOW_COUNT + 1) }
    expect_raises(ArgumentError) { plan.window_offsets(UInt32::MAX, 2) }
    expect_raises(ArgumentError) { plan.sieve_odd_window(UInt32::MAX - 2_u32, 3) }
  end

  it "rejects unsupported factors and validates witness soundness without requiring coverage" do
    [0_u32, 2_u32, 9_u32, 65_537_u32].each do |prime|
      expect_raises(ArgumentError) { MersenneLab::ExponentSievePlan.new([prime]) }
    end

    plan = MersenneLab::ExponentSievePlan.new([89_u32, 7_u32, 23_u32, 5_u32, 3_u32])
    witnesses = plan.sieve_odd_window(1_u32, 24)
    plan.verify_witnesses_odd_window!(1_u32, 24, witnesses).should be_nil
    plan.verify_witnesses_odd_window!(1_u32, 24, Array.new(24, 0_u32)).should be_nil
    plan.verify_witnesses_odd_window!(11_u32, 1, [23_u32]).should be_nil

    expect_raises(ArgumentError) { plan.verify_witnesses_odd_window!(1_u32, 1, [31_u32]) }
    expect_raises(ArgumentError) { plan.verify_witnesses_odd_window!(1_u32, 1, [89_u32]) }
    expect_raises(ArgumentError) { plan.verify_witnesses_odd_window!(3_u32, 1, [7_u32]) }
    expect_raises(ArgumentError) { plan.verify_witnesses_odd_window!(5_u32, 1, [7_u32]) }
    expect_raises(ArgumentError) { plan.verify_witnesses_odd_window!(1_u32, 2, [0_u32]) }
  end
end
