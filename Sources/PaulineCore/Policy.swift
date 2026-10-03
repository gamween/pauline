/// Everything Pauline reads from the system on each check.
public struct PowerState: Equatable, Sendable {
    /// The system-wide `SleepDisabled` flag, set by `pmset -a disablesleep 1`.
    public var sleepDisabled: Bool
    /// True when the Mac runs on its battery rather than a power adapter.
    public var onBattery: Bool
    /// True while the internal battery charges. False on a weak adapter that cannot keep up.
    public var batteryCharging: Bool
    /// Internal battery charge from 0 to 100, nil on Macs without a battery.
    public var batteryPercent: Int?
    public var lidClosed: Bool
    /// The built-in screen is lit (online, active and not asleep).
    public var builtInDisplayAwake: Bool
    public var externalDisplayConnected: Bool
    /// macOS reports a critical thermal state.
    public var overheating: Bool

    public init(
        sleepDisabled: Bool,
        onBattery: Bool = false,
        batteryCharging: Bool = false,
        batteryPercent: Int? = nil,
        lidClosed: Bool = false,
        builtInDisplayAwake: Bool = false,
        externalDisplayConnected: Bool = false,
        overheating: Bool = false
    ) {
        self.sleepDisabled = sleepDisabled
        self.onBattery = onBattery
        self.batteryCharging = batteryCharging
        self.batteryPercent = batteryPercent
        self.lidClosed = lidClosed
        self.builtInDisplayAwake = builtInDisplayAwake
        self.externalDisplayConnected = externalDisplayConnected
        self.overheating = overheating
    }

    /// Closed lid and no monitor: nobody is using this Mac, it may well be in a bag.
    var closedWithoutExternalDisplay: Bool { lidClosed && !externalDisplayConnected }
}

/// What the app must do after a check.
public enum Action: Equatable, Sendable {
    /// Turn `disablesleep` back off.
    case restoreSleep
    /// Put the Mac to sleep right away (`pmset sleepnow`).
    case sleepNow
    /// Turn the screens off (`pmset displaysleepnow`).
    case sleepDisplay
}

/// Why staying awake is not allowed right now.
public enum Danger: Equatable, Sendable {
    case lowBattery
    case overheating
}

/// The safety thresholds, free of system calls so they can be tested.
public struct Policy: Equatable, Sendable {
    /// Battery percentage at or below which Pauline gives sleep back while the battery drains.
    /// 0 disables the floor.
    public var batteryFloor: Int

    public static let defaultBatteryFloor = 20

    public init(batteryFloor: Int = Policy.defaultBatteryFloor) {
        self.batteryFloor = min(max(batteryFloor, 0), 100)
    }

    /// Returns why the Mac must be allowed to sleep, or nil if staying awake is fine.
    /// While `disablesleep` is on, macOS also skips its own emergency sleep for heat and empty
    /// batteries, so Pauline has to watch both.
    public func danger(_ state: PowerState) -> Danger? {
        if state.overheating { return .overheating }
        // Draining: on battery, or plugged into an adapter too weak to charge.
        let draining = state.onBattery || !state.batteryCharging
        if batteryFloor > 0, draining, let percent = state.batteryPercent, percent <= batteryFloor {
            return .lowBattery
        }
        return nil
    }
}

/// The safety rules over time. Remembers the previous reading and a sleep still owed.
public struct Safety: Sendable {
    public var policy: Policy
    /// The Mac must sleep but has not yet. macOS does not put an already closed Mac to sleep
    /// when `disablesleep` goes back to 0, and `pmset sleepnow` can lose a race with that change,
    /// so the request is repeated on every check until the Mac sleeps or the lid opens.
    public private(set) var sleepPending = false
    private var previous: PowerState?

    public init(policy: Policy = Policy()) {
        self.policy = policy
    }

    /// At launch Pauline always gives sleep back, so a crash or a restart never leaves the Mac stuck awake.
    public mutating func launch(_ state: PowerState) -> [Action] {
        previous = state
        guard state.sleepDisabled, state.closedWithoutExternalDisplay else { return [.restoreSleep] }
        sleepPending = true
        return [.restoreSleep, .sleepNow]
    }

    /// Decides what to do after a new reading.
    public mutating func check(_ current: PowerState) -> [Action] {
        defer { previous = current }

        if sleepPending {
            if !current.closedWithoutExternalDisplay {
                sleepPending = false
            } else if !current.sleepDisabled {
                return [.sleepNow]
            } else {
                // Sleep was disabled again from elsewhere, the rules below take over.
                sleepPending = false
            }
        }

        guard current.sleepDisabled else { return [] }

        if policy.danger(current) != nil {
            guard current.closedWithoutExternalDisplay else { return [.restoreSleep] }
            sleepPending = true
            return [.restoreSleep, .sleepNow]
        }

        // Some MacBooks keep the built-in screen lit behind a closed lid. Turn it off once,
        // when that happens, and never touch the screens of a Mac docked to a monitor.
        let screenLeftOn = { (state: PowerState) in state.closedWithoutExternalDisplay && state.builtInDisplayAwake }
        if screenLeftOn(current) && !(previous.map(screenLeftOn) ?? false) {
            return [.sleepDisplay]
        }
        return []
    }

    /// The Mac slept and woke up: any sleep owed has happened.
    public mutating func didWake() {
        sleepPending = false
    }
}
