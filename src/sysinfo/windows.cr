# Windows backend: GlobalMemoryStatusEx for RAM, a Toolhelp32 process
# snapshot for pid/ppid, GetProcessMemoryInfo for working sets,
# NtQuerySystemInformation for per-core CPU ticks, GetIfTable2 for
# interface byte counters.
#
# Toolhelp32/OpenProcess/CloseHandle come from the stdlib's LibC; the
# memory/ntdll/iphlpapi calls are declared here against the SDK headers
# (netioapi.h layout verified against 10.0.19041.0). Processes we can't
# open (services, other users) still appear in the table with 0 KB.

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

  @[Link("psapi")]
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

  @[Link("ntdll")]
  lib LibNtDll
    # winternl.h SYSTEM_INFORMATION_CLASS
    SystemProcessorPerformanceInformation = 8_u32

    fun nt_query_system_information = NtQuerySystemInformation(
      system_information_class : UInt32, system_information : UInt8*,
      system_information_length : UInt32, return_length : UInt32*) : Int32
  end

  @[Link("iphlpapi")]
  lib LibIphlpapi
    # ipifcons.h IFTYPE for software loopback
    IF_TYPE_SOFTWARE_LOOPBACK = 24_u32

    # ifdef.h sizing used by MIB_IF_ROW2:
    #   IF_MAX_STRING_SIZE + 1         = 257 WCHARs
    #   IF_MAX_PHYS_ADDRESS_LENGTH     = 32 bytes
    IF_MAX_STRING_SIZE          =  256
    IF_MAX_PHYS_ADDRESS_LENGTH  =   32

    # GUID (align 4, 16 bytes) — layout-compatible placeholder for the
    # interface/network GUIDs.
    struct GUID
      data1 : UInt32
      data2 : UInt16
      data3 : UInt16
      data4 : UInt8[8]
    end

    # netioapi.h MIB_IF_ROW2: field list and types 1:1 with the header
    # (all the enum fields are 4-byte); the compiler lays it out per the
    # C ABI, so only InOctets/OutOctets and Type are actually read.
    struct MIB_IF_ROW2
      interface_luid : UInt64                       # NET_LUID (union over ULONG64)
      interface_index : UInt32                      # NET_IFINDEX
      interface_guid : GUID
      alias : UInt16[257]                           # WCHAR[IF_MAX_STRING_SIZE + 1]
      description : UInt16[257]
      physical_address_length : UInt32
      physical_address : UInt8[32]                  # IF_MAX_PHYS_ADDRESS_LENGTH
      permanent_physical_address : UInt8[32]
      mtu : UInt32
      type : UInt32                                 # IFTYPE
      tunnel_type : Int32                           # TUNNEL_TYPE enum
      media_type : Int32                            # NDIS_MEDIUM enum
      physical_medium_type : Int32                  # NDIS_PHYSICAL_MEDIUM enum
      access_type : Int32                           # NET_IF_ACCESS_TYPE enum
      direction_type : Int32                        # NET_IF_DIRECTION_TYPE enum
      interface_and_oper_status_flags : UInt8       # 8 x 1-bit BOOLEANs
      oper_status : Int32                           # IF_OPER_STATUS enum
      admin_status : Int32                          # NET_IF_ADMIN_STATUS enum
      media_connect_state : Int32                   # NET_IF_MEDIA_CONNECT_STATE enum
      network_guid : GUID                           # NET_IF_NETWORK_GUID
      connection_type : Int32                       # NET_IF_CONNECTION_TYPE enum
      transmit_link_speed : UInt64
      receive_link_speed : UInt64
      in_octets : UInt64
      in_ucast_pkts : UInt64
      in_nucast_pkts : UInt64
      in_discards : UInt64
      in_errors : UInt64
      in_unknown_protos : UInt64
      in_ucast_octets : UInt64
      in_multicast_octets : UInt64
      in_broadcast_octets : UInt64
      out_octets : UInt64
      out_ucast_pkts : UInt64
      out_nucast_pkts : UInt64
      out_discards : UInt64
      out_errors : UInt64
      out_ucast_octets : UInt64
      out_multicast_octets : UInt64
      out_broadcast_octets : UInt64
      out_q_len : UInt64
    end

    struct MIB_IF_TABLE2
      num_entries : UInt32
      table : MIB_IF_ROW2[1]
    end

    fun get_if_table2 = GetIfTable2(table : MIB_IF_TABLE2**) : UInt32
    fun free_mib_table = FreeMibTable(buffer : Void*) : Void
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
      return if snapshot == LibC::INVALID_HANDLE_VALUE

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

    # Per-core (busy, idle) 100-ns tick counters from
    # NtQuerySystemInformation(SystemProcessorPerformanceInformation):
    # one 48-byte SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION per core
    # {IdleTime, KernelTime, UserTime, Reserved1[2], Reserved2}, read
    # through documented offsets like the darwin backend. KernelTime
    # includes idle, so busy = kernel + user - idle (interrupts/DPC
    # count as busy). NB: the kernel rejects lengths that are not an
    # exact multiple of 48, so the needed size is probed first (a null
    # buffer returns STATUS_INFO_LENGTH_MISMATCH and the byte count).
    # This class reports only the processor group of the calling
    # process — enough for a terminal monitor.
    def self.platform_cpu_ticks : Array({UInt64, UInt64})?
      entry_size = 48
      written = uninitialized UInt32
      LibNtDll.nt_query_system_information(
        LibNtDll::SystemProcessorPerformanceInformation, Pointer(UInt8).null,
        0_u32, pointerof(written))
      return nil if written == 0
      size = (written + entry_size - 1) // entry_size * entry_size
      buffer = Bytes.new(size)
      status = LibNtDll.nt_query_system_information(
        LibNtDll::SystemProcessorPerformanceInformation, buffer.to_unsafe,
        buffer.size.to_u32, pointerof(written))
      return nil if status != 0
      count = written // entry_size
      return nil if count == 0
      cores = Array({UInt64, UInt64}).new(count.to_i32) do |i|
        entry = buffer + (i &* entry_size)
        idle = IO::ByteFormat::SystemEndian.decode(UInt64, entry)
        kernel = IO::ByteFormat::SystemEndian.decode(UInt64, entry + 8)
        user = IO::ByteFormat::SystemEndian.decode(UInt64, entry + 16)
        {(kernel &+ user) &- idle, idle}
      end
      cores
    end

    # (received, sent) byte counters summed over non-loopback
    # interfaces from GetIfTable2's MIB_IF_ROW2 table (64-bit
    # counters, no 4 GB wrap like the old MIB_IFROW / macOS). The
    # table is heap-allocated by the API and freed with FreeMibTable.
    def self.platform_network_counters : {UInt64, UInt64}?
      table = Pointer(LibIphlpapi::MIB_IF_TABLE2).null
      return nil if LibIphlpapi.get_if_table2(pointerof(table)) != 0
      return nil if table.null?

      received = 0_u64
      sent = 0_u64
      rows = table.value.table.to_unsafe
      table.value.num_entries.times do |i|
        row = rows[i]
        next if row.type == LibIphlpapi::IF_TYPE_SOFTWARE_LOOPBACK
        received &+= row.in_octets
        sent &+= row.out_octets
      end
      LibIphlpapi.free_mib_table(table.as(Void*))
      {received, sent}
    end

    # GPU readings: the NVIDIA cards through runtime-loaded NVML (AMD
    # on Windows would need ADL and is not covered).
    def self.platform_gpus : Array(Gpu)
      nvml_gpus
    end
  end
{% end %}
