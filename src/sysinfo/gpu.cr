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
#   Intel  — Level Zero Sysman (libze_loader.so.1 / ze_loader.dll,
#            runtime-loaded like NVML) on Linux and Windows. VRAM and
#            temperature are point-in-time reads; engine load and power
#            are counters, so they are computed between two
#            refresh_gpus calls (nil right after the first one).
#   Other  — no GPUs reported (macOS).

module Sysinfo
  # One GPU's readings; anything that cannot be read is nil, and no
  # read here can raise into the caller.
  struct Gpu
    getter vendor : Symbol # :nvidia, :amd or :intel
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

    # Level Zero Sysman (the Intel GPU API behind oneAPI, used by
    # intel_gpu_top-class tooling) struct layouts, transcribed from the
    # v1.24 spec headers (ze_api.h / zes_api.h). Only the fields that
    # are read live here; ze_result_t: 0 = success.
    lib LibZes
      struct ZeDeviceProperties
        stype : UInt32
        p_next : Void*
        type : UInt32
        vendor_id : UInt32
        device_id : UInt32
        flags : UInt32
        subdevice_id : UInt32
        core_clock_rate : UInt32
        max_mem_alloc_size : UInt64
        max_hardware_contexts : UInt32
        max_command_queue_priority : UInt32
        num_threads_per_eu : UInt32
        physical_eu_simd_width : UInt32
        num_eus_per_subslice : UInt32
        num_subslices_per_slice : UInt32
        num_slices : UInt32
        timer_resolution : UInt64
        timestamp_valid_bits : UInt32
        kernel_timestamp_valid_bits : UInt32
        uuid : UInt8[16]
        name : UInt8[256]
      end

      struct ZesDeviceProperties
        stype : UInt32
        p_next : Void*
        core : ZeDeviceProperties
        num_subdevices : UInt32
        serial_number : UInt8[64]
        board_number : UInt8[64]
        brand_name : UInt8[64]
        model_name : UInt8[64]
        vendor_name : UInt8[64]
        driver_version : UInt8[64]
      end

      struct ZesMemState
        stype : UInt32
        p_next : Void*
        health : Int32
        free : UInt64
        size : UInt64
      end

      struct ZesEngineStats
        active_time : UInt64
        timestamp : UInt64
      end

      # ZES_TEMP_SENSORS_GPU
      TEMP_SENSOR_GPU = 1

      struct ZesTempProperties
        stype : UInt32
        p_next : Void*
        type : Int32
        on_subdevice : UInt32
        subdevice_id : UInt32
        max_temperature : Float64
        is_critical_temp_supported : UInt32
        is_threshold1_supported : UInt32
        is_threshold2_supported : UInt32
      end

      struct ZesPowerProperties
        stype : UInt32
        p_next : Void*
        on_subdevice : UInt32
        subdevice_id : UInt32
        can_control : UInt32
        is_energy_threshold_supported : UInt32
        default_limit : Int32
        min_limit : Int32
        max_limit : Int32
      end

      struct ZesEnergyCounter
        energy : UInt64
        timestamp : UInt64
      end
    end

    # Intel GPUs through Level Zero Sysman, loaded at runtime like
    # NVML: the loader library ships with the driver (Windows) or the
    # intel-level-zero-gpu package (Linux) and is never a link-time
    # dependency. Engine activity and energy counters are monotonic,
    # so the previous snapshot is kept per handle and utilization /
    # power are the deltas since the previous read_all.
    class Zes
      ZES_LIBRARIES = {% if flag?(:windows) %}
                        ["ze_loader.dll"] of String
                      {% else %}
                        ["libze_loader.so.1", "libze_loader.so"] of String
                      {% end %}

      @handles = [] of Void*
      @last_engine = {} of Void* => LibZes::ZesEngineStats
      @last_energy = {} of Void* => LibZes::ZesEnergyCounter

      @device_get : Proc(Void*, Pointer(UInt32), Pointer(Void*), UInt32)? = nil
      @device_props : Proc(Void*, Pointer(LibZes::ZesDeviceProperties), UInt32)? = nil
      @enum_memory : Proc(Void*, Pointer(UInt32), Pointer(Void*), UInt32)? = nil
      @mem_state : Proc(Void*, Pointer(LibZes::ZesMemState), UInt32)? = nil
      @enum_engines : Proc(Void*, Pointer(UInt32), Pointer(Void*), UInt32)? = nil
      @engine_activity : Proc(Void*, Pointer(LibZes::ZesEngineStats), UInt32)? = nil
      @enum_temp : Proc(Void*, Pointer(UInt32), Pointer(Void*), UInt32)? = nil
      @temp_props : Proc(Void*, Pointer(LibZes::ZesTempProperties), UInt32)? = nil
      @temp_state : Proc(Void*, Pointer(Float64), UInt32)? = nil
      @enum_power : Proc(Void*, Pointer(UInt32), Pointer(Void*), UInt32)? = nil
      @energy_counter : Proc(Void*, Pointer(LibZes::ZesEnergyCounter), UInt32)? = nil
      @power_props : Proc(Void*, Pointer(LibZes::ZesPowerProperties), UInt32)? = nil

      def initialize
        handle_lib = Sysinfo.open_dynamic_library(ZES_LIBRARIES)
        return unless handle_lib

        if ptr = Sysinfo.dynamic_symbol(handle_lib, "zesInit")
          return unless Proc(UInt32, UInt32).new(ptr, Pointer(Void).null).call(0_u32) == 0
        end

        if ptr = Sysinfo.dynamic_symbol(handle_lib, "zesDeviceGet")
          @device_get = Proc(Void*, Pointer(UInt32), Pointer(Void*), UInt32).new(ptr, Pointer(Void).null)
        end
        if ptr = Sysinfo.dynamic_symbol(handle_lib, "zesDriverGet")
          @handles = drivers(Proc(Pointer(UInt32), Pointer(Void*), UInt32).new(ptr, Pointer(Void).null))
        end

        if ptr = Sysinfo.dynamic_symbol(handle_lib, "zesDeviceGetProperties")
          @device_props = Proc(Void*, Pointer(LibZes::ZesDeviceProperties), UInt32).new(ptr, Pointer(Void).null)
        end
        if ptr = Sysinfo.dynamic_symbol(handle_lib, "zesDeviceEnumMemoryModules")
          @enum_memory = Proc(Void*, Pointer(UInt32), Pointer(Void*), UInt32).new(ptr, Pointer(Void).null)
        end
        if ptr = Sysinfo.dynamic_symbol(handle_lib, "zesMemoryGetState")
          @mem_state = Proc(Void*, Pointer(LibZes::ZesMemState), UInt32).new(ptr, Pointer(Void).null)
        end
        if ptr = Sysinfo.dynamic_symbol(handle_lib, "zesDeviceEnumEngineGroups")
          @enum_engines = Proc(Void*, Pointer(UInt32), Pointer(Void*), UInt32).new(ptr, Pointer(Void).null)
        end
        if ptr = Sysinfo.dynamic_symbol(handle_lib, "zesEngineGetActivity")
          @engine_activity = Proc(Void*, Pointer(LibZes::ZesEngineStats), UInt32).new(ptr, Pointer(Void).null)
        end
        if ptr = Sysinfo.dynamic_symbol(handle_lib, "zesDeviceEnumTemperatureSensors")
          @enum_temp = Proc(Void*, Pointer(UInt32), Pointer(Void*), UInt32).new(ptr, Pointer(Void).null)
        end
        if ptr = Sysinfo.dynamic_symbol(handle_lib, "zesTemperatureGetProperties")
          @temp_props = Proc(Void*, Pointer(LibZes::ZesTempProperties), UInt32).new(ptr, Pointer(Void).null)
        end
        if ptr = Sysinfo.dynamic_symbol(handle_lib, "zesTemperatureGetState")
          @temp_state = Proc(Void*, Pointer(Float64), UInt32).new(ptr, Pointer(Void).null)
        end
        if ptr = Sysinfo.dynamic_symbol(handle_lib, "zesDeviceEnumPowerDomains")
          @enum_power = Proc(Void*, Pointer(UInt32), Pointer(Void*), UInt32).new(ptr, Pointer(Void).null)
        end
        if ptr = Sysinfo.dynamic_symbol(handle_lib, "zesPowerGetEnergyCounter")
          @energy_counter = Proc(Void*, Pointer(LibZes::ZesEnergyCounter), UInt32).new(ptr, Pointer(Void).null)
        end
        if ptr = Sysinfo.dynamic_symbol(handle_lib, "zesPowerGetProperties")
          @power_props = Proc(Void*, Pointer(LibZes::ZesPowerProperties), UInt32).new(ptr, Pointer(Void).null)
        end
      end

      def read_all : Array(Gpu)
        @handles.map { |handle| read(handle) }
      end

      # Utilization between two engine-activity snapshots, each an
      # (activeTime, timestamp) pair of nanosecond counters; nil when
      # the timestamps are too close to divide.
      def self.delta_percent(prev_active : UInt64, prev_stamp : UInt64,
                             cur_active : UInt64, cur_stamp : UInt64) : Int32?
        # A counter that went backwards was reset (driver reinit):
        # nothing was measured since, so the load is zero.
        return 0 if cur_stamp < prev_stamp || cur_active < prev_active
        span = cur_stamp - prev_stamp
        return nil if span == 0
        active = cur_active - prev_active
        ((active.to_f / span.to_f) * 100.0).round.clamp(0.0, 100.0).to_i32
      end

      private def read(handle : Void*) : Gpu
        name = read_name(handle)
        util = read_util(handle)
        used_kb, total_kb = read_memory(handle)
        temp = read_temp(handle)
        power, power_limit = read_power(handle)
        Gpu.new(:intel, name, util, used_kb, total_kb, temp, power, power_limit)
      end

      private def read_name(handle : Void*) : String?
        return nil unless fn = @device_props
        props = LibZes::ZesDeviceProperties.new
        return nil unless fn.call(handle, pointerof(props)) == 0
        name = cstr(props.core.name.to_slice)
        name = cstr(props.brand_name.to_slice) if name.empty?
        name = cstr(props.model_name.to_slice) if name.empty?
        name.empty? || name == "unknown" ? nil : name
      end

      # VRAM: every memory module's state, summed. On integrated
      # GPUs this is the shared-memory budget the driver exposes to
      # Level Zero, not dedicated chips.
      private def read_memory(handle : Void*) : {Int64?, Int64?}
        return {nil, nil} unless enum_fn = @enum_memory
        return {nil, nil} unless state_fn = @mem_state
        total = used = 0_u64
        any = false
        enum_handles(enum_fn, handle).each do |mem|
          state = LibZes::ZesMemState.new
          next unless state_fn.call(mem, pointerof(state)) == 0
          total &+= state.size
          used &+= state.size >= state.free ? state.size - state.free : 0_u64
          any = true
        end
        any ? {(used // 1024).to_i64, (total // 1024).to_i64} : {nil, nil}
      end

      # Load: the busiest engine group's active-time share since the
      # previous read_all (nil on the first one).
      private def read_util(handle : Void*) : Int32?
        return nil unless enum_fn = @enum_engines
        return nil unless activity_fn = @engine_activity
        best = nil
        enum_handles(enum_fn, handle).each do |engine|
          stats = LibZes::ZesEngineStats.new
          next unless activity_fn.call(engine, pointerof(stats)) == 0
          if prev = @last_engine[engine]?
            if percent = Zes.delta_percent(prev.active_time, prev.timestamp,
              stats.active_time, stats.timestamp)
              best = percent if best.nil? || percent > best
            end
          end
          @last_engine[engine] = stats
        end
        best
      end

      # Temperature: the GPU sensor when the driver distinguishes
      # sensors, otherwise the first one.
      private def read_temp(handle : Void*) : Int32?
        return nil unless enum_fn = @enum_temp
        return nil unless state_fn = @temp_state
        sensors = enum_handles(enum_fn, handle)
        return nil if sensors.empty?
        chosen = sensors.first
        if props_fn = @temp_props
          sensors.each do |sensor|
            props = LibZes::ZesTempProperties.new
            if props_fn.call(sensor, pointerof(props)) == 0 &&
               props.type == LibZes::TEMP_SENSOR_GPU
              chosen = sensor
              break
            end
          end
        end
        value = 0.0
        return nil unless state_fn.call(chosen, pointerof(value)) == 0
        value.round.to_i32
      end

      # Power: the card-level energy counter (µJ over µs) between two
      # read_all calls; the limit is the factory default TDP. The
      # first power domain stands for the whole card.
      private def read_power(handle : Void*) : {Float64?, Float64?}
        return {nil, nil} unless enum_fn = @enum_power
        power = power_limit = nil
        enum_handles(enum_fn, handle).first?.try do |domain|
          if counter_fn = @energy_counter
            counter = LibZes::ZesEnergyCounter.new
            if counter_fn.call(domain, pointerof(counter)) == 0
              if prev = @last_energy[domain]?
                span = counter.timestamp &- prev.timestamp
                energy = counter.energy &- prev.energy
                power = energy.to_f64 / span.to_f64 if span > 0 # µJ/µs = W
              end
              @last_energy[domain] = counter
            end
          end
          if props_fn = @power_props
            props = LibZes::ZesPowerProperties.new
            if props_fn.call(domain, pointerof(props)) == 0 && props.default_limit > 0
              power_limit = props.default_limit / 1000.0
            end
          end
        end
        {power, power_limit}
      end

      private def cstr(bytes : Bytes) : String
        length = bytes.index(0_u8) || bytes.size
        String.new(bytes[0, length])
      end

      # The count-then-fill pattern every zes*Enum uses.
      private def enum_handles(fn : Proc(Void*, Pointer(UInt32), Pointer(Void*), UInt32),
                               handle : Void*) : Array(Void*)
        count = 0_u32
        return [] of Void* unless fn.call(handle, pointerof(count), Pointer(Void*).null) == 0
        return [] of Void* if count == 0
        handles = Pointer(Void*).malloc(count)
        return [] of Void* unless fn.call(handle, pointerof(count), handles) == 0
        handles.to_slice(count).to_a
      end

      private def drivers(fn : Proc(Pointer(UInt32), Pointer(Void*), UInt32)) : Array(Void*)
        count = 0_u32
        return [] of Void* unless fn.call(pointerof(count), Pointer(Void*).null) == 0
        return [] of Void* if count == 0
        handles = Pointer(Void*).malloc(count)
        return [] of Void* unless fn.call(pointerof(count), handles) == 0

        devices = [] of Void*
        if device_fn = @device_get
          handles.to_slice(count).each do |driver|
            devices.concat(enum_handles(device_fn, driver))
          end
        end
        devices
      end
    end

    @@zes : Zes? = nil

    # The Intel GPUs' readings; initialized once like the NVML reader,
    # and absent Level Zero reports nothing (machines without the
    # runtime, or macOS).
    def self.zes_gpus : Array(Gpu)
      @@zes ||= Zes.new
      @@zes.not_nil!.read_all
    end
  end
{% end %}
