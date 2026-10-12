require "./prepared_sieve"
require "./exponent_sieve"
require "../../Crystal/cogni-ml/src/ml/metal/dispatch"

module MersenneLab
  class MetalSieve
    SOURCE        = {{ read_file("#{__DIR__}/kernels/mpgs_sieve.metal") }}
    WINDOW_SOURCE = {{ read_file("#{__DIR__}/kernels/mpgs_window.metal") }}

    # The current cogni-ml bridge retains pipelines without exposing release.
    # Keep exactly these two pipelines for process lifetime, rather than
    # compiling and retaining two more on every backend construction.
    @@pipeline_lock = Mutex.new
    @@candidate_pipeline : ML::Metal::ComputePipeline? = nil
    @@cached_window_pipeline : ML::Metal::ComputePipeline? = nil

    @pipeline : ML::Metal::ComputePipeline
    @window_pipeline : ML::Metal::ComputePipeline? = nil
    @mutex = Mutex.new
    @closed = false

    def initialize
      @pipeline = @@pipeline_lock.synchronize do
        raise "Metal device unavailable" unless ML::Metal::Device.init!
        @@candidate_pipeline ||= ML::Metal::ComputePipeline.new("mpgs_sieve", SOURCE)
      end
    end

    def sieve(exponent : UInt32, ks : Array(UInt64), primes : Array(UInt32)) : Array(UInt32)
      @mutex.synchronize { sieve_unlocked(exponent, ks, primes) }
    end

    private def sieve_unlocked(exponent : UInt32, ks : Array(UInt64), primes : Array(UInt32)) : Array(UInt32)
      raise "Metal sieve is closed" if @closed
      MersenneLab.validate_inputs!(exponent, ks, primes)
      raise ArgumentError.new("GPU sieve requires m >= 15; smaller candidates need a proper-divisor guard") if exponent < 15
      return [] of UInt32 if ks.empty?
      return Array(UInt32).new(ks.size, 0_u32) if primes.empty?

      powers = primes.map { |d| MersenneLab.pow2_mod(exponent, d) }
      results = Array(UInt32).new(ks.size, UInt32::MAX)
      buffers = [] of ML::MetalBuffer
      begin
        k_buffer = ML::MetalBuffer.new(ks.size.to_i64 * sizeof(UInt64))
        buffers << k_buffer
        d_buffer = ML::MetalBuffer.new(primes.size.to_i64 * sizeof(UInt32))
        buffers << d_buffer
        p_buffer = ML::MetalBuffer.new(powers.size.to_i64 * sizeof(UInt32))
        buffers << p_buffer
        out_buffer = ML::MetalBuffer.new(results.size.to_i64 * sizeof(UInt32))
        buffers << out_buffer
        k_buffer.write_bytes(ks.to_unsafe.as(UInt8*), ks.size.to_i64 * sizeof(UInt64))
        d_buffer.write_bytes(primes.to_unsafe.as(UInt8*), primes.size.to_i64 * sizeof(UInt32))
        p_buffer.write_bytes(powers.to_unsafe.as(UInt8*), powers.size.to_i64 * sizeof(UInt32))
        out_buffer.write_bytes(results.to_unsafe.as(UInt8*), results.size.to_i64 * sizeof(UInt32))

        ML::Metal::Dispatch.execute(@pipeline) do |encoder|
          encoder.set_buffer(k_buffer, 0)
          encoder.set_buffer(d_buffer, 1)
          encoder.set_buffer(p_buffer, 2)
          encoder.set_buffer(out_buffer, 3, access: ML::Metal::BufferAccess::Write)
          encoder.set_value(ks.size.to_u32, 4)
          encoder.set_value(primes.size.to_u32, 5)
          encoder.dispatch_1d(ks.size, 128)
        end
        out_buffer.read_bytes(results.to_unsafe.as(UInt8*), results.size.to_i64 * sizeof(UInt32))
        raise "Metal sieve did not write every candidate result" if results.any? { |factor| factor == UInt32::MAX }
        results
      ensure
        buffers.each(&.release)
      end
    end

    # Full-call convenience API; plan preparation is included in its cost.
    def sieve_odd_window(exponent : UInt32, start : UInt64, count : Int32,
                         primes : Array(UInt32), tile_size : Int32 = 1024) : Array(UInt32)
      sieve_odd_window(SievePlan.new(exponent, primes), start, count, tile_size)
    end

    # A prepared plan amortizes prime validation and modular inversion across
    # windows. Allocation, transfers, dispatch, synchronization and readback
    # still occur in every call. No automatic CPU/GPU performance policy.
    def sieve_odd_window(plan : SievePlan, start : UInt64, count : Int32,
                         tile_size : Int32 = 1024) : Array(UInt32)
      @mutex.synchronize do
        raise "Metal sieve is closed" if @closed
        raise ArgumentError.new("GPU window sieve requires exponent >= 15") if plan.exponent < 15
        raise ArgumentError.new("tile size must be in 1..65536") unless 1 <= tile_size <= 65536
        offsets = plan.window_offsets(start, count)
        return [] of UInt32 if count == 0
        return Array(UInt32).new(count, 0_u32) if plan.prime_count == 0

        primes = plan.primes
        # An even exponent makes 3 divide every candidate. A first-ranked 3
        # resolves the window on the host. Otherwise seed that rank and launch
        # only earlier factors, which alone can improve witness precedence.
        three_rank = plan.exponent.even? ? primes.index(3_u32) : nil
        return Array(UInt32).new(count, 3_u32) if three_rank == 0
        active_count = three_rank || primes.size
        initial_rank = three_rank ? three_rank.to_u32 : UInt32::MAX
        tile_count = (count.to_u64 + tile_size.to_u64 - 1) // tile_size.to_u64
        jobs = tile_count * active_count.to_u64
        raise ArgumentError.new("factor/tile grid exceeds Int32 dispatch bound") if jobs > Int32::MAX.to_u64
        strides = plan.strides
        ranks = Array(UInt32).new(count, initial_rank)
        pipeline = window_pipeline
        buffers = [] of ML::MetalBuffer
        begin
          offsets_buffer = upload(buffers, offsets)
          strides_buffer = upload(buffers, strides)
          out_buffer = upload(buffers, ranks)
          ML::Metal::Dispatch.execute(pipeline) do |encoder|
            encoder.set_buffer(offsets_buffer, 0)
            encoder.set_buffer(strides_buffer, 1)
            encoder.set_buffer(out_buffer, 2, access: ML::Metal::BufferAccess::ReadWrite)
            encoder.set_value(count.to_u32, 3)
            encoder.set_value(active_count.to_u32, 4)
            encoder.set_value(tile_size.to_u32, 5)
            encoder.set_value(tile_count.to_u32, 6)
            encoder.dispatch_1d(jobs.to_i32, 128)
          end
          out_buffer.read_bytes(ranks.to_unsafe.as(UInt8*), count.to_i64 * sizeof(UInt32))
          ranks.map! do |rank|
            if rank == UInt32::MAX
              0_u32
            else
              raise "Metal window sieve returned an invalid factor rank" if rank >= primes.size.to_u32
              primes[rank.to_i32]
            end
          end
          ranks
        ensure
          buffers.each(&.release)
        end
      end
    end

    # Direct Mersenne exponent windows use exact orders of two as strides.
    # Full calls include preparing orders; prepared calls amortize that work
    # across arbitrary windows without compatible-k materialization/rebasing.
    def sieve_exponents(start : UInt32, count : Int32, primes : Array(UInt32),
                        tile_size : Int32 = 1024) : Array(UInt32)
      sieve_exponents(ExponentSievePlan.new(primes), start, count, tile_size)
    end

    def sieve_exponents(plan : ExponentSievePlan, start : UInt32, count : Int32,
                        tile_size : Int32 = 1024) : Array(UInt32)
      @mutex.synchronize do
        raise "Metal sieve is closed" if @closed
        raise ArgumentError.new("GPU exponent sieve requires start >= 17") if start < 17
        raise ArgumentError.new("tile size must be in 1..65536") unless 1 <= tile_size <= 65536
        offsets = plan.window_offsets(start, count)
        return [] of UInt32 if count == 0
        return Array(UInt32).new(count, 0_u32) if plan.active_count == 0

        tile_count = (count.to_u64 + tile_size.to_u64 - 1) // tile_size.to_u64
        jobs = tile_count * plan.active_count.to_u64
        raise ArgumentError.new("order/tile grid exceeds Int32 dispatch bound") if jobs > Int32::MAX.to_u64
        orders = plan.orders
        factors = plan.active_primes
        pipeline = window_pipeline
        buffers = [] of ML::MetalBuffer
        begin
          offsets_buffer = upload(buffers, offsets)
          strides_buffer = upload(buffers, orders)
          # Shared storage and synchronous dispatch allow initialization and
          # consumption in place. Avoid an upload, readback copy and separate
          # rank-to-factor walk over a large host array.
          out_buffer = ML::MetalBuffer.new(count.to_i64 * sizeof(UInt32), ML::StorageMode::Shared)
          buffers << out_buffer
          ranks = out_buffer.contents.as(UInt32*)
          raise "Metal shared output contents unavailable" if ranks.null?
          Slice(UInt32).new(ranks, count).fill(UInt32::MAX)
          ML::Metal::Dispatch.execute(pipeline) do |encoder|
            encoder.set_buffer(offsets_buffer, 0)
            encoder.set_buffer(strides_buffer, 1)
            encoder.set_buffer(out_buffer, 2, access: ML::Metal::BufferAccess::ReadWrite)
            encoder.set_value(count.to_u32, 3)
            encoder.set_value(plan.active_count.to_u32, 4)
            encoder.set_value(tile_size.to_u32, 5)
            encoder.set_value(tile_count.to_u32, 6)
            encoder.dispatch_1d(jobs.to_i32, 128)
          end
          # Dispatch.execute commits and waits before any CPU reads. Copy the
          # mapped factors into an owned array before releasing this buffer.
          Array(UInt32).new(count) do |index|
            rank = ranks[index]
            if rank == UInt32::MAX
              0_u32
            else
              raise "Metal exponent sieve returned an invalid order rank" if rank >= factors.size.to_u32
              factors[rank.to_i32]
            end
          end
        ensure
          buffers.each(&.release)
        end
      end
    end

    # Compile the experimental window kernel only when it is actually needed.
    # A failure here leaves the existing candidate pipeline usable.
    private def window_pipeline : ML::Metal::ComputePipeline
      @window_pipeline ||= @@pipeline_lock.synchronize do
        @@cached_window_pipeline ||= ML::Metal::ComputePipeline.new("mpgs_window", WINDOW_SOURCE)
      end
    end

    private def upload(buffers : Array(ML::MetalBuffer), values : Array(UInt32)) : ML::MetalBuffer
      bytes = values.size.to_i64 * sizeof(UInt32)
      buffer = ML::MetalBuffer.new(bytes)
      buffers << buffer
      buffer.write_bytes(values.to_unsafe.as(UInt8*), bytes)
      buffer
    end

    def device_name : String
      ML::Metal::Device.instance.name
    end

    def close : Nil
      @mutex.synchronize { @closed = true }
    end
  end
end
