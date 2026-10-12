require "spec"
require "big"
require "../core"

describe MersenneLab do
  describe ".pow2_mod" do
    it "computes powers modulo a positive modulus" do
      MersenneLab.pow2_mod(0_u32, 7_u32).should eq(1_u32)
      MersenneLab.pow2_mod(10_u32, 13_u32).should eq(10_u32)
    end

    it "rejects a zero modulus" do
      expect_raises(ArgumentError) { MersenneLab.pow2_mod(1_u32, 0_u32) }
    end
  end

  describe ".residue" do
    it "matches exact BigInt candidates over a small domain and large k values" do
      primes = [3_u32, 5_u32, 7_u32, 11_u32, 13_u32, 17_u32, 19_u32, 23_u32, 65_521_u32]
      ks = [1_u64, 3_u64, 9_u64, UInt64::MAX]

      (1_u32..16_u32).each do |exponent|
        ks.each do |k|
          coefficient = BigInt.new(3) * k.to_big_i + 1
          candidate = (BigInt.new(1) << exponent) * coefficient - 1

          primes.each do |d|
            MersenneLab.residue(exponent, k, d).should eq((candidate % d.to_big_i).to_u32)
            MersenneLab.proper_factor?(exponent, k, d).should eq(candidate > d.to_big_i && candidate % d.to_big_i == 0)
          end
        end
      end
    end

    it "handles UInt64::MAX k without overflowing the coefficient" do
      exponent = 61_u32
      d = 65_521_u32
      coefficient = BigInt.new(3) * UInt64::MAX.to_big_i + 1
      candidate = (BigInt.new(1) << exponent) * coefficient - 1

      MersenneLab.residue(exponent, UInt64::MAX, d).should eq((candidate % d.to_big_i).to_u32)
    end

    it "handles exponent 136279841 with small modular controls" do
      # 136279841 mod 3 = 2, so 2^m mod 7 = 4. These controls check both
      # a divisible and a non-divisible candidate without building 2^m.
      MersenneLab.residue(136_279_841_u32, 5_u64, 7_u32).should eq(0_u32)
      MersenneLab.proper_factor?(136_279_841_u32, 5_u64, 7_u32).should be_true
      MersenneLab.residue(136_279_841_u32, 1_u64, 7_u32).should eq(1_u32)
      MersenneLab.proper_factor?(136_279_841_u32, 1_u64, 7_u32).should be_false
    end
  end

  describe ".proper_factor?" do
    it "does not call a candidate itself a proper factor" do
      MersenneLab.proper_factor?(1_u32, 1_u64, 7_u32).should be_false
      MersenneLab.proper_factor?(3_u32, 1_u64, 31_u32).should be_false
    end

    it "accepts a genuine proper divisor" do
      MersenneLab.proper_factor?(2_u32, 1_u64, 3_u32).should be_true
    end
  end

  describe ".sieve" do
    it "returns the first supplied proper factor and uses zero for unresolved candidates" do
      MersenneLab.sieve(2_u32, [1_u64, 3_u64], [5_u32, 3_u32]).should eq([5_u32, 3_u32])
      MersenneLab.sieve(1_u32, [13_u64], [3_u32, 5_u32, 7_u32, 11_u32]).should eq([0_u32])
      MersenneLab.sieve(1_u32, [1_u64, 3_u64], [] of UInt32).should eq([0_u32, 0_u32])
    end

    it "validates candidate and trial-prime domains" do
      expect_raises(ArgumentError) { MersenneLab.sieve(0_u32, [1_u64], [3_u32]) }
      expect_raises(ArgumentError) { MersenneLab.sieve(2_u32, [0_u64], [3_u32]) }
      expect_raises(ArgumentError) { MersenneLab.sieve(2_u32, [2_u64], [3_u32]) }
      expect_raises(ArgumentError) { MersenneLab.sieve(2_u32, [1_u64], [2_u32]) }
      expect_raises(ArgumentError) { MersenneLab.sieve(2_u32, [1_u64], [9_u32]) }
      expect_raises(ArgumentError) { MersenneLab.sieve(2_u32, [1_u64], [65_537_u32]) }
    end
  end
end
