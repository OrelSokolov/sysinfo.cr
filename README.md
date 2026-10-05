# sysinfo.cr

Cross-platform system & process memory info for Crystal — a small port
of the Rust [sysinfo](https://crates.io/crates/sysinfo) crate's surface:

- `Sysinfo.memory` — global RAM: `total_kb` / `available_kb` / `used_kb` / `percent`
- `Sysinfo.refresh_processes` — rebuild the pid / parent / RSS snapshot
- `Sysinfo.processes` — the last snapshot (`Sysinfo::Process` entries)
- `Sysinfo.process_tree_memory_kb(pid)` — RSS of a process **and all its
  descendants** (what a terminal tab actually uses: the shell plus its
  compilers/servers/agents), cycle-safe
- `Sysinfo.refresh_cpu` / `Sysinfo.cpu_percentages` — per-core busy percent
  since the previous sample (first call is a baseline of zeros)
- `Sysinfo.refresh_network` / `Sysinfo.network` — bytes received/sent since
  boot plus average rates since the previous sample, loopback excluded
- `Sysinfo.refresh_gpus` / `Sysinfo.gpus` — one `Sysinfo::Gpu` per card:
  load, VRAM used/total/percent, temperature, power and power limit
  (plus PCIe gen/width on NVIDIA). Unreadable values are `nil`; nothing
  here can raise into the caller.

The library is synchronous, like the Rust crate — callers decide when
and where to refresh (h2term hides it on a background fiber).

## Backends

| Platform | RAM | Process table | CPU cores | Network | GPU |
|---|---|---|---|---|---|
| Linux | `/proc/meminfo` | `/proc/<pid>/status` (PPid + VmRSS) | `/proc/stat` | `/proc/net/dev` | NVML (`dlopen`) + amdgpu sysfs |
| macOS | `sysctl` + `host_statistics64` | libproc (`proc_listallpids`, `proc_pidinfo`) | `host_processor_info` | `sysctl(NET_RT_IFLIST2)` | — |
| Windows | `GlobalMemoryStatusEx` | Toolhelp32 + `GetProcessMemoryInfo` | `NtQuerySystemInformation` | `GetIfTable2` | NVML (`LoadLibraryA`) |
| Other | `nil` | empty | — | — | — |

GPU readings come from the same sources Strata's monitor uses: NVIDIA's
own NVML library, loaded at runtime from the driver (`libnvidia-ml.so.1`
/ `nvml.dll`) so there is no compile-time binding, and — on Linux — the
amdgpu driver's sysfs files (KFD topology → `renderD*` device →
`gpu_busy_percent`, `mem_info_vram_*`, the `hwmon` temperature/power
sensors); no ROCm library needed. AMD on Windows would need ADL, and
Intel's xe driver only accounts VRAM per-client through root-only
fdinfo, so neither reports GPUs here.

On Linux `/proc`'s top level lists only thread-group leaders, so
per-thread RSS can never be double-counted (upstream sysinfo has to
filter thread entries explicitly). On macOS, `proc_pidinfo` only
succeeds for processes the current uid may signal; the snapshot skips
everyone else.

## Use

```crystal
require "sysinfo"

if mem = Sysinfo.memory
  puts "RAM #{mem.used_kb // 1024}/#{mem.total_kb // 1024} MB (#{mem.percent}%)"
end

Sysinfo.refresh_processes
Sysinfo.process_tree_memory_kb(Process.pid) # => whole tree RSS in KB
```

A live monitor example (per-core CPU load, RAM, network throughput,
GPU readings) lives in `example/monitor.cr`:

```sh
crystal run example/monitor.cr
```

macOS note: on current kernels the interface byte counters come back
with the high 32 bits zeroed, so totals wrap at 4 GB — the rate math
uses wrapping deltas and stays correct across the wrap.

## Test

```sh
crystal spec
```
