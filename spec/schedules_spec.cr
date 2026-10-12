require "spec"
require "big"
require "../schedules"

describe MersenneLab::Schedules do
  it "matches sparse candidates to exact Mersenne values in a controlled domain" do
    pairs = MersenneLab::Schedules.compatible_k_sequence(3_u32, 13_u32)
    pairs.map { |q, _k| q }.should eq([5_u32, 7_u32, 9_u32, 11_u32, 13_u32])

    pairs.each do |q, k|
      generated = (BigInt.new(1) << 3) * (BigInt.new(3) * k + 1) - 1
      mersenne = (BigInt.new(1) << q.to_i) - 1
      generated.should eq(mersenne)
    end
  end

  it "reports equal Mersenne hits and excludes composite exponents" do
    result = MersenneLab::Schedules.run_experiment(3_u32, 13_u32)
    expected_hits = [5_u32, 7_u32, 13_u32]

    result.odd_k_scan.mersenne_hits.should eq(expected_hits)
    result.compatible_k_recurrence.mersenne_hits.should eq(expected_hits)
    result.prime_exponent_selection.mersenne_hits.should eq(expected_hits)
    result.prime_exponent_selection.selected_prime_exponents.should eq([5_u32, 7_u32, 11_u32, 13_u32])
    result.prime_exponent_selection.selected_prime_exponents.should_not contain(9_u32)
    result.odd_k_scan.candidate_count.should eq(171_u64)
    result.compatible_k_recurrence.candidate_count.should eq(5_u64)
  end

  it "rejects ordinary progression primes that are not Mersenne-shaped" do
    progression_prime = (BigInt.new(1) << 3) * (BigInt.new(3) * 3 + 1) - 1
    progression_prime.should eq(BigInt.new(79))
    MersenneLab::Schedules.gmp_probable_prime?(progression_prime).should be_true
    MersenneLab::Schedules.mersenne_exponent(progression_prime).should be_nil
  end

  it "keeps the maximum execution gap and UInt64 k bound exact" do
    pairs = MersenneLab::Schedules.compatible_k_sequence(111_u32, 127_u32)
    pairs.size.should eq(8)
    pairs.last.should eq({127_u32, 21_845_u64})

    counts = MersenneLab::Schedules.analytic_counts(111_u32, 127_u32)
    counts.legacy_max_odd_k.should eq(21_845_u64)
    counts.legacy_gmp_screen_calls.should eq(10_923_u64)
  end

  it "uses the greatest odd k under an odd exponent-gap ceiling" do
    counts = MersenneLab::Schedules.analytic_counts(3_u32, 6_u32)
    counts.legacy_max_odd_k.should eq(1_u64)
    counts.legacy_gmp_screen_calls.should eq(1_u64)
  end

  it "estimates the q=61 legacy scan analytically without running it" do
    counts = MersenneLab::Schedules.analytic_counts(31_u32, 61_u32)
    counts.legacy_max_odd_k.should eq(357_913_941_u64)
    counts.legacy_gmp_screen_calls.should eq(178_956_971_u64)
    counts.compatible_k_candidates.should eq(15_u64)
    counts.prime_exponent_candidates.should eq(7_u64)
    counts.selected_prime_exponents.last.should eq(61_u32)
  end

  it "rejects ranges outside the bounded execution domain" do
    expect_raises(ArgumentError) { MersenneLab::Schedules.run_experiment(0_u32, 10_u32) }
    expect_raises(ArgumentError) { MersenneLab::Schedules.run_experiment(2_u32, 10_u32) }
    expect_raises(ArgumentError) { MersenneLab::Schedules.run_experiment(10_u32, 9_u32) }
    expect_raises(ArgumentError) { MersenneLab::Schedules.run_experiment(31_u32, 61_u32) }
    expect_raises(ArgumentError) { MersenneLab::Schedules.run_experiment(3_u32, 20_u32) }
    expect_raises(ArgumentError) { MersenneLab::Schedules.run_experiment(1_u32, 128_u32) }
  end
end
