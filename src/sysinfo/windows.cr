# Windows backend: GlobalMemoryStatusEx for RAM, a Toolhelp32 process
# snapshot for pid/ppid, GetProcessMemoryInfo for working sets.
#
# Toolhelp32/OpenProcess/CloseHandle come from the stdlib's LibC; only
# the memory calls are declared here. NOTE: written against the
# documented Win32 APIs, but not yet compiled or run on a Windows host
# — treat as best effort. Processes we can't open (services, other
# users) still appear in the table with 0 KB.

{% if flag?(:windows) %}
  lib LibWinMemory
    struct MEMORYSTATUSEX
      dw_length : UInt32
      dw_memory_load : UInt32
      ull_total_phys : UInt64
      ull_avail_phys : UInt64
      ull_total_page_file : UInt64
      ull_avail_page_file : UInt64
      ull_total_virtual : UInt64
      ull_avail_virtual : UInt64
      ull_avail_extended_virtual : UInt64
    end

    fun global_memory_status_ex = GlobalMemoryStatusEx(buffer : MEMORYSTATUSEX*) : Int32
  end

  lib LibPsapi
    struct PROCESS_MEMORY_COUNTERS
      cb : UInt32
      page_fault_count : UInt32
      peak_working_set_size : UInt64
      working_set_size : UInt64
      quota_peak_paged_pool_usage : UInt64
      quota_paged_pool_usage : UInt64
      quota_peak_non_paged_pool_usage : UInt64
      quota_non_paged_pool_usage : UInt64
      pagefile_usage : UInt64
      peak_pagefile_usage : UInt64
    end

    fun get_process_memory_info = GetProcessMemoryInfo(process : Void*,
                                                       counters : PROCESS_MEMORY_COUNTERS*,
                                                       cb : UInt32) : Int32
  end

  module Sysinfo
    KB = 1024_u64

    PROCESS_QUERY_LIMITED_INFORMATION = 0x00001000_u32

    def self.platform_memory : Memory?
      status = LibWinMemory::MEMORYSTATUSEX.new
      status.dw_length = sizeof(LibWinMemory::MEMORYSTATUSEX).to_u32
      return nil if LibWinMemory.global_memory_status_ex(pointerof(status)) == 0
      Memory.new((status.ull_total_phys // KB).to_i64,
        (status.ull_avail_phys // KB).to_i64)
    end

    def self.platform_refresh_processes : Nil
      snapshot = LibC.CreateToolhelp32Snapshot(LibC::TH32CS_SNAPPROCESS, 0)
      return if snapshot.null?

      processes = [] of Process
      entry = LibC::PROCESSENTRY32W.new
      entry.dwSize = sizeof(LibC::PROCESSENTRY32W).to_u32
      ok = LibC.Process32FirstW(snapshot, pointerof(entry))
      while ok != 0
        pid = entry.th32ProcessID
        ppid = entry.th32ParentProcessID
        rss_kb = 0_i64
        handle = LibC.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid)
        unless handle.null?
          counters = LibPsapi::PROCESS_MEMORY_COUNTERS.new
          counters.cb = sizeof(LibPsapi::PROCESS_MEMORY_COUNTERS).to_u32
          if LibPsapi.get_process_memory_info(handle, pointerof(counters), counters.cb) != 0
            rss_kb = (counters.working_set_size // KB).to_i64
          end
          LibC.CloseHandle(handle)
        end
        processes << Process.new(pid.to_i32, ppid > 0 ? ppid.to_i32 : nil, rss_kb)
        ok = LibC.Process32NextW(snapshot, pointerof(entry))
      end
      LibC.CloseHandle(snapshot)
      store_processes(processes)
    end

    # CPU / network counters are not implemented for Windows yet.
    def self.platform_cpu_ticks : Array({UInt64, UInt64})?
      nil
    end

    def self.platform_network_counters : {UInt64, UInt64}?
      nil
    end
  end
{% end %}
