# sysinfo.cr — cross-platform system & process memory info, a small
# port of the Rust `sysinfo` crate's surface (the parts h2term needs):
#
#   Sysinfo.memory                    — global RAM (total/available/used/percent)
#   Sysinfo.refresh_processes         — rebuild the pid/parent/RSS snapshot
#   Sysinfo.processes                 — the last snapshot
#   Sysinfo.process_tree_memory_kb    — RSS of a process + all descendants
#   Sysinfo.refresh_cpu               — sample tick counters, update per-core load
#   Sysinfo.cpu_percentages           — per-core busy percent since the last sample
#   Sysinfo.refresh_network           — sample interface counters, update rates
#   Sysinfo.network                   — totals since boot + rates since the last sample
#   Sysinfo.refresh_gpus              — read every supported GPU (VRAM, load, temp, power)
#   Sysinfo.gpus                      — the last GPU snapshot
#
# The library is synchronous, like the Rust crate: callers decide when
# and where to refresh (h2term hides it on a monitor fiber).
#
# Platform notes:
#   Linux   — /proc (meminfo + per-pid status). /proc's top level lists
#             only thread-group leaders, so per-thread RSS can never be
#             double counted (upstream sysinfo has to filter threads).
#   macOS   — sysctl for RAM sizing, host_statistics64 for available
#             pages, libproc for the process table. proc_pidinfo only
#             succeeds for same-uid (or root) processes; the snapshot
#             skips everyone else.
#   Windows — GlobalMemoryStatusEx + Toolhelp32 process snapshot +
#             GetProcessMemoryInfo for working sets (0 KB when access
#             is denied), NtQuerySystemInformation for per-core CPU
#             ticks, GetIfTable2 for interface byte counters, NVML
#             (runtime LoadLibraryA) for NVIDIA GPUs.
#   GPU     — NVIDIA through NVML loaded at runtime (Linux dlopen,
#             Windows LoadLibraryA); AMD through the amdgpu driver's
#             sysfs files on Linux; Intel (integrated and Arc) through
#             Level Zero Sysman (libze_loader.so.1 / ze_loader.dll)
#             loaded at runtime on Linux and Windows; macOS reports no
#             GPUs. Level Zero's engine load and power are counters, so
#             they only exist after the second refresh_gpus.
#   Other   — memory returns nil, processes stay empty.

require "./sysinfo/*"

module Sysinfo
  # Global RAM statistics; sizes in KB.
  struct Memory
    getter total_kb : Int64
    getter available_kb : Int64

    def initialize(@total_kb : Int64, @available_kb : Int64)
    end

    def used_kb : Int64
      {@total_kb - @available_kb, 0_i64}.max
    end

    # Used percent, 0 when total is unknown.
    def percent : Int32
      return 0 if @total_kb <= 0
      ((used_kb.to_f / @total_kb) * 100.0).round.to_i32.clamp(0, 100)
    end
  end

  # One non-thread process entry from the snapshot.
  struct Process
    getter pid : Int32
    # nil for init / kernel threads (ppid 0).
    getter parent_pid : Int32?
    getter memory_kb : Int64

    def initialize(@pid : Int32, @parent_pid : Int32?, @memory_kb : Int64)
    end
  end

  # Network traffic; sizes in KB. The rates are averages over the span
  # between the previous refresh_network and this one (0 on the first
  # sample, like cpu_percentages before the second refresh_cpu).
  struct Network
    getter total_received_kb : Int64
    getter total_sent_kb : Int64
    getter received_kb_s : Int64
    getter sent_kb_s : Int64

    def initialize(@total_received_kb : Int64, @total_sent_kb : Int64,
                   @received_kb_s : Int64, @sent_kb_s : Int64)
    end
  end

  # Snapshot state; swapped whole by refresh_processes.
  @@processes : Array(Process) = [] of Process
  @@by_pid : Hash(Int32, Process) = Hash(Int32, Process).new
  @@children : Hash(Int32, Array(Int32)) = Hash(Int32, Array(Int32)).new
  @@children_built = false

  # Global RAM, nil = unknown on this platform.
  def self.memory : Memory?
    platform_memory
  end

  # Rebuild the process snapshot (call off the UI hot path — reading a
  # few hundred entries takes milliseconds).
  def self.refresh_processes : Nil
    platform_refresh_processes
    @@children_built = false
  end

  # The last snapshot (empty until refresh_processes ran).
  def self.processes : Array(Process)
    @@processes
  end

  # Resident memory of a process and all its descendants in KB — the
  # closest thing to "what this tab actually uses", since shells spawn
  # children (compilers, servers, agents). 0 when unknown / without a
  # snapshot. Cycle-safe.
  def self.process_tree_memory_kb(root_pid : Int32?) : Int64
    return 0_i64 unless root = root_pid
    build_children unless @@children_built
    total = 0_i64
    visited = Set(Int32).new
    queue = Deque(Int32){root}
    while pid = queue.shift?
      next unless visited.add?(pid)
      if process = @@by_pid[pid]?
        total += process.memory_kb
      end
      @@children[pid]?.try &.each { |child| queue << child }
    end
    total
  end

  private def self.build_children : Nil
    children = Hash(Int32, Array(Int32)).new
    by_pid = Hash(Int32, Process).new
    @@processes.each do |process|
      by_pid[process.pid] = process
      if parent = process.parent_pid
        (children[parent] ||= [] of Int32) << process.pid
      end
    end
    @@children = children
    @@by_pid = by_pid
    @@children_built = true
  end

  # Store a fresh snapshot (platform backends call this).
  protected def self.store_processes(processes : Array(Process)) : Nil
    @@processes = processes
    @@children_built = false
  end

  # CPU state; swapped by refresh_cpu. Platforms deliver per-core
  # (busy, idle) tick counters — the delta math is shared.
  @@cpu_percentages : Array(Int32) = [] of Int32
  @@last_cpu_ticks : Array({UInt64, UInt64})? = nil

  # Sample CPU counters and update per-core percentages. The first call
  # only stores a baseline, so percentages read 0 until the second call
  # (space the calls ~1 s apart for readable rates).
  def self.refresh_cpu : Nil
    cores = platform_cpu_ticks
    percentages =
      if cores && (previous = @@last_cpu_ticks) && previous.size == cores.size
        cores.zip(previous).map do |current, before|
          busy = current[0] &- before[0]
          idle = current[1] &- before[1]
          total = busy &+ idle
          total == 0 ? 0 : ((busy.to_f / total) * 100.0).round.to_i32.clamp(0, 100)
        end
      elsif cores
        Array.new(cores.size, 0)
      else
        [] of Int32
      end
    @@cpu_percentages = percentages
    @@last_cpu_ticks = cores
  end

  # Busy percent per core since the previous refresh_cpu (empty until
  # refresh_cpu ran; zeros after only one call).
  def self.cpu_percentages : Array(Int32)
    @@cpu_percentages
  end

  # Network state; swapped by refresh_network.
  @@network : Network? = nil
  @@last_net_counters : {UInt64, UInt64}? = nil
  @@last_net_at : Time::Instant? = nil

  # Sample interface counters and update traffic rates. Like CPU, the
  # first call only stores a baseline. Loopback is excluded.
  def self.refresh_network : Nil
    counters = platform_network_counters
    network =
      if counters
        now = Time.instant
        received_kb_s = 0_i64
        sent_kb_s = 0_i64
        if (before = @@last_net_counters) && (started = @@last_net_at) &&
           (seconds = (now - started).total_seconds) > 0
          received_kb_s = ((counters[0] &- before[0]).to_f / 1024 / seconds).round.to_i64
          sent_kb_s = ((counters[1] &- before[1]).to_f / 1024 / seconds).round.to_i64
        end
        Network.new((counters[0] // 1024).to_i64, (counters[1] // 1024).to_i64,
          received_kb_s, sent_kb_s)
      end
    @@network = network
    @@last_net_counters = counters
    @@last_net_at = counters ? Time.instant : nil
  end

  # The last network sample (nil until refresh_network ran, or on
  # platforms without a backend).
  def self.network : Network?
    @@network
  end
end
