require "spec"
require "../src/sysinfo"

describe Sysinfo do
  it "computes memory used/percent" do
    mem = Sysinfo::Memory.new(1000, 250)
    mem.used_kb.should eq(750)
    mem.percent.should eq(75)
    Sysinfo::Memory.new(0, 0).percent.should eq(0)
  end

  it "computes gpu vram percent" do
    gpu = Sysinfo::Gpu.new(:nvidia, mem_used_kb: 250_i64, mem_total_kb: 1000_i64)
    gpu.mem_percent.should eq(25)
    Sysinfo::Gpu.new(:nvidia).mem_percent.should be_nil
    Sysinfo::Gpu.new(:nvidia, mem_used_kb: 250_i64, mem_total_kb: 0_i64).mem_percent.should be_nil
  end

  {% if flag?(:linux) || flag?(:windows) %}
    it "computes intel engine load between snapshots" do
      # 40% busy over a 10ms window
      Sysinfo::Zes.delta_percent(0_u64, 0_u64, 4_000_000_u64, 10_000_000_u64).should eq(40)
      Sysinfo::Zes.delta_percent(0_u64, 0_u64, 10_000_000_u64, 10_000_000_u64).should eq(100)
      # same snapshot twice: no measurable window
      Sysinfo::Zes.delta_percent(5_u64, 5_u64, 5_u64, 5_u64).should be_nil
      # counter reset / driver reinit clamps to zero, not negative
      Sysinfo::Zes.delta_percent(9_u64, 0_u64, 1_u64, 5_u64).should eq(0)
    end
  {% end %}

  it "reports unknown tree memory for nil pid" do
    Sysinfo.process_tree_memory_kb(nil).should eq(0)
  end

  {% if flag?(:linux) %}
    it "finds amdgpu devices through the kfd topology" do
      base = File.join(__DIR__, "fixtures", "sys")
      dirs = Sysinfo.amd_device_dirs(base)
      dirs.should eq([File.join(base, "class", "drm", "renderD128", "device"),
                      File.join(base, "class", "drm", "renderD129", "device")])

      gpu = Sysinfo.amd_gpu(dirs.first)
      gpu.vendor.should eq(:amd)
      gpu.name.should eq("AMD Radeon RX 6700 XT")
      gpu.util_percent.should eq(42)
      gpu.mem_used_kb.should eq(1_048_576)
      gpu.mem_total_kb.should eq(4_194_304)
      gpu.mem_percent.should eq(25)
      gpu.temp_c.should eq(42)
      gpu.power_w.should eq(12.0)
      gpu.power_limit_w.should eq(150.0)

      # A device folder without any readable files keeps nil readings.
      bare = Sysinfo.amd_gpu(dirs.last)
      bare.name.should eq("AMD Radeon")
      bare.util_percent.should be_nil
      bare.temp_c.should be_nil
    end
  {% end %}

  {% if flag?(:linux) || flag?(:darwin) || flag?(:windows) %}
    it "reads global memory" do
      mem = Sysinfo.memory
      mem.should_not be_nil
      mem.not_nil!.total_kb.should be > 0
      (0..100).should contain(mem.not_nil!.percent)
    end

    it "snapshots processes and sums the own process tree" do
      Sysinfo.refresh_processes
      me = Sysinfo.processes.find(&.pid.==(Process.pid))
      me.should_not be_nil
      me.not_nil!.memory_kb.should be > 0
      Sysinfo.process_tree_memory_kb(Process.pid.to_i32).should be > 0
    end

    it "samples per-core cpu percentages" do
      Sysinfo.refresh_cpu # baseline only
      Sysinfo.cpu_percentages.size.should be > 0
      Sysinfo.cpu_percentages.each { |p| (0..100).should contain(p) }
      Sysinfo.refresh_cpu
      Sysinfo.cpu_percentages.each { |p| (0..100).should contain(p) }
    end

    it "samples network counters and rates" do
      Sysinfo.refresh_network # baseline only
      net = Sysinfo.network
      net.should_not be_nil
      net.not_nil!.total_received_kb.should be >= 0
      net.not_nil!.received_kb_s.should eq(0)
      Sysinfo.refresh_network
      Sysinfo.network.not_nil!.received_kb_s.should be >= 0
    end

    it "refreshes the gpu snapshot without raising" do
      Sysinfo.refresh_gpus
      Sysinfo.gpus.each do |gpu|
        gpu.name.should_not be_nil
        if util = gpu.util_percent
          (0..100).should contain(util)
        end
        if percent = gpu.mem_percent
          (0..100).should contain(percent)
        end
      end
    end
  {% end %}
end
