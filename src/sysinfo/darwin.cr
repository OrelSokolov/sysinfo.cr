# macOS backend: sysctl for RAM sizing, Mach host_statistics64 for
# available pages, libproc for the process table.
#
# proc_pidinfo results are read through opaque byte buffers with
# documented field offsets (instead of hand-copied struct layouts) so
# layout drift in the kernel headers can't silently misread a pid.
# Both flavors only succeed for processes this uid may signal — other
# users' processes are skipped from the snapshot entirely (the same
# restriction the Rust sysinfo crate reports as "no read permission").

{% if flag?(:darwin) %}
  lib LibSysctl
    # size_t is UInt64 on x86_64/aarch64 darwin; name is a plain
    # null-terminated char* (Crystal literals are).
    fun sysctlbyname = sysctlbyname(name : UInt8*, oldp : Void*, oldlenp : UInt64*,
                                    newp : Void*, newlen : UInt64) : Int32
    # int sysctl(int*, u_int, void*, size_t*, void*, size_t)
    fun sysctl = sysctl(name : Int32*, namelen : UInt32, oldp : UInt8*,
                        oldlenp : UInt64*, newp : UInt8*, newlen : UInt64) : Int32

    # net/route.h mib pieces for the interface-stats walk
    CTL_NET        =   4
    PF_ROUTE       =  17
    NET_RT_IFLIST2 =   6
    RTM_IFINFO2    =  18
    IFF_LOOPBACK   = 0x8
  end

  @[Link("proc")]
  lib LibProc
    # proc_pidinfo flavors (libproc.h); sizes are in bytes, the return
    # value of the filling call is the number of pids written.
    PROC_PIDBSDINFO  = 3
    PROC_PIDTASKINFO = 4

    fun proc_listallpids = proc_listallpids(buffer : Int32*, size : Int32) : Int32
    fun proc_pidinfo = proc_pidinfo(pid : Int32, flavor : Int32, arg : UInt64,
                                    buffer : UInt8*, size : Int32) : Int32
  end

  # mach_* calls live in libSystem (no separate libmach on modern SDKs);
  # proc_* needs -lproc.
  lib LibMach
    # host_info64_t flavor (mach/host_info.h)
    HOST_VM_INFO64 = 4

    # processor_info.h: host_processor_info flavor + CPU_STATE_* slots
    # of processor_cpu_load_info (user, system, idle, nice).
    PROCESSOR_CPU_LOAD_INFO = 2

    fun mach_host_self = mach_host_self : UInt32
    fun host_statistics64 = host_statistics64(host : UInt32, flavor : Int32,
                                              info : UInt8*, count : UInt32*) : Int32
    fun host_processor_info = host_processor_info(host : UInt32, flavor : Int32,
                                                  core_count : UInt32*,
                                                  info : Int32**,
                                                  info_count : UInt32*) : Int32
    fun mach_task_self = mach_task_self : UInt32
    fun vm_deallocate = vm_deallocate(target : UInt32, address : UInt64,
                                      size : UInt64) : Int32
  end

  module Sysinfo
    KB = 1024

    def self.sysctl_u64(name : String) : UInt64?
      value = uninitialized UInt64
      size : UInt64 = sizeof(UInt64).to_u64
      if LibSysctl.sysctlbyname(name.to_unsafe, pointerof(value), pointerof(size),
           nil, 0) == 0
        value
      end
    end

    def self.page_size_kb : UInt64
      sysctl_u64("hw.pagesize").try(&.//(KB)) || 4_u64
    end

    def self.platform_memory : Memory?
      total = sysctl_u64("hw.memsize")
      return nil unless total

      # HOST_VM_INFO64 fills vm_statistics64_data_t; we only rely on its
      # leading natural_t fields (free / active / inactive counts), so a
      # UInt32 view of the buffer is all the layout we depend on.  The
      # count must cover the whole struct (62+ units after the rev3 tag
      # fields) or the kernel rejects the call.
      counters = uninitialized UInt32[128]
      count = counters.size.to_u32
      available_kb = 0_i64
      if LibMach.host_statistics64(LibMach.mach_host_self, LibMach::HOST_VM_INFO64,
           counters.to_unsafe.as(UInt8*), pointerof(count)) == 0
        pages = counters[0] + counters[2] # free + inactive
        available_kb = pages.to_u64 * page_size_kb
      end
      Memory.new((total // KB).to_i64, available_kb.to_i64)
    end

    def self.platform_refresh_processes : Nil
      # proc_listallpids(NULL, 0) returns a pid count hint, but the
      # buffersize argument of the filling call is in bytes and its
      # return value is the number of pids actually written.
      pid_count = LibProc.proc_listallpids(nil, 0)
      return if pid_count <= 0
      pids = Pointer(Int32).malloc(pid_count)
      filled = LibProc.proc_listallpids(pids, pid_count * sizeof(Int32))
      return if filled <= 0

      processes = [] of Process
      bsd_info = Bytes.new(512)
      task_info = Bytes.new(512)
      filled.times do |i|
        pid = pids[i]
        next if pid <= 0

        ppid = nil
        rss_kb = 0_i64
        if LibProc.proc_pidinfo(pid, LibProc::PROC_PIDBSDINFO, 0,
             bsd_info, bsd_info.size) > 0
          # proc_bsdinfo: pbi_flags, pbi_status, pbi_xstatus, pbi_pid,
          # pbi_ppid — all UInt32 at documented offsets.
          info_pid = IO::ByteFormat::SystemEndian.decode(UInt32, bsd_info + 12)
          ppid_raw = IO::ByteFormat::SystemEndian.decode(UInt32, bsd_info + 16)
          next unless info_pid == pid # stale table entry
          ppid = ppid_raw.to_i32 if ppid_raw > 0
        else
          next # not allowed to see it at all
        end
        if LibProc.proc_pidinfo(pid, LibProc::PROC_PIDTASKINFO, 0,
             task_info, task_info.size) > 0
          # proc_taskinfo: pti_virtual_size, pti_resident_size (bytes).
          rss_kb = IO::ByteFormat::SystemEndian.decode(UInt64, task_info + 8) // KB
        end
        processes << Process.new(pid, ppid, rss_kb.to_i64)
      end
      store_processes(processes)
    end

    # Per-core (busy, idle) tick counters from host_processor_info.
    # The returned array is vm-allocated and must be freed with
    # vm_deallocate (not free).
    def self.platform_cpu_ticks : Array({UInt64, UInt64})?
      core_count = uninitialized UInt32
      info = uninitialized Int32*
      info_count = uninitialized UInt32
      return nil if LibMach.host_processor_info(
                      LibMach.mach_host_self, LibMach::PROCESSOR_CPU_LOAD_INFO,
                      pointerof(core_count), pointerof(info), pointerof(info_count)) != 0

      cores = Array({UInt64, UInt64}).new(core_count) do |i|
        base = info + (i &* 4)
        busy = base[0].to_u64! &+ base[1].to_u64! &+ base[3].to_u64! # user+system+nice
        {busy, base[2].to_u64!}                                      # idle
      end
      LibMach.vm_deallocate(LibMach.mach_task_self, info.address,
        info_count.to_u64! &* sizeof(Int32))
      cores
    end

    # (received, sent) byte counters summed over non-loopback interfaces,
    # read from the route-socket interface list. Each RTM_IFINFO2
    # message is an if_msghdr2 whose if_data64 starts at offset 32
    # (verified against the SDK headers) and carries ifi_ibytes /
    # ifi_obytes at 96 / 104. NB: current kernels zero the high 32 bits
    # of the byte counters, so totals may wrap at 4 GB — rate deltas use
    # wrapping arithmetic and stay correct across the wrap.
    def self.platform_network_counters : {UInt64, UInt64}?
      mib = StaticArray(Int32, 6).new(0)
      mib[0] = LibSysctl::CTL_NET
      mib[1] = LibSysctl::PF_ROUTE
      mib[4] = LibSysctl::NET_RT_IFLIST2

      size : UInt64 = 0
      return nil if LibSysctl.sysctl(mib.to_unsafe, 6, nil, pointerof(size), nil, 0) != 0
      return nil if size == 0
      buffer = Bytes.new(size.to_i32)
      return nil if LibSysctl.sysctl(mib.to_unsafe, 6, buffer.to_unsafe,
                      pointerof(size), nil, 0) != 0

      received = 0_u64
      sent = 0_u64
      offset = 0
      while offset + 112 <= buffer.size # obytes (104..112) must fit
        msglen = IO::ByteFormat::SystemEndian.decode(UInt16, buffer + offset)
        break if msglen == 0
        if buffer[offset + 3] == LibSysctl::RTM_IFINFO2
          flags = IO::ByteFormat::SystemEndian.decode(UInt32, buffer + (offset + 8))
          if flags & LibSysctl::IFF_LOOPBACK == 0
            received += IO::ByteFormat::SystemEndian.decode(UInt64, buffer + (offset + 96))
            sent += IO::ByteFormat::SystemEndian.decode(UInt64, buffer + (offset + 104))
          end
        end
        offset += msglen
      end
      {received, sent}
    end
  end
{% end %}
