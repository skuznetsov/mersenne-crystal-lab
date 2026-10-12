require "json"
require "./exponent_sieve"

raise ArgumentError.new("usage: exponent_order_checks [oracle_json]") if ARGV.size > 1
oracle = JSON.parse(File.read(ARGV[0]? || File.join(__DIR__, "results/order_oracle.json")))
orders_by_prime = oracle["orders_by_prime"].as_h
primes = oracle["primes"].as_a.map { |value| value.as_i64.to_u32 }

mismatches = [] of String
primes.each do |prime|
  expected = orders_by_prime[prime.to_s].as_i64.to_u32
  actual = MersenneLab::ExponentSievePlan.order_of_two(prime)
  mismatches << "#{prime}: expected #{expected}, got #{actual}" if expected != actual
end
raise "order mismatch: #{mismatches.first(10)}" unless mismatches.empty?

expected_active_primes = [] of UInt32
expected_orders = [] of UInt32
primes.each do |prime|
  order = orders_by_prime[prime.to_s].as_i64.to_u32
  next if order.even?
  next if expected_orders.any? { |earlier| order % earlier == 0 }
  expected_active_primes << prime
  expected_orders << order
end
plan = MersenneLab::ExponentSievePlan.new(primes)
raise "active representative mismatch" unless plan.active_primes == expected_active_primes
raise "active order mismatch" unless plan.orders == expected_orders

q_checked = 0
(1_u32..255_u32).step(2) do |q|
  candidate_bound = q < 16 ? ((1_u64 << q) - 1_u64) : UInt64::MAX
  expected = primes.find do |prime|
    order = orders_by_prime[prime.to_s].as_i64.to_u32
    q % order == 0 && prime.to_u64 < candidate_bound
  end || 0_u32
  actual = plan.sieve_odd_window(q, 1)[0]
  raise "complete-prime q=#{q}: expected #{expected}, got #{actual}" unless actual == expected
  q_checked += 1
end

def check_single(name : String, factors : Array(UInt32), q : UInt32, expected : UInt32) : Nil
  actual = MersenneLab::ExponentSievePlan.new(factors).sieve_odd_window(q, 1)[0]
  raise "#{name}: expected #{expected}, got #{actual}" unless actual == expected
end

check_single("ascending_divisor_dominates_q9", [7_u32, 73_u32], 9_u32, 7_u32)
check_single("earlier_composite_order_q9", [73_u32, 7_u32], 9_u32, 73_u32)
check_single("arbitrary_rank_q33", [89_u32, 7_u32, 23_u32], 33_u32, 89_u32)
check_single("same_order_first_23_q11", [23_u32, 89_u32], 11_u32, 23_u32)
check_single("same_order_first_89_q11", [89_u32, 23_u32], 11_u32, 89_u32)
check_single("equal_candidate_q3", [7_u32], 3_u32, 0_u32)
check_single("equal_candidate_q5", [31_u32], 5_u32, 0_u32)
check_single("equal_candidate_q7", [127_u32], 7_u32, 0_u32)
check_single("equal_candidate_q13", [8191_u32], 13_u32, 0_u32)
check_single("q9_order9", [73_u32], 9_u32, 73_u32)
check_single("q15_order15", [151_u32], 15_u32, 151_u32)
max_window = MersenneLab::ExponentSievePlan.new([7_u32]).sieve_odd_window(UInt32::MAX - 2_u32, 2)
raise "max_endpoint_stride: expected [0, 7], got #{max_window}" unless max_window == [0_u32, 7_u32]

empty = plan.window_offsets(UInt32::MAX, 0)
raise "zero-count max endpoint should be valid" unless empty.size == plan.active_count
begin
  plan.window_offsets(UInt32::MAX, 2)
  raise "overflowing endpoint was accepted"
rescue ArgumentError
end

puts "orders_compared=#{primes.size}"
puts "order_mismatches=#{mismatches.size}"
puts "odd_order_primes=#{primes.count { |p| orders_by_prime[p.to_s].as_i64.odd? }}"
puts "retained_groups=#{plan.active_count}"
puts "retained_density=#{expected_orders.sum { |r| 1.0_f64 / r }}"
puts "complete_ascending_q_cases=#{q_checked}"
puts "precedence_probes=11"
puts "boundary_zero_count=pass"
puts "boundary_overflow=pass"
