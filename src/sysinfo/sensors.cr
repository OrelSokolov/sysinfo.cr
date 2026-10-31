# Temperature sensors — the machine's hwmon chips on Linux (CPU
# packages and cores, drive controllers, GPUs, ACPI zones, ...), the
# same tree the `sensors` tool reads. Other platforms report no
# sensors (Windows would need WMI, macOS SMC plumbing).

module Sysinfo
  # One temperature sensor; anything the driver does not publish is
  # nil, and no read here can raise into the caller.
  struct Sensor
    getter chip : String  # driver name, e.g. "coretemp", "nvme"
    getter label : String # temp<N>_label, or "temp<N>" without one
    getter temp_c : Int32?
    getter max_c : Int32?
    getter critical_c : Int32?

    def initialize(@chip : String, @label : String, @temp_c : Int32? = nil,
                   @max_c : Int32? = nil, @critical_c : Int32? = nil)
    end
  end

  # Sensor snapshot state; swapped whole by refresh_sensors.
  @@sensors : Array(Sensor) = [] of Sensor

  # Read every supported temperature sensor and swap the snapshot.
  def self.refresh_sensors : Nil
    @@sensors = platform_sensors
  end

  # The last refresh_sensors snapshot (empty until it ran, on platforms
  # without a backend, or with no sensors).
  def self.sensors : Array(Sensor)
    @@sensors
  end
end
