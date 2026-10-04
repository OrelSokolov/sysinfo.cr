# Example monitor: per-core CPU load, RAM usage, network throughput.
#
#   crystal run example/monitor.cr
#
# Ctrl+C stops it. CPU percentages and network rates need two samples,
# so the first line of output is a baseline; everything after the first
# second is live.

require "../src/sysinfo"

def bar(percent : Int32, width = 20) : String
  filled = percent.clamp(0, 100) * width // 100
  ("#" * filled).ljust(width, '·')
end

Sysinfo.refresh_cpu
Sysinfo.refresh_network

loop do
  Sysinfo.refresh_cpu
  Sysinfo.refresh_network

  print "\e[H\e[2J"
  puts "sysinfo.cr monitor  (#{Time.local.to_s("%H:%M:%S")})"
  puts

  Sysinfo.cpu_percentages.each_with_index do |percent, i|
    printf("cpu %2d [%s] %3d%%\n", i + 1, bar(percent), percent)
  end
  puts

  if mem = Sysinfo.memory
    printf("ram      [%s] %5d/%d MB  %d%%\n",
      bar(mem.percent), mem.used_kb // 1024, mem.total_kb // 1024, mem.percent)
  else
    puts "ram      (unknown on this platform)"
  end

  if net = Sysinfo.network
    rx = net.received_kb_s.clamp(0, 10_000).to_i32
    tx = net.sent_kb_s.clamp(0, 10_000).to_i32
    printf("net down [%s] %d KB/s\n", bar(rx * 100 // 10_000), rx)
    printf("net up   [%s] %d KB/s\n", bar(tx * 100 // 10_000), tx)
    printf("         total rx %d MB, tx %d MB\n",
      net.total_received_kb // 1024, net.total_sent_kb // 1024)
  else
    puts "net      (unknown on this platform)"
  end

  sleep Time::Span.new(seconds: 1)
end
