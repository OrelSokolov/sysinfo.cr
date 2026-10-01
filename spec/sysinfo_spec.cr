require "spec"
require "../src/sysinfo"

describe Sysinfo do
  it "computes memory used/percent" do
    mem = Sysinfo::Memory.new(1000, 250)
    mem.used_kb.should eq(750)
    mem.percent.should eq(75)
    Sysinfo::Memory.new(0, 0).percent.should eq(0)
  end

  it "reports unknown tree memory for nil pid" do
    Sysinfo.process_tree_memory_kb(nil).should eq(0)
  end

  {% if flag?(:linux) %}
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
  {% end %}
end
