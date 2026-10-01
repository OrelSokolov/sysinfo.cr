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
  end
{% end %}
