require "big"
require "./metal_backend"

# Executable adversarial checks, including an independent BigInt oracle for
# bounded exponents. Larger exponents use the unchanged modular reference.
def check_window(backend, exponent, start, count, primes, tile)
  ks = Array(UInt64).new(count) { |i| start + 2_u64 * i.to_u64 }
  expected = if exponent <= 32
               ks.map do |k|
                 candidate = (BigInt.new(1) << exponent) * (BigInt.new(3) * k.to_big_i + 1) - 1
                 primes.find { |d| candidate > d.to_big_i && candidate % d.to_big_i == 0 } || 0_u32
               end
             else
               MersenneLab.sieve(exponent, ks, primes)
             end
  plan = MersenneLab::SievePlan.new(exponent, primes)
  raise "CPU dense mismatch" unless plan.sieve_odd_window(start, count) == expected
  raise "Metal candidate mismatch" unless backend.sieve(exponent, ks, primes) == expected
  actual = backend.sieve_odd_window(plan, start, count, tile)
  raise "Metal rank/window mismatch m=#{exponent} start=#{start} count=#{count} tile=#{tile}" unless actual == expected
  plan.verify_witnesses_odd_window!(start, count, actual)
end

backend = MersenneLab::MetalSieve.new
begin
  cases = 0
  [15_u32, 16_u32, 31_u32, 32_u32, UInt32::MAX, 136279841_u32].each do |m|
    [1, 2, 31, 129, 513, 1025, 4097].each do |count|
      [1_u64, UInt64::MAX - 2_u64 * (count - 1).to_u64].each do |start|
        [[65521_u32], [5_u32, 3_u32, 7_u32, 31_u32, 5_u32, 65521_u32],
         [65521_u32, 31_u32, 5_u32, 7_u32, 3_u32, 5_u32]].each do |primes|
          [127, 1024, 65536].each do |tile|
            check_window(backend, m, start, count, primes, tile)
            cases += 1
          end
        end
      end
    end
  end
  check_window(backend, 32_u32, 26111_u64, 1, [65521_u32], 1)
  [15_u32, 16_u32].each do |m|
    check_window(backend, m, 1_u64, 129, [3_u32], 1)
    cases += 1
  end
  check_window(backend, 16_u32, UInt64::MAX, 1, [3_u32, 5_u32], 127)
  check_window(backend, 16_u32, 1_u64, 129, [3_u32, 5_u32], 127)
  cases += 2
  plan = MersenneLab::SievePlan.new(15_u32, [3_u32, 7_u32])
  grid_plan = MersenneLab::SievePlan.new(15_u32, Array(UInt32).new(128, 5_u32))
  shortcut_plan = MersenneLab::SievePlan.new(16_u32, [3_u32, 5_u32])
  raise "empty window mismatch" unless backend.sieve_odd_window(plan, UInt64::MAX, 0).empty?
  raise "empty factors mismatch" unless backend.sieve_odd_window(15_u32, 1_u64, 2, [] of UInt32) == [0_u32, 0_u32]
  [-> { backend.sieve_odd_window(plan, UInt64::MAX, 2) },
   -> { backend.sieve_odd_window(plan, 0_u64, 0) },
   -> { backend.sieve_odd_window(plan, 2_u64, 1) },
   -> { backend.sieve_odd_window(plan, 1_u64, -1) },
   -> { backend.sieve_odd_window(plan, 1_u64, 1, 0) },
   -> { backend.sieve_odd_window(plan, 1_u64, 1, 65537) },
   -> { backend.sieve_odd_window(plan, 1_u64, MersenneLab::SievePlan::MAX_WINDOW_COUNT + 1) },
   -> { backend.sieve_odd_window(grid_plan, 1_u64, MersenneLab::SievePlan::MAX_WINDOW_COUNT, 1) },
   -> { backend.sieve_odd_window(shortcut_plan, UInt64::MAX, 2) },
   -> { backend.sieve_odd_window(shortcut_plan, 2_u64, 0) },
   -> { backend.sieve_odd_window(shortcut_plan, 1_u64, 1, 0) },
   -> { backend.sieve_odd_window(14_u32, 1_u64, 1, [7_u32]) }].each do |invalid|
    begin
      invalid.call
    rescue ArgumentError
      next
    end
    raise "invalid window was accepted"
  end
  # Multiple instances must remain usable in alternating calls. Metal
  # pipelines are cached; each instance owns its closed state and call mutex.
  other = MersenneLab::MetalSieve.new
  begin
    3.times do
      check_window(other, 16_u32, 1_u64, 129, [5_u32, 3_u32], 127)
      check_window(backend, 15_u32, UInt64::MAX - 256, 129, [7_u32, 3_u32], 127)
    end
  ensure
    other.close
  end
  backend.close
  backend.close
  [-> { backend.sieve(15_u32, [1_u64], [7_u32]) },
   -> { backend.sieve_odd_window(plan, 1_u64, 1) }].each do |closed_call|
    begin
      closed_call.call
    rescue error
      raise error unless error.message == "Metal sieve is closed"
      next
    end
    raise "closed Metal backend was accepted"
  end
  puts "metal_window_cases=#{cases + 7} all_outputs_match=true invalid_inputs_rejected=true closed_state_checked=true"
ensure
  backend.close
end
