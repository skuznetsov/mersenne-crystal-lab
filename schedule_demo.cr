require "./schedules"

include MersenneLab

if ARGV.size != 0 && ARGV.size != 2
  raise ArgumentError.new("usage: crystal run schedule_demo.cr [base_exponent upper_exponent]")
end

base_exponent = ARGV.size == 2 ? ARGV[0].to_u32 : 3_u32
upper_exponent = ARGV.size == 2 ? ARGV[1].to_u32 : 19_u32
comparison = Schedules.run_experiment(base_exponent, upper_exponent)

puts "MPGS candidate schedule comparison"
puts "GMP probable-prime screening uses 25 repetitions; positive screens are not primality proofs."
puts "Inclusive exponent ceiling: #{base_exponent}..#{upper_exponent}; odd-k candidates stop at G_m(k) <= 2^upper - 1."
puts

results = [
  comparison.odd_k_scan,
  comparison.compatible_k_recurrence,
  comparison.prime_exponent_selection,
]
raise "candidate schedules disagree on Mersenne hits" unless results.all? { |result| result.mersenne_hits == results.first.mersenne_hits }
puts "schedule_hits_match=true"

results.each do |result|
  puts "#{result.name}:"
  puts "  candidate GMP screens: #{result.candidate_prime_screens}"
  puts "  exponent GMP screens:  #{result.exponent_prime_screens}"
  puts "  selected prime exponents: #{result.selected_prime_exponents.join(", ")}"
  puts "  GMP-probable Mersenne hits: #{result.mersenne_hits.join(", ")}"
  puts "  elapsed: #{result.wall_time.total_milliseconds.round(3)} ms"
end

puts
puts "Formula-only scale reference (no legacy enumeration or candidate screens run):"
analytic = Schedules.analytic_counts(31_u32, 61_u32)
puts "  m=31, upper q=61: legacy odd-k max #{analytic.legacy_max_odd_k}"
puts "  estimated legacy GMP screen calls: #{analytic.legacy_gmp_screen_calls}"
puts "  exact compatible-k candidates: #{analytic.compatible_k_candidates}"
puts "  prime-exponent candidates after screening: #{analytic.prime_exponent_candidates}"
puts "  selected q: #{analytic.selected_prime_exponents.join(", ")}"
puts "Elapsed values are one-run exploratory timings, not a performance conclusion or a GIMPS comparison."
