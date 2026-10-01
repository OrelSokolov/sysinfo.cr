# macOS backend: sysctl for RAM sizing, Mach host_statistics64 for
# available pages, libproc for the process table.
#
# proc_pidinfo results are read through opaque byte buffers with
# documented field offsets (instead of hand-copied struct layouts) so
# layout drift in the kernel headers can't silently misread a pid.
# PROC_PIDTASKINFO only succeeds for processes this uid may signal —
# everyone else reports 0 KB RSS, like sysinfo's "no read permission".

{% if flag?(:darwin) %}
  lib LibSysctl
    # size_t is UInt64 on x86_64/aarch64 darwin; name is a plain
    # null-terminated char* (Crystal literals are).
    fun sysctlbyname = sysctlbyname(name : UInt8*, oldp : Void*, oldlenp : UInt64*,
                                    newp : Void*, newlen : UInt64) : Int32
  end

  @[Link("proc")]
  lib LibProc
    # proc_pidinfo flavors (libproc.h)
    PROC_PIDBSDINFO  = 3
    PROC_PIDTASKINFO = 4

    # Returns the pid count (size 0) or fills the buffer (size > 0).
    fun proc_listallpids = proc_listallpids(buffer : Int32*, size : Int32) : Int32
    fun proc_pidinfo = proc_pidinfo(pid : Int32, flavor : Int32, arg : UInt64,
                                    buffer : UInt8*, size : Int32) : Int32
  end

  @[Link("mach")]
  lib LibMach
    # host_info64_t flavor (mach/host_info.h)
    HOST_VM_INFO64 = 4

    fun mach_host_self = mach_host_self : UInt32
    fun host_statistics64 = host_statistics64(host : UInt32, flavor : Int32,
                                              info : UInt8*, count : UInt32*) : Int32
  end

  module Sysinfo
    KB = 1024

    def self.sysctl_u64(name : String) : UInt64?
      value = uninitialized UInt64
      size = uninitialized UInt64
      size = sizeof(UInt64)
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
      # UInt32 view of the buffer is all the layout we depend on.
      counters = uninitialized UInt32[32]
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
      count = LibProc.proc_listallpids(nil, 0)
      return if count <= 0
      pids = Pointer(Int32).malloc(count)
      count = LibProc.proc_listallpids(pids, count)
      return if count <= 0

      processes = [] of Process
      bsd_info = Bytes.new(512)
      task_info = Bytes.new(512)
      count.times do |i|
        pid = pids[i]
        next if pid <= 0

        ppid = nil
        rss_kb = 0_i64
        if LibProc.proc_pidinfo(pid, LibProc::PROC_PIDBSDINFO, 0,
                                bsd_info, bsd_info.size) > 0
          # proc_bsdinfo: pbi_flags, pbi_status, pbi_xstatus, pbi_pid,
          # pbi_ppid — all UInt32 at documented offsets.
          info_pid = IO::ByteFormat.decode(UInt32, bsd_info + 12)
          ppid_raw = IO::ByteFormat.decode(UInt32, bsd_info + 16)
          next unless info_pid == pid # stale table entry
          ppid = ppid_raw.to_i32 if ppid_raw > 0
        else
          next # not allowed to see it at all
        end
        if LibProc.proc_pidinfo(pid, LibProc::PROC_PIDTASKINFO, 0,
                                task_info, task_info.size) > 0
          # proc_taskinfo: pti_virtual_size, pti_resident_size (bytes).
          rss_kb = IO::ByteFormat.decode(UInt64, task_info + 8) // KB
        end
        processes << Process.new(pid, ppid, rss_kb.to_i64)
      end
      store_processes(processes)
    end
  end
{% end %}
