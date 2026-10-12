require "./core"
require "../../Crystal/cogni-ml/src/ml/cuda/driver"

lib LibCUDADriver
  fun cuCtxGetCurrent(context : Void**) : Int32
  fun cuCtxPushCurrent_v2(context : Void*) : Int32
  fun cuCtxPopCurrent_v2(context : Void**) : Int32
end

module MersenneLab
  # CUDA implementation of the modular sieve. A zero result means that none
  # of the supplied trial primes divided the candidate; it does not establish
  # primality.
  class CUDASieve
    BLOCK_SIZE = 256_u32
    PTX        = {{ read_file("#{__DIR__}/kernels/mpgs_sieve.ptx") }}

    @context : ML::CUDA::Context
    @context_handle : Void*
    @cuda_module : ML::CUDA::CUDAModule
    @function : ML::CUDA::KernelFunction
    @mutex : Mutex

    def initialize
      @mutex = Mutex.new
      context = ML::CUDA::Context.create
      context_handle = Pointer(Void).null
      cuda_module = nil.as(ML::CUDA::CUDAModule?)
      function = nil.as(ML::CUDA::KernelFunction?)

      begin
        ML::CUDA.check! LibCUDADriver.cuCtxGetCurrent(pointerof(context_handle)), "cuCtxGetCurrent"
        raise "CUDA context creation did not make its context current" if context_handle.null?

        cuda_module = ML::CUDA::CUDAModule.load(PTX, "mpgs_sieve")
        function = cuda_module.not_nil!.function("mpgs_sieve")

        popped_context = Pointer(Void).null
        ML::CUDA.check! LibCUDADriver.cuCtxPopCurrent_v2(pointerof(popped_context)), "cuCtxPopCurrent"
        raise "CUDA context stack changed during sieve initialization" unless popped_context == context_handle
      rescue error
        begin
          if context_handle.null?
            # The wrapper still owns the handle when current-context capture
            # itself failed, so use its best-effort cleanup in that case.
            context.close
          else
            # Destroying the context releases any module loaded into it and
            # pops it if still current, restoring the caller's prior context.
            ML::CUDA.check! LibCUDADriver.cuCtxDestroy_v2(context_handle), "cuCtxDestroy"
          end
        rescue cleanup_error
          raise "#{error.message}; CUDA context destruction also failed: #{cleanup_error.message}"
        end
        raise error
      end

      @context = context
      @context_handle = context_handle
      @cuda_module = cuda_module.not_nil!
      @function = function.not_nil!
      @closed = false
    end

    def close : Nil
      @mutex.synchronize do
        next if @closed

        operation_error = nil.as(Exception?)
        begin
          with_context { @cuda_module.close }
        rescue error
          operation_error = error
        end

        begin
          # Destruction also releases module resources if explicit unload
          # failed, and runs after with_context restores the caller's context.
          ML::CUDA.check! LibCUDADriver.cuCtxDestroy_v2(@context_handle), "cuCtxDestroy"
        rescue destroy_error
          if operation_error
            raise "#{operation_error.not_nil!.message}; CUDA context destruction also failed: #{destroy_error.message}"
          end
          raise destroy_error
        end

        @closed = true
        raise operation_error.not_nil! if operation_error
      end
    end

    def sieve(exponent : UInt32, ks : Array(UInt64), primes : Array(UInt32)) : Array(UInt32)
      @mutex.synchronize do
        raise "CUDA sieve is closed" if @closed

        with_context do
          MersenneLab.validate_inputs!(exponent, ks, primes)
          raise ArgumentError.new("CUDA sieve requires exponent >= 15") if exponent < 15_u32

          next [] of UInt32 if ks.empty?
          next Array(UInt32).new(ks.size, 0_u32) if primes.empty?

          results = Array(UInt32).new(ks.size, UInt32::MAX)

          powers = primes.map { |prime| MersenneLab.pow2_mod(exponent, prime).to_u32 }
          count = ks.size.to_u32
          factor_count = primes.size.to_u32

          buffers = [] of ML::CUDA::DeviceBuffer

          begin
            ks_device = allocate_buffer(buffers, ks.size.to_u64 * sizeof(UInt64).to_u64)
            primes_device = allocate_buffer(buffers, primes.size.to_u64 * sizeof(UInt32).to_u64)
            powers_device = allocate_buffer(buffers, powers.size.to_u64 * sizeof(UInt32).to_u64)
            results_device = allocate_buffer(buffers, results.size.to_u64 * sizeof(UInt32).to_u64)

            ML::CUDA.copy_htod!(ks_device.ptr, ks.to_unsafe.as(Void*), ks_device.bytesize, "MPGS k values")
            ML::CUDA.copy_htod!(primes_device.ptr, primes.to_unsafe.as(Void*), primes_device.bytesize, "MPGS trial primes")
            ML::CUDA.copy_htod!(powers_device.ptr, powers.to_unsafe.as(Void*), powers_device.bytesize, "MPGS powers modulo primes")
            ML::CUDA.copy_htod!(results_device.ptr, results.to_unsafe.as(Void*), results_device.bytesize, "MPGS output sentinel")

            # The driver expects a pointer to host storage for each kernel argument.
            # Keep these scalar slots alive through launch and synchronization.
            ks_arg = ks_device.ptr
            primes_arg = primes_device.ptr
            powers_arg = powers_device.ptr
            results_arg = results_device.ptr
            count_arg = count
            factor_count_arg = factor_count
            params = Pointer(Void*).malloc(6)
            params[0] = pointerof(ks_arg).as(Void*)
            params[1] = pointerof(primes_arg).as(Void*)
            params[2] = pointerof(powers_arg).as(Void*)
            params[3] = pointerof(results_arg).as(Void*)
            params[4] = pointerof(count_arg).as(Void*)
            params[5] = pointerof(factor_count_arg).as(Void*)

            grid_x = ((count.to_u64 + BLOCK_SIZE.to_u64 - 1_u64) // BLOCK_SIZE.to_u64).to_u32
            ML::CUDA.check! LibCUDADriver.cuLaunchKernel(
              @function.handle, grid_x, 1_u32, 1_u32,
              BLOCK_SIZE, 1_u32, 1_u32, 0_u32, Pointer(Void).null,
              params, Pointer(Void*).null
            ), "cuLaunchKernel(MPGS modular sieve)"
            ML::CUDA.synchronize!("MPGS modular sieve")
            ML::CUDA.copy_dtoh!(results.to_unsafe.as(Void*), results_device.ptr, results_device.bytesize, "MPGS factors")
            raise "CUDA sieve did not write every candidate result" if results.any? { |factor| factor == UInt32::MAX }

            results
          ensure
            buffers.reverse_each(&.close)
          end
        end
      end
    end

    private def with_context(&block : -> T) : T forall T
      ML::CUDA.check! LibCUDADriver.cuCtxPushCurrent_v2(@context_handle), "cuCtxPushCurrent"

      begin
        block.call
      ensure
        popped_context = Pointer(Void).null
        ML::CUDA.check! LibCUDADriver.cuCtxPopCurrent_v2(pointerof(popped_context)), "cuCtxPopCurrent"
        raise "CUDA context stack changed during sieve operation" unless popped_context == @context_handle
      end
    end

    private def allocate_buffer(buffers : Array(ML::CUDA::DeviceBuffer), bytesize : UInt64) : ML::CUDA::DeviceBuffer
      buffer = ML::CUDA::DeviceBuffer.new(bytesize)
      buffers << buffer
      buffer
    end
  end
end
