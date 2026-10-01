# sysinfo.cr

Cross-platform system & process memory info for Crystal — a small port
of the Rust [sysinfo](https://crates.io/crates/sysinfo) crate's surface:

- `Sysinfo.memory` — global RAM: `total_kb` / `available_kb` / `used_kb` / `percent`
- `Sysinfo.refresh_processes` — rebuild the pid / parent / RSS snapshot
- `Sysinfo.processes` — the last snapshot (`Sysinfo::Process` entries)
- `Sysinfo.process_tree_memory_kb(pid)` — RSS of a process **and all its
  descendants** (what a terminal tab actually uses: the shell plus its
  compilers/servers/agents), cycle-safe

The library is synchronous, like the Rust crate — callers decide when
and where to refresh (h2term hides it on a background fiber).

## Backends

| Platform | RAM | Process table |
|---|---|---|
| Linux | `/proc/meminfo` | `/proc/<pid>/status` (PPid + VmRSS) |
| macOS | `sysctl` + `host_statistics64` | libproc (`proc_listallpids`, `proc_pidinfo`) |
| Windows | `GlobalMemoryStatusEx` | Toolhelp32 + `GetProcessMemoryInfo` (best effort, not yet tested on a Windows host) |
| Other | `nil` | empty |

On Linux `/proc`'s top level lists only thread-group leaders, so
per-thread RSS can never be double-counted (upstream sysinfo has to
filter thread entries explicitly). On macOS, RSS is readable only for
processes the current uid may signal; others report 0 KB.

## Use

```crystal
require "sysinfo"

if mem = Sysinfo.memory
  puts "RAM #{mem.used_kb // 1024}/#{mem.total_kb // 1024} MB (#{mem.percent}%)"
end

Sysinfo.refresh_processes
Sysinfo.process_tree_memory_kb(Process.pid) # => whole tree RSS in KB
```

## Test

```sh
crystal spec
```
