# Fallback backend: everything unknown on platforms without a native
# backend (memory nil, processes empty) — same contract as a failed
# read on the supported ones.

{% unless flag?(:linux) || flag?(:darwin) || flag?(:windows) %}
  module Sysinfo
    def self.platform_memory : Memory?
      nil
    end

    def self.platform_refresh_processes : Nil
    end

    def self.platform_cpu_ticks : Array({UInt64, UInt64})?
      nil
    end

    def self.platform_network_counters : {UInt64, UInt64}?
      nil
    end
  end
{% end %}
