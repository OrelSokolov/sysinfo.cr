# GPU readings — VRAM, load, temperature, power — from the same
# sources Strata's monitor (serve/telemetry.py) uses:
#
#   NVIDIA — NVML, the driver's own library (libnvidia-ml.so.1 /
#            nvml.dll), loaded at runtime through dlopen /
#            LoadLibraryA: no compile-time binding, silently absent on
#            machines without an NVIDIA driver.
#   AMD    — the amdgpu driver's sysfs files on Linux (KFD topology →
#            renderD* device → gpu_busy_percent, mem_info_vram_* and
#            the hwmon sensors); no ROCm library needed. AMD on Windows
#            would need ADL and is not covered.
#   Other  — no GPUs reported (macOS; Intel Arc, whose xe driver only
#            accounts VRAM per-client through root-only fdinfo).

module Sysinfo
  # One GPU's readings; anything that cannot be read is nil, and no
  # read here can raise into the caller.
  struct Gpu
    getter vendor : Symbol # :nvidia or :amd
    getter name : String?
    getter util_percent : Int32?
    getter mem_used_kb : Int64?
    getter mem_total_kb : Int64?
    getter temp_c : Int32?
    getter power_w : Float64?
    getter power_limit_w : Float64?
    getter pcie_gen : Int32?
    getter pcie_width : Int32?

    def initialize(@vendor : Symbol, @name : String? = nil, @util_percent : Int32? = nil,
                   @mem_used_kb : Int64? = nil, @mem_total_kb : Int64? = nil,
                   @temp_c : Int32? = nil, @power_w : Float64? = nil,
                   @power_limit_w : Float64? = nil, @pcie_gen : Int32? = nil,
                   @pcie_width : Int32? = nil)
    end

    # VRAM used percent, nil when used or total is unknown.
    def mem_percent : Int32?
      return nil unless used = @mem_used_kb
      return nil unless total = @mem_total_kb
      return nil if total <= 0
      ((used.to_f / total) * 100.0).round.to_i32.clamp(0, 100)
    end
  end

  # GPU snapshot state; swapped whole by refresh_gpus.
  @@gpus : Array(Gpu) = [] of Gpu

  # Read every supported GPU's current readings and swap the snapshot.
  def self.refresh_gpus : Nil
    @@gpus = platform_gpus
  end

  # The last refresh_gpus snapshot (empty until it ran, on platforms
  # without a backend, or with no supported card).
  def self.gpus : Array(Gpu)
    @@gpus
  end
end

{% if flag?(:linux) || flag?(:windows) %}
  module Sysinfo
    # Runtime library loading for NVML: dlopen on Linux, LoadLibraryA
    # on Windows. NVML ships with the driver and is never a link-time
    # dependency of the program.
    {% if flag?(:windows) %}
      @[Link("kernel32")]
      lib LibDynLoad
        fun load_library_a = LoadLibraryA(name : UInt8*) : Void*
        fun get_proc_address = GetProcAddress(handle : Void*, name : UInt8*) : Void*
      end

      def self.open_dynamic_library(names : Enumerable(String)) : Void*?
        names.each do |name|
          handle = LibDynLoad.load_library_a(name.to_unsafe)
          return handle unless handle.null?
        end
        nil
      end

      def self.dynamic_symbol(handle : Void*, name : String) : Void*?
        symbol = LibDynLoad.get_proc_address(handle, name.to_unsafe)
        symbol.null? ? nil : symbol
      end
    {% else %}
      lib LibDynLoad
        fun dlopen(path : UInt8*, mode : Int32) : Void*
        fun dlsym(handle : Void*, symbol : UInt8*) : Void*
      end

      # dlfcn.h RTLD_NOW: resolve everything now, fail fast
      RTLD_NOW = 2

      def self.open_dynamic_library(names : Enumerable(String)) : Void*?
        names.each do |name|
          handle = LibDynLoad.dlopen(name.to_unsafe, RTLD_NOW)
          return handle unless handle.null?
        end
        nil
      end

      def self.dynamic_symbol(handle : Void*, name : String) : Void*?
        symbol = LibDynLoad.dlsym(handle, name.to_unsafe)
        symbol.null? ? nil : symbol
      end
    {% end %}

    # NVML function pointers resolved once in initialize; values are
    # read through opaque byte buffers with documented offsets (the
    # same trick the darwin backend uses), so no NVML headers are
    # needed. Every NVML call returns nvmlReturn_t; 0 = success.
    class Nvml
      # NVML_TEMPERATURE_GPU (nvml.h)
      TEMPERATURE_GPU = 0_u32

      NVML_LIBRARIES = {% if flag?(:windows) %}
                         ["nvml.dll"] of String
                       {% else %}
                         ["libnvidia-ml.so.1", "libnvidia-ml.so"] of String
                       {% end %}

      @get_name : Proc(Void*, UInt8*, UInt32, UInt32)? = nil
      @get_utilization : Proc(Void*, UInt8*, UInt32)? = nil
      @get_memory : Proc(Void*, UInt8*, UInt32)? = nil
      @get_temp : Proc(Void*, UInt32, UInt32*, UInt32)? = nil
      @get_power : Proc(Void*, UInt32*, UInt32)? = nil
      @get_power_limit : Proc(Void*, UInt32*, UInt32)? = nil
      @get_pcie_gen : Proc(Void*, UInt32*, UInt32)? = nil
      @get_pcie_width : Proc(Void*, UInt32*, UInt32)? = nil

      def initialize
        @lib = Sysinfo.open_dynamic_library(NVML_LIBRARIES)
        @handles = [] of Void*
        return unless handle_lib = @lib

        init = Sysinfo.dynamic_symbol(handle_lib, "nvmlInit_v2") ||
               Sysinfo.dynamic_symbol(handle_lib, "nvmlInit")
        return unless init && Proc(UInt32).new(init, Pointer(Void).null).call == 0

        count = uninitialized UInt32
        get_count = Sysinfo.dynamic_symbol(handle_lib, "nvmlDeviceGetCount_v2") ||
                    Sysinfo.dynamic_symbol(handle_lib, "nvmlDeviceGetCount")
        return unless get_count &&
                      Proc(UInt32*, UInt32).new(get_count, Pointer(Void).null).call(pointerof(count)) == 0

        get_handle = Sysinfo.dynamic_symbol(handle_lib, "nvmlDeviceGetHandleByIndex_v2") ||
                     Sysinfo.dynamic_symbol(handle_lib, "nvmlDeviceGetHandleByIndex")
        return unless get_handle
        handle_fn = Proc(UInt32, Void**, UInt32).new(get_handle, Pointer(Void).null)
        count.times do |i|
          handle = Pointer(Void).null
          @handles << handle if handle_fn.call(i.to_u32!, pointerof(handle)) == 0
        end

        if ptr = Sysinfo.dynamic_symbol(handle_lib, "nvmlDeviceGetName")
          @get_name = Proc(Void*, UInt8*, UInt32, UInt32).new(ptr, Pointer(Void).null)
        end
        # nvmlUtilization_t { UInt32 gpu, memory } — only gpu is used
        if ptr = Sysinfo.dynamic_symbol(handle_lib, "nvmlDeviceGetUtilizationRates")
          @get_utilization = Proc(Void*, UInt8*, UInt32).new(ptr, Pointer(Void).null)
        end
        # nvmlMemory_t { UInt64 total, free, used }
        if ptr = Sysinfo.dynamic_symbol(handle_lib, "nvmlDeviceGetMemoryInfo")
          @get_memory = Proc(Void*, UInt8*, UInt32).new(ptr, Pointer(Void).null)
        end
        # Temperature takes (device, sensor selector, UInt32*); power,
        # power limit and the PCIe link fields take (device, UInt32*).
        if ptr = Sysinfo.dynamic_symbol(handle_lib, "nvmlDeviceGetTemperature")
          @get_temp = Proc(Void*, UInt32, UInt32*, UInt32).new(ptr, Pointer(Void).null)
        end
        if ptr = Sysinfo.dynamic_symbol(handle_lib, "nvmlDeviceGetPowerUsage")
          @get_power = Proc(Void*, UInt32*, UInt32).new(ptr, Pointer(Void).null)
        end
        if ptr = Sysinfo.dynamic_symbol(handle_lib, "nvmlDeviceGetEnforcedPowerLimit")
          @get_power_limit = Proc(Void*, UInt32*, UInt32).new(ptr, Pointer(Void).null)
        end
        if ptr = Sysinfo.dynamic_symbol(handle_lib, "nvmlDeviceGetCurrPcieLinkGeneration")
          @get_pcie_gen = Proc(Void*, UInt32*, UInt32).new(ptr, Pointer(Void).null)
        end
        if ptr = Sysinfo.dynamic_symbol(handle_lib, "nvmlDeviceGetCurrPcieLinkWidth")
          @get_pcie_width = Proc(Void*, UInt32*, UInt32).new(ptr, Pointer(Void).null)
        end
      end

      def read_all : Array(Gpu)
        gpus = [] of Gpu
        @handles.each do |handle|
          gpus << read(handle)
        end
        gpus
      end

      private def read(handle : Void*) : Gpu
        name = nil
        if fn = @get_name
          buffer = StaticArray(UInt8, 96).new(0)
          if fn.call(handle, buffer.to_unsafe, 96_u32) == 0
            name = String.new(buffer.to_unsafe)
          end
        end

        util = nil
        if fn = @get_utilization
          buffer = Bytes.new(8) # nvmlUtilization_t
          if fn.call(handle, buffer.to_unsafe) == 0
            util = IO::ByteFormat::SystemEndian.decode(UInt32, buffer).to_i32
          end
        end

        used_kb = total_kb = nil
        if fn = @get_memory
          buffer = Bytes.new(24) # nvmlMemory_t: total, free, used
          if fn.call(handle, buffer.to_unsafe) == 0
            total_kb = (IO::ByteFormat::SystemEndian.decode(UInt64, buffer[0, 8]) // 1024).to_i64
            used_kb = (IO::ByteFormat::SystemEndian.decode(UInt64, buffer[16, 8]) // 1024).to_i64
          end
        end

        temp = read_sel(handle, @get_temp, TEMPERATURE_GPU)
        power_mw = read_uint(handle, @get_power)
        limit_mw = read_uint(handle, @get_power_limit)
        gen = read_uint(handle, @get_pcie_gen)
        width = read_uint(handle, @get_pcie_width)

        Gpu.new(:nvidia, name, util, used_kb, total_kb,
          temp.try(&.to_i32),
          power_mw.try { |mw| mw / 1000.0 },
          limit_mw.try { |mw| mw / 1000.0 },
          gen.try(&.to_i32), width.try(&.to_i32))
      end

      private def read_uint(handle : Void*, fn : Proc(Void*, UInt32*, UInt32)?) : UInt32?
        return nil unless fn
        value = uninitialized UInt32
        return nil unless fn.call(handle, pointerof(value)) == 0
        value
      end

      private def read_sel(handle : Void*, fn : Proc(Void*, UInt32, UInt32*, UInt32)?,
                           selector : UInt32) : UInt32?
        return nil unless fn
        value = uninitialized UInt32
        return nil unless fn.call(handle, selector, pointerof(value)) == 0
        value
      end
    end

    @@nvml : Nvml? = nil

    # The NVIDIA cards' readings; the NVML reader is initialized once
    # (a failed load is cached too, so machines without an NVIDIA
    # driver do not retry dlopen on every refresh).
    def self.nvml_gpus : Array(Gpu)
      @@nvml ||= Nvml.new
      @@nvml.not_nil!.read_all
    end
  end
{% end %}
