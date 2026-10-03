/// Something worth a Telegram message while Pauline is on.
public enum Notice: Equatable, Sendable {
    /// The battery went down past one of the reminder levels.
    case batteryLow(percent: Int)
    /// Plugged in and charging has ended: full, or held at 80% by Optimized Battery Charging.
    case chargingDone(percent: Int)
}

/// Decides when to send a reminder, from one reading to the next.
/// Opening and closing messages are not here: they follow Pauline turning on and off.
public struct Notifier: Sendable {
    /// Battery levels that get a reminder, once each per discharge.
    static let reminderLevels = [30, 20, 10]
    /// How far the battery must charge back above a level before its reminder can fire again.
    static let rearmMargin = 5
    /// How far the charge must move from the last "charging done" before another one,
    /// so a full battery drifting between 95% and 100% stays quiet while 80% then 100% does not.
    static let chargeMargin = 10

    private var reminded: Set<Int> = []
    private var lastChargedPercent: Int?
    /// A charge was watched on the adapter since the last battery reading: replugging a full battery is not one.
    private var sawCharging = false
    private var previous: PowerState?

    public init() {}

    public mutating func check(_ current: PowerState) -> [Notice] {
        defer { previous = current }
        guard current.sleepDisabled else {
            reminded = []
            lastChargedPercent = nil
            sawCharging = false
            return []
        }
        guard let percent = current.batteryPercent else { return [] }
        let wasOn = previous?.sleepDisabled ?? false
        var notices: [Notice] = []

        if current.draining {
            let crossed = Set(Self.reminderLevels.filter { percent <= $0 }).subtracting(reminded)
            reminded.formUnion(crossed)
            // A level counts when the battery went past it while watched. When the drain just started
            // (Pauline turned on, cable out, charging stopped), levels at or above the previous
            // reading were already behind: they are the starting point, without a message.
            let watched = wasOn && (previous?.draining ?? false)
            let startingPoint = watched ? Int.max : (previous?.batteryPercent ?? percent)
            if crossed.contains(where: { $0 < startingPoint }) {
                notices.append(.batteryLow(percent: percent))
            }
        } else {
            reminded = reminded.filter { percent < $0 + Self.rearmMargin }
        }

        if current.onBattery {
            lastChargedPercent = nil
            sawCharging = false
        } else if current.batteryCharging {
            sawCharging = true
        }
        if let last = lastChargedPercent, abs(percent - last) >= Self.chargeMargin {
            lastChargedPercent = nil
        }
        if !current.onBattery, !current.batteryCharging, current.chargeComplete, lastChargedPercent == nil {
            lastChargedPercent = percent
            // Already charged when Pauline turned on, or plugged in already full: nothing was watched charging.
            if wasOn, sawCharging {
                notices.append(.chargingDone(percent: percent))
            }
        }
        return notices
    }
}
