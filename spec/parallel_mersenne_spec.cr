require "spec"
require "big"
require "atomic"
require "fiber/execution_context"
require "../prepared_sieve"
require "../schedules"
require "../jabari_adapters"
require "../parallel_mersenne"

class ParallelMersenneFailureOnce < MersenneLab::ParallelMersenne
  @fail_next : Atomic(Bool)

  def initialize(workers : Int32, chunk_size : Int32 = 1)
    super(workers, chunk_size)
    @fail_next = Atomic(Bool).new(true)
  end

  protected def probable_prime?(candidate : BigInt) : Bool
    _, failed = @fail_next.compare_and_set(true, false)
    raise RuntimeError.new("injected worker failure") if failed
    MersenneLab::Schedules.gmp_probable_prime?(candidate)
  end
end

class ParallelMersenneProbe < MersenneLab::ParallelMersenne
  def initialize(
    workers : Int32,
    chunk_size : Int32,
    @entered : Channel(Tuple(UInt32, UInt64)),
    @release : Channel(Nil),
  )
    super(workers, chunk_size)
  end

  protected def probable_prime?(candidate : BigInt) : Bool
    @entered.send({candidate.bit_length.to_u32, Thread.current.object_id})
    @release.receive
    MersenneLab::Schedules.gmp_probable_prime?(candidate)
  end
end

describe MersenneLab::ParallelMersenne do
  it "matches the single-core adapters for uneven work at 1, 2, and 4 workers" do
    expected = MersenneLab::JabariAdapters.baseline_mersenne(17_u32, 11)

    {1, 2, 4}.each do |worker_count|
      scanner = MersenneLab::ParallelMersenne.new(worker_count, 4)
      begin
        actual = scanner.baseline_mersenne(17_u32, 11)
        actual.states.should eq(expected.states)
        actual.prime_screen_count.should eq(11_u64)
      ensure
        scanner.close
      end
    end
  end

  it "preserves witness filtering, duplicates, output order, and exact GMP call counts" do
    witnesses = [0_u32, 0_u32, 127_u32, 47_u32, 31_u32, 7_u32, 233_u32, 0_u32, 7_u32]
    expected = MersenneLab::JabariAdapters.screen_mersenne(17_u32, witnesses)
    scanner = MersenneLab::ParallelMersenne.new(4, 2)

    begin
      actual = scanner.screen_mersenne(17_u32, witnesses)
      actual.states.should eq(expected.states)
      actual.prime_screen_count.should eq(witnesses.count(0_u32).to_u64)
      actual.states.should eq([2_u8, 2_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 2_u8, 0_u8])
    ensure
      scanner.close
    end
  end

  it "returns a composite-filled result without GMP work when every candidate is witnessed" do
    scanner = MersenneLab::ParallelMersenne.new(3, 3)

    begin
      result = scanner.screen_mersenne(21_u32, [7_u32, 47_u32, 31_u32, 7_u32, 233_u32])
      result.states.should eq(Array.new(5, MersenneLab::JabariAdapters::COMPOSITE))
      result.prime_screen_count.should eq(0_u64)
    ensure
      scanner.close
    end
  end

  it "uses one witness snapshot when callers mutate the source array after admission" do
    count = 4
    witnesses = Array.new(count, 0_u32)
    entered = Channel(Tuple(UInt32, UInt64)).new(count)
    release = Channel(Nil).new(count)
    scanner = ParallelMersenneProbe.new(1, 1, entered, release)
    results = Channel(MersenneLab::JabariAdapters::Result).new(1)
    completed = false
    caller = Fiber::ExecutionContext::Isolated.new("parallel-mersenne-witness-snapshot") do
      results.send(scanner.screen_mersenne(17_u32, witnesses))
    end

    observed = entered.receive
    witnesses.fill(31_u32)
    count.times { release.send(nil) }

    result = results.receive
    caller.wait
    completed = true
    expected = MersenneLab::JabariAdapters.baseline_mersenne(17_u32, count)
    observed[0].should eq(23_u32)
    witnesses.should eq(Array.new(count, 31_u32))
    result.states.should eq(expected.states)
    result.prime_screen_count.should eq(count.to_u64)
  ensure
    release.try(&.close) unless completed
    scanner.try(&.close)
  end

  it "supports empty intervals and repeated calls on the same worker pool" do
    scanner = MersenneLab::ParallelMersenne.new(2, 5)

    begin
      scanner.baseline_mersenne(4_095_u32, 0).states.should eq([] of UInt8)
      scanner.screen_mersenne(4_095_u32, [] of UInt32).states.should eq([] of UInt8)
      first = scanner.baseline_mersenne(17_u32, 5)
      second = scanner.screen_mersenne(17_u32, [0_u32, 0_u32, 7_u32, 47_u32, 31_u32])
      baseline = MersenneLab::JabariAdapters.baseline_mersenne(17_u32, 5)
      first.states.should eq(baseline.states)
      second.states.should eq(baseline.states)
      first.prime_screen_count.should eq(5_u64)
      second.prime_screen_count.should eq(2_u64)
    ensure
      scanner.close
    end
  end

  it "validates worker, chunk, exponent, count, and interval bounds" do
    expect_raises(ArgumentError) { MersenneLab::ParallelMersenne.new(0) }
    expect_raises(ArgumentError) { MersenneLab::ParallelMersenne.new(65) }
    expect_raises(ArgumentError) { MersenneLab::ParallelMersenne.new(1, 0) }
    expect_raises(ArgumentError) { MersenneLab::ParallelMersenne.new(1, 4_097) }

    scanner = MersenneLab::ParallelMersenne.new(1)
    begin
      expect_raises(ArgumentError) { scanner.baseline_mersenne(16_u32, 1) }
      expect_raises(ArgumentError) { scanner.baseline_mersenne(18_u32, 1) }
      expect_raises(ArgumentError) { scanner.baseline_mersenne(4_097_u32, 1) }
      expect_raises(ArgumentError) { scanner.baseline_mersenne(4_095_u32, 2) }
      expect_raises(ArgumentError) { scanner.baseline_mersenne(17_u32, -1) }
      expect_raises(ArgumentError) do
        scanner.baseline_mersenne(17_u32, MersenneLab::SievePlan::MAX_WINDOW_COUNT + 1)
      end
      expect_raises(ArgumentError) { scanner.screen_mersenne(4_095_u32, [0_u32, 0_u32]) }
    ensure
      scanner.close
    end
  end

  it "serializes concurrent callers and makes close idempotent" do
    scanner = MersenneLab::ParallelMersenne.new(3, 2)
    results = Channel(MersenneLab::JabariAdapters::Result).new(0)
    first = Fiber::ExecutionContext::Isolated.new("parallel-mersenne-caller-1") do
      results.send(scanner.baseline_mersenne(17_u32, 7))
    end
    second = Fiber::ExecutionContext::Isolated.new("parallel-mersenne-caller-2") do
      results.send(scanner.baseline_mersenne(19_u32, 5))
    end

    expected_first = MersenneLab::JabariAdapters.baseline_mersenne(17_u32, 7)
    expected_second = MersenneLab::JabariAdapters.baseline_mersenne(19_u32, 5)
    outputs = [results.receive, results.receive]
    outputs.map(&.states).should contain(expected_first.states)
    outputs.map(&.states).should contain(expected_second.states)
    first.wait
    second.wait
    scanner.close
    scanner.close
    expect_raises(RuntimeError) { scanner.baseline_mersenne(17_u32, 1) }
  ensure
    scanner.try(&.close)
  end

  it "waits for a blocked worker before close returns and rejects later calls" do
    entered = Channel(Tuple(UInt32, UInt64)).new
    release = Channel(Nil).new(1)
    scanner = ParallelMersenneProbe.new(1, 1, entered, release)
    results = Channel(MersenneLab::JabariAdapters::Result).new(1)
    caller = Fiber::ExecutionContext::Isolated.new("parallel-mersenne-close-caller") do
      results.send(scanner.baseline_mersenne(17_u32, 1))
    end
    observed = entered.receive
    close_started = Channel(Nil).new(1)
    close_returned = Channel(Nil).new(1)
    closer = Fiber::ExecutionContext::Isolated.new("parallel-mersenne-closer") do
      close_started.send(nil)
      scanner.close
      close_returned.send(nil)
    end

    close_started.receive
    returned_before_release = false
    select
    when close_returned.receive
      returned_before_release = true
    when timeout(10.milliseconds)
    end

    release.send(nil)
    result = results.receive
    unless returned_before_release
      close_returned.receive
    end
    caller.wait
    closer.wait

    returned_before_release.should be_false
    observed[0].should eq(17_u32)
    result.states.should eq([MersenneLab::JabariAdapters::PROBABLE_PRIME_MERSENNE])
    expect_raises(RuntimeError) { scanner.screen_mersenne(17_u32, [0_u32]) }
  ensure
    release.try(&.close)
    scanner.try(&.close)
  end

  it "assigns distinct uneven-chunk tasks to multiple worker threads without omissions" do
    worker_count = 4
    count = 11
    entered = Channel(Tuple(UInt32, UInt64)).new(count)
    release = Channel(Nil).new(count)
    scanner = ParallelMersenneProbe.new(worker_count, 3, entered, release)
    results = Channel(MersenneLab::JabariAdapters::Result).new(1)
    caller = Fiber::ExecutionContext::Isolated.new("parallel-mersenne-worker-probe") do
      results.send(scanner.baseline_mersenne(17_u32, count))
    end

    observations = [] of Tuple(UInt32, UInt64)
    worker_ids = [] of UInt64
    while worker_ids.size < worker_count
      observation = entered.receive
      observations << observation
      worker_ids << observation[1] unless worker_ids.includes?(observation[1])
    end
    worker_ids.size.should eq(worker_count)

    worker_count.times { release.send(nil) }
    (count - worker_count).times do
      observations << entered.receive
      release.send(nil)
    end

    result = results.receive
    caller.wait
    expected = MersenneLab::JabariAdapters.baseline_mersenne(17_u32, count)
    result.states.should eq(expected.states)
    result.prime_screen_count.should eq(count.to_u64)

    exponents = observations.map(&.first)
    exponents.sort.should eq(count.times.map { |index| 17_u32 + 2_u32 * index.to_u32 }.to_a)
    exponents.uniq.size.should eq(count)
    observations.map(&.last).uniq.size.should eq(worker_count)
    scanner.close
  ensure
    release.try(&.close)
    scanner.try(&.close)
  end

  it "drains workers after a worker error, propagates it, and remains usable" do
    scanner = ParallelMersenneFailureOnce.new(4, 1)

    begin
      error = expect_raises(RuntimeError) { scanner.baseline_mersenne(17_u32, 9) }
      error.message.should eq("injected worker failure")

      result = scanner.baseline_mersenne(17_u32, 9)
      expected = MersenneLab::JabariAdapters.baseline_mersenne(17_u32, 9)
      result.states.should eq(expected.states)
      result.prime_screen_count.should eq(9_u64)
    ensure
      scanner.close
    end
  end
end
