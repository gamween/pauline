import Testing
@testable import PaulineCore

@Suite("Battery floor")
struct BatteryFloorTests {
    let policy = Policy(batteryFloor: 20)

    @Test func triggersAtTheFloorOnBattery() {
        #expect(policy.danger(PowerState(sleepDisabled: true, onBattery: true, batteryPercent: 20)) == .lowBattery)
    }

    @Test func staysQuietAboveTheFloor() {
        #expect(policy.danger(PowerState(sleepDisabled: true, onBattery: true, batteryPercent: 21)) == nil)
    }

    @Test func ignoresTheFloorWhileCharging() {
        let state = PowerState(sleepDisabled: true, onBattery: false, batteryCharging: true, batteryPercent: 5)
        #expect(policy.danger(state) == nil)
    }

    @Test func triggersOnAnAdapterTooWeakToCharge() {
        let state = PowerState(sleepDisabled: true, onBattery: false, batteryCharging: false, batteryPercent: 15)
        #expect(policy.danger(state) == .lowBattery)
    }

    @Test func zeroDisablesTheFloor() {
        #expect(Policy(batteryFloor: 0).danger(PowerState(sleepDisabled: true, onBattery: true, batteryPercent: 3)) == nil)
    }

    @Test func clampsOutOfRangeFloors() {
        #expect(Policy(batteryFloor: -5).batteryFloor == 0)
        #expect(Policy(batteryFloor: 250).batteryFloor == 100)
    }

    @Test func desktopMacsHaveNoFloor() {
        #expect(policy.danger(PowerState(sleepDisabled: true, onBattery: false, batteryPercent: nil)) == nil)
    }

    @Test func overheatingAlwaysCounts() {
        let state = PowerState(sleepDisabled: true, onBattery: false, batteryCharging: true, batteryPercent: 90, overheating: true)
        #expect(policy.danger(state) == .overheating)
    }
}

@Suite("Giving sleep back")
struct GivingSleepBackTests {
    let lowOnDesk = PowerState(sleepDisabled: true, onBattery: true, batteryPercent: 12)

    @Test func restoresSleepWithTheLidOpen() {
        var safety = Safety()
        #expect(safety.check(lowOnDesk) == [.restoreSleep])
        #expect(!safety.sleepPending)
    }

    @Test func alsoSleepsNowWhenTheLidIsClosed() {
        var safety = Safety()
        var closed = lowOnDesk
        closed.lidClosed = true
        #expect(safety.check(closed) == [.restoreSleep, .sleepNow])
        #expect(safety.sleepPending)
    }

    @Test func neverForcesSleepOnADockedMac() {
        var safety = Safety()
        var docked = lowOnDesk
        docked.lidClosed = true
        docked.externalDisplayConnected = true
        #expect(safety.check(docked) == [.restoreSleep])
    }

    @Test func doesTheSameWhenTooHot() {
        var safety = Safety()
        let hot = PowerState(sleepDisabled: true, batteryCharging: true, batteryPercent: 80, lidClosed: true, overheating: true)
        #expect(safety.check(hot) == [.restoreSleep, .sleepNow])
    }

    @Test func keepsAskingUntilTheMacSleeps() {
        var safety = Safety()
        var closed = lowOnDesk
        closed.lidClosed = true
        _ = safety.check(closed)
        // The flag is back to 0 but the Mac is still awake on the next check.
        closed.sleepDisabled = false
        #expect(safety.check(closed) == [.sleepNow])
        #expect(safety.check(closed) == [.sleepNow])
    }

    @Test func stopsAskingOnceTheMacHasSlept() {
        var safety = Safety()
        var closed = lowOnDesk
        closed.lidClosed = true
        _ = safety.check(closed)
        safety.didWake()
        closed.sleepDisabled = false
        #expect(safety.check(closed).isEmpty)
    }

    @Test func stopsAskingWhenTheLidOpens() {
        var safety = Safety()
        var state = lowOnDesk
        state.lidClosed = true
        _ = safety.check(state)
        state.sleepDisabled = false
        state.lidClosed = false
        #expect(safety.check(state).isEmpty)
        #expect(!safety.sleepPending)
    }

    @Test func doesNothingWhileSleepIsAllowed() {
        var safety = Safety()
        #expect(safety.check(PowerState(sleepDisabled: false, onBattery: true, batteryPercent: 2, lidClosed: true)).isEmpty)
    }
}

@Suite("Launch")
struct LaunchTests {
    @Test func alwaysRestoresSleep() {
        var safety = Safety()
        #expect(safety.launch(PowerState(sleepDisabled: false)) == [.restoreSleep])
        #expect(safety.launch(PowerState(sleepDisabled: true)) == [.restoreSleep])
    }

    @Test func putsAClosedMacToSleep() {
        var safety = Safety()
        #expect(safety.launch(PowerState(sleepDisabled: true, lidClosed: true)) == [.restoreSleep, .sleepNow])
        #expect(safety.sleepPending)
    }
}

@Suite("Closed lid screen")
struct ClosedLidScreenTests {
    let litBehindLid = PowerState(sleepDisabled: true, batteryCharging: true, lidClosed: true, builtInDisplayAwake: true)

    @Test func turnsTheScreenOffWhenItStaysLit() {
        var safety = Safety()
        _ = safety.check(PowerState(sleepDisabled: true, batteryCharging: true, builtInDisplayAwake: true))
        #expect(safety.check(litBehindLid) == [.sleepDisplay])
    }

    @Test func doesItOnlyOnce() {
        var safety = Safety()
        _ = safety.check(litBehindLid)
        #expect(safety.check(litBehindLid).isEmpty)
    }

    @Test func leavesAnAlreadyDarkScreenAlone() {
        var safety = Safety()
        var dark = litBehindLid
        dark.builtInDisplayAwake = false
        #expect(safety.check(dark).isEmpty)
    }

    @Test func neverTouchesTheScreensOfADockedMac() {
        var safety = Safety()
        var docked = litBehindLid
        docked.externalDisplayConnected = true
        #expect(safety.check(docked).isEmpty)
    }
}

@Suite("Status text")
struct StatusTextTests {
    let policy = Policy(batteryFloor: 20)

    @Test func describesBothStates() {
        #expect(StatusText.headline(PowerState(sleepDisabled: true)) == "Awake, even with the lid closed")
        #expect(StatusText.headline(PowerState(sleepDisabled: false)) == "Sleeping normally")
    }

    @Test func describesTheBattery() {
        #expect(StatusText.battery(PowerState(sleepDisabled: true), policy: policy) == nil)
        #expect(
            StatusText.battery(PowerState(sleepDisabled: true, onBattery: true, batteryPercent: 72), policy: policy)
                == "Battery 72%, sleeps again at 20%"
        )
        #expect(
            StatusText.battery(PowerState(sleepDisabled: true, batteryCharging: true, batteryPercent: 72), policy: policy)
                == "Battery 72%, charging"
        )
        #expect(
            StatusText.battery(PowerState(sleepDisabled: true, batteryPercent: 100), policy: policy)
                == "Battery 100%, on power adapter"
        )
    }

    @Test func explainsRefusals() {
        #expect(StatusText.refusal(.lowBattery, policy: policy).message.contains("20%"))
        #expect(StatusText.refusal(.overheating, policy: policy).title == "Mac too hot")
    }
}
