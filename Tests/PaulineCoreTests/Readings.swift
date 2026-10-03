@testable import PaulineCore

// Readings shared by the test suites.

func onBattery(_ percent: Int, awake: Bool = true) -> PowerState {
    PowerState(sleepDisabled: awake, onBattery: true, batteryPercent: percent)
}

func charging(_ percent: Int, awake: Bool = true) -> PowerState {
    PowerState(sleepDisabled: awake, batteryCharging: true, batteryPercent: percent)
}

/// Plugged in, not charging, and charging has not ended: a weak adapter.
func weakAdapter(_ percent: Int, awake: Bool = true) -> PowerState {
    PowerState(sleepDisabled: awake, batteryCharging: false, batteryPercent: percent)
}

/// Plugged in and charging has ended (full, or held by Optimized Battery Charging).
func charged(_ percent: Int, awake: Bool = true) -> PowerState {
    PowerState(sleepDisabled: awake, batteryCharging: false, batteryPercent: percent, chargeComplete: true)
}
