# Linux backend: everything comes from /proc.

{% if flag?(:linux) %}
  module Sysinfo
    def self.platform_memory : Memory?
      total_kb = nil
      available_kb = nil
      File.each_line("/proc/meminfo") do |line|
        kb = line.split[1]?.try &.to_i64?
        if line.starts_with?("MemTotal:")
          total_kb = kb
        elsif line.starts_with?("MemAvailable:")
          available_kb = kb
        end
        break if total_kb && available_kb
      end
      return nil unless (total = total_kb) && (available = available_kb)
      Memory.new(total, available)
    rescue File::NotFoundError
      nil
    end

    def self.platform_refresh_processes : Nil
      processes = [] of Process
      # Top-level /proc/<pid> lists only thread-group leaders, so no
      # thread filtering is needed (threads live under <pid>/task).
      Dir.glob("/proc/[0-9]*").each do |proc_dir|
        pid = File.basename(proc_dir).to_i?
        next unless pid
        ppid = nil
        rss_kb = 0_i64
        File.each_line(File.join(proc_dir, "status")) do |line|
          if line.starts_with?("PPid:")
            ppid = line[5..].strip.to_i?
          elsif line.starts_with?("VmRSS:")
            rss_kb = line[7..].split.first?.try(&.to_i64) || 0_i64
            break
          end
        end
        # PPid 0 = init / kernel thread (kernel threads lack VmRSS and
        # stay at 0 KB anyway).
        processes << Process.new(pid, ppid.try(&.>(0)) ? ppid : nil, rss_kb)
      end
      store_processes(processes)
    end

    # Per-core (busy, idle) jiffy counters from /proc/stat
    # ("cpuN: user nice system idle iowait irq softirq steal ...").
    def self.platform_cpu_ticks : Array({UInt64, UInt64})?
      cores = [] of {UInt64, UInt64}
      File.each_line("/proc/stat") do |line|
        break unless line.starts_with?("cpu")
        next if line.starts_with?("cpu ") # aggregate line comes first
        fields = line.split
        busy = {1, 2, 3, 6, 7, 8}.sum { |i| fields[i]?.try(&.to_u64?) || 0_u64 }
        idle = (fields[4]?.try(&.to_u64?) || 0_u64) &+ (fields[5]?.try(&.to_u64?) || 0_u64)
        cores << {busy, idle}
      end
      cores.empty? ? nil : cores
    rescue File::NotFoundError
      nil
    end

    # (received, sent) byte counters from /proc/net/dev, skipping lo.
    def self.platform_network_counters : {UInt64, UInt64}?
      received = 0_u64
      sent = 0_u64
      File.each_line("/proc/net/dev") do |line|
        next unless separator = line.index(':')
        next if line[0, separator].strip == "lo"
        columns = line[(separator + 1)..].split
        received += columns[0]?.try(&.to_u64?) || 0_u64
        sent += columns[8]?.try(&.to_u64?) || 0_u64
      end
      {received, sent}
    rescue File::NotFoundError
      nil
    end

    # GPU readings: the NVIDIA cards through NVML plus every amdgpu
    # card in KFD order.
    def self.platform_gpus : Array(Gpu)
      gpus = nvml_gpus
      amd_device_dirs.each do |dir|
        gpus << amd_gpu(dir)
      end
      gpus
    end

    # The amdgpu sysfs device folders (/sys/class/drm/renderD<N>/device)
    # of the AMD GPUs, in KFD topology order — the numbering HIP and
    # Strata's telemetry use. GPU nodes are the KFD nodes with a gfx
    # target version and SIMDs; each is linked to its render node by
    # drm_render_minor. `base` is overridable for the specs.
    def self.amd_device_dirs(base = "/sys") : Array(String)
      nodes = File.join(base, "class", "kfd", "kfd", "topology", "nodes")
      return [] of String unless Dir.exists?(nodes)
      dirs = [] of String
      Dir.children(nodes)
        .select { |node| node.to_i? }
        .sort_by { |node| node.to_i.not_nil! }
        .each do |node|
          properties = File.read(File.join(nodes, node, "properties")) rescue nil
          next unless properties
          props = Hash(String, String).new
          properties.each_line do |line|
            key, _, value = line.partition(" ")
            props[key] = value.strip unless key.empty?
          end
          next if (props["gfx_target_version"]?.try(&.to_i?) || 0) == 0
          next if (props["simd_count"]?.try(&.to_i?) || 0) == 0
          next unless minor = props["drm_render_minor"]?
          device = File.join(base, "class", "drm", "renderD#{minor.strip}", "device")
          dirs << device if Dir.exists?(device)
        end
      dirs
    end

    # One amdgpu card's readings: load (gpu_busy_percent), VRAM
    # (mem_info_vram_used/_total, bytes) and, from its hwmon folder,
    # the edge temperature (temp1_input, m°C), power (power1_average
    # or power1_input, µW) and its cap (power1_cap).
    def self.amd_gpu(dir : String) : Gpu
      util = read_sysfs_int(File.join(dir, "gpu_busy_percent")).try(&.to_i32)
      used_kb = read_sysfs_int(File.join(dir, "mem_info_vram_used")).try { |b| (b // 1024).to_i64 }
      total_kb = read_sysfs_int(File.join(dir, "mem_info_vram_total")).try { |b| (b // 1024).to_i64 }

      temp = power = power_limit = nil
      hwmons = Dir.children(File.join(dir, "hwmon")) rescue nil
      if hwmons && !hwmons.empty?
        hwmon = File.join(dir, "hwmon", hwmons.sort.first)
        temp = read_sysfs_int(File.join(hwmon, "temp1_input"))
          .try { |mc| (mc / 1000.0).round.to_i32 }
        microwatts = read_sysfs_int(File.join(hwmon, "power1_average")) ||
                     read_sysfs_int(File.join(hwmon, "power1_input"))
        power = microwatts.try { |uw| uw / 1e6 }
        power_limit = read_sysfs_int(File.join(hwmon, "power1_cap"))
          .try { |uw| uw / 1e6 }
      end

      name = (File.read(File.join(dir, "product_name")).strip rescue nil)
      name = "AMD Radeon" if name.nil? || name.empty?
      Gpu.new(:amd, name, util, used_kb, total_kb, temp, power, power_limit)
    end

    private def self.read_sysfs_int(path : String) : Int64?
      File.read(path).strip.to_i64?
    rescue
      nil
    end
  end
{% end %}
