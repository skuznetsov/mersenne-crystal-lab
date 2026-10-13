require "atomic"
require "big"
require "channel"
require "fiber/execution_context"
require "sync/mutex"
require "wait_group"
require "./prepared_sieve"
require "./jabari_adapters"
require "./schedules"

module MersenneLab
  # A reusable fixed-size worker pool for the direct Mersenne GMP screener.
  # Every worker owns one isolated system thread and creates its own BigInts;
  # callers share only immutable job inputs and disjoint result indexes.
  class ParallelMersenne
    MAX_WORKERS    =    64
    MAX_CHUNK_SIZE = 4_096

    private class Job
      getter cursor : Atomic(Int32)
      getter states : Array(UInt8)
      getter witnesses : Array(UInt32)?
      getter start_exponent : UInt32
      getter prime_screen_count : Atomic(UInt64)
      getter exception : Atomic(Exception?)
      getter completions : WaitGroup

      def initialize(
        @start_exponent : UInt32,
        count : Int32,
        @states : Array(UInt8),
        @witnesses : Array(UInt32)?,
        worker_count : Int32,
      )
        @cursor = Atomic(Int32).new(count)
        @prime_screen_count = Atomic(UInt64).new(0_u64)
        @exception = Atomic(Exception?).new(nil)
        @completions = WaitGroup.new(worker_count)
      end

      # Claims non-overlapping ranges from the high end so workers start with
      # the most expensive exponents and leave smaller candidates for later.
      def claim(chunk_size : Int32) : Tuple(Int32, Int32)?
        loop do
          upper = @cursor.get(:relaxed)
          return nil if upper == 0

          lower = Math.max(0, upper - chunk_size)
          _, claimed = @cursor.compare_and_set(upper, lower, :acquire_release, :relaxed)
          return {lower, upper} if claimed
        end
      end

      def record_exception(exception : Exception) : Nil
        @exception.compare_and_set(nil, exception, :release, :relaxed)
        nil
      end
    end

    @mutex : Sync::Mutex
    @worker_count : Int32
    @chunk_size : Int32
    @channels : Array(Channel(Job?))
    @workers : Array(Fiber::ExecutionContext::Isolated)
    @closed : Bool

    # Creates a reusable pool with one dedicated isolated execution context per
    # worker. Calls and shutdown are serialized; witness arrays are copied
    # before they are handed to worker threads.
    def initialize(workers : Int32, chunk_size : Int32 = 1)
      if workers < 1 || workers > MAX_WORKERS
        raise ArgumentError.new("worker count must be from 1 through #{MAX_WORKERS}")
      end
      if chunk_size < 1 || chunk_size > MAX_CHUNK_SIZE
        raise ArgumentError.new("chunk size must be from 1 through #{MAX_CHUNK_SIZE}")
      end

      @worker_count = workers
      @chunk_size = chunk_size
      @mutex = Sync::Mutex.new
      @channels = [] of Channel(Job?)
      @workers = [] of Fiber::ExecutionContext::Isolated
      @closed = false

      start_workers(workers)
    end

    private def start_workers(workers : Int32) : Nil
      workers.times do |index|
        channel = Channel(Job?).new
        worker = start_worker(index, channel)
        @channels << channel
        @workers << worker
      end
      nil
    rescue exception
      stop_started_workers
      raise exception
    end

    private def start_worker(index : Int32, channel : Channel(Job?)) : Fiber::ExecutionContext::Isolated
      Fiber::ExecutionContext::Isolated.new("mersenne-gmp-#{index}") do
        worker_loop(channel)
      end
    end

    # Screens every direct Mersenne candidate in the checked odd-exponent
    # window with GMP's same probable-prime test as JabariAdapters.
    def baseline_mersenne(start_exponent : UInt32, count : Int32) : JabariAdapters::Result
      @mutex.synchronize do
        ensure_open!
        validate_mersenne_window!(start_exponent, count)
        states = Array(UInt8).new(count, JabariAdapters::COMPOSITE)
        run_job(start_exponent, states, nil)
      end
    end

    # Skips candidates with a nonzero known-divisor witness and GMP-screens
    # only unresolved candidates. The input is snapshotted once; callers must
    # not mutate it while this copy is being made.
    def screen_mersenne(start_exponent : UInt32, witnesses : Array(UInt32)) : JabariAdapters::Result
      @mutex.synchronize do
        ensure_open!
        validate_mersenne_window!(start_exponent, witnesses.size)
        snapshot = witnesses.dup
        states = Array(UInt8).new(snapshot.size, JabariAdapters::COMPOSITE)
        run_job(start_exponent, states, snapshot)
      end
    end

    # Stops all workers and waits for their isolated fibers to terminate.
    # Repeated calls are safe.
    def close : Nil
      @mutex.synchronize do
        return nil if @closed
        @closed = true

        @channels.each { |channel| channel.send(nil) }

        first_exception : Exception? = nil
        @workers.each do |worker|
          begin
            worker.wait
          rescue exception
            first_exception ||= exception
          end
        end

        raise first_exception if first_exception
      end
      nil
    end

    # Kept protected so specs or a specialized subclass can inject a worker
    # failure without exposing a checker callback in the public constructor.
    protected def probable_prime?(candidate : BigInt) : Bool
      Schedules.gmp_probable_prime?(candidate)
    end

    private def run_job(
      start_exponent : UInt32,
      states : Array(UInt8),
      witnesses : Array(UInt32)?,
    ) : JabariAdapters::Result
      job = Job.new(start_exponent, states.size, states, witnesses, @worker_count)
      @channels.each { |channel| channel.send(job) }
      job.completions.wait
      if worker_error = job.exception.get(:acquire)
        raise worker_error
      end

      JabariAdapters::Result.new(states, job.prime_screen_count.get(:acquire))
    end

    private def worker_loop(channel : Channel(Job?)) : Nil
      loop do
        job = channel.receive
        break unless job

        begin
          process_job(job)
        rescue exception
          job.record_exception(exception)
        ensure
          job.completions.done
        end
      end
      nil
    end

    private def process_job(job : Job) : Nil
      while chunk = job.claim(@chunk_size)
        lower, upper = chunk
        index = upper - 1
        while index >= lower
          if witnesses = job.witnesses
            if witnesses[index] != 0
              job.states[index] = JabariAdapters::COMPOSITE
              index -= 1
              next
            end
          end

          exponent = job.start_exponent.to_u64 + 2_u64 * index.to_u64
          candidate = (BigInt.new(1) << exponent.to_i) - 1
          job.prime_screen_count.add(1_u64, :relaxed)
          if probable_prime?(candidate)
            job.states[index] = JabariAdapters::PROBABLE_PRIME_MERSENNE
          else
            job.states[index] = JabariAdapters::COMPOSITE
          end
          index -= 1
        end
      end
      nil
    end

    private def ensure_open! : Nil
      raise RuntimeError.new("ParallelMersenne is closed") if @closed
      nil
    end

    private def validate_mersenne_window!(start_exponent : UInt32, count : Int32) : Nil
      if start_exponent < 17_u32 || start_exponent > JabariAdapters::MAX_MERSENNE_EXPONENT || start_exponent.even?
        raise ArgumentError.new(
          "Mersenne start exponent must be odd and from 17 through #{JabariAdapters::MAX_MERSENNE_EXPONENT}"
        )
      end
      raise ArgumentError.new("window count must be nonnegative") if count < 0
      if count > SievePlan::MAX_WINDOW_COUNT
        raise ArgumentError.new("window count exceeds #{SievePlan::MAX_WINDOW_COUNT}")
      end

      if count > 0
        last_exponent = start_exponent.to_u64 + 2_u64 * (count - 1).to_u64
        if last_exponent > JabariAdapters::MAX_MERSENNE_EXPONENT.to_u64
          raise ArgumentError.new(
            "Mersenne window exceeds exponent #{JabariAdapters::MAX_MERSENNE_EXPONENT}"
          )
        end
      end
      nil
    end

    private def stop_started_workers : Nil
      @channels.each { |channel| channel.send(nil) }
      @workers.each(&.wait)
      nil
    end
  end
end
