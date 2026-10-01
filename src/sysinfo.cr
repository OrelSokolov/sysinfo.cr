# sysinfo.cr — cross-platform system & process memory info, a small
# port of the Rust `sysinfo` crate's surface (the parts h2term needs):
#
#   Sysinfo.memory                    — global RAM (total/available/used/percent)
#   Sysinfo.refresh_processes         — rebuild the pid/parent/RSS snapshot
#   Sysinfo.processes                 — the last snapshot
#   Sysinfo.process_tree_memory_kb    — RSS of a process + all descendants
#
# The library is synchronous, like the Rust crate: callers decide when
# and where to refresh (h2term hides it on a monitor fiber).
#
# Platform notes:
#   Linux   — /proc (meminfo + per-pid status). /proc's top level lists
#             only thread-group leaders, so per-thread RSS can never be
#             double counted (upstream sysinfo has to filter threads).
#   macOS   — sysctl for RAM sizing, host_statistics64 for available
#             pages, libproc for the process table. RSS reads need
#             same-user (or root) processes; others report 0 KB.
#   Windows — GlobalMemoryStatusEx + Toolhelp32 process snapshot +
#             GetProcessMemoryInfo for working sets (0 KB when access
#             is denied). The Windows backend is written against the
#             documented Win32 APIs but not yet compiled/tested on a
#             Windows host.
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
end
