import Testing
@testable import PaulineCore

/// Runs readings through a notifier and returns everything it produced.
private func run(_ readings: [PowerState]) -> [Notice] {
    var notifier = Notifier()
    return readings.flatMap { notifier.check($0) }
}

private func onBattery(_ percent: Int, awake: Bool = true) -> PowerState {
    PowerState(sleepDisabled: awake, onBattery: true, batteryPercent: percent)
}

private func charging(_ percent: Int, awake: Bool = true) -> PowerState {
    PowerState(sleepDisabled: awake, batteryCharging: true, batteryPercent: percent)
}

/// Plugged in, not charging, and charging has not ended: a weak adapter.
private func weakAdapter(_ percent: Int, awake: Bool = true) -> PowerState {
    PowerState(sleepDisabled: awake, batteryCharging: false, batteryPercent: percent)
}

/// Plugged in and charging has ended (full, or held by Optimized Battery Charging).
private func charged(_ percent: Int, awake: Bool = true) -> PowerState {
    PowerState(sleepDisabled: awake, batteryCharging: false, batteryPercent: percent, chargeComplete: true)
}

@Suite("Battery reminders")
struct BatteryReminderTests {
    @Test func remindsAt30And20And10() {
        let notices = run([onBattery(35), onBattery(30), onBattery(25), onBattery(20), onBattery(11), onBattery(10)])
        #expect(notices == [.batteryLow(percent: 30), .batteryLow(percent: 20), .batteryLow(percent: 10)])
    }

    @Test func remindsOnlyOncePerLevel() {
        #expect(run([onBattery(31), onBattery(30), onBattery(30), onBattery(29)]) == [.batteryLow(percent: 30)])
    }

    @Test func staysQuietAboutTheLevelFoundWhenTurnedOn() {
        #expect(run([onBattery(25, awake: false), onBattery(25), onBattery(24), onBattery(20)]) == [.batteryLow(percent: 20)])
    }

    @Test func catchesALevelCrossedRightAfterTurningOn() {
        #expect(run([onBattery(31, awake: false), onBattery(30)]) == [.batteryLow(percent: 30)])
    }

    @Test func staysQuietWhenTheCableComesOut() {
        #expect(run([charging(26), onBattery(26), onBattery(21), onBattery(20)]) == [.batteryLow(percent: 20)])
    }

    @Test func catchesALevelCrossedWhenChargingStops() {
        #expect(run([charging(21), weakAdapter(20)]) == [.batteryLow(percent: 20)])
    }

    @Test func remindsAgainAfterChargingWellAboveTheLevel() {
        let notices = run([onBattery(31), onBattery(30), charging(30), charging(45), onBattery(45), onBattery(31), onBattery(30)])
        #expect(notices == [.batteryLow(percent: 30), .batteryLow(percent: 30)])
    }

    @Test func aFlappingAdapterDoesNotRepeatTheReminder() {
        let notices = run([onBattery(31), onBattery(30), charging(31), weakAdapter(30), charging(31), weakAdapter(30)])
        #expect(notices == [.batteryLow(percent: 30)])
    }

    @Test func countsAWeakAdapterAsDraining() {
        #expect(run([weakAdapter(21), weakAdapter(20)]) == [.batteryLow(percent: 20)])
    }

    @Test func staysQuietWhileSleepIsAllowed() {
        #expect(run([onBattery(31, awake: false), onBattery(30, awake: false), onBattery(10, awake: false)]).isEmpty)
    }

    @Test func startsOverEachTimeStayAwakeTurnsOn() {
        let notices = run([onBattery(31), onBattery(30), onBattery(29, awake: false), onBattery(29), onBattery(20)])
        #expect(notices == [.batteryLow(percent: 30), .batteryLow(percent: 20)])
    }

    @Test func desktopMacsGetNoReminder() {
        #expect(run([PowerState(sleepDisabled: true), PowerState(sleepDisabled: true)]).isEmpty)
    }
}

@Suite("Charging done")
struct ChargingDoneTests {
    @Test func saysWhenTheBatteryIsFull() {
        #expect(run([charging(98), charging(100), charged(100)]) == [.chargingDone(percent: 100)])
    }

    @Test func ignoresAPauseOnAWeakAdapter() {
        #expect(run([charging(60), weakAdapter(61), charging(62), weakAdapter(62)]).isEmpty)
    }

    @Test func isNotFooledByUnplugging() {
        #expect(run([charging(100), onBattery(100)]).isEmpty)
    }

    @Test func staysQuietWhenAlreadyChargedAtTurnOn() {
        #expect(run([charged(100, awake: false), charged(100), charged(100)]).isEmpty)
    }

    @Test func doesNotRepeatWhileAFullBatteryDrifts() {
        #expect(run([charging(99), charged(100), charging(95), charged(100)]) == [.chargingDone(percent: 100)])
    }

    @Test func reportsTheHoldAt80ThenTheFullCharge() {
        let notices = run([charging(79), charged(80), charging(85), charging(95), charged(100)])
        #expect(notices == [.chargingDone(percent: 80), .chargingDone(percent: 100)])
    }

    @Test func staysQuietWhenAFullBatteryIsPluggedBackIn() {
        #expect(run([charged(100), onBattery(100), charged(100)]).isEmpty)
        #expect(run([onBattery(97), charged(97)]).isEmpty)
    }

    @Test func staysQuietWhenRepluggingDuringThe80Hold() {
        #expect(run([charging(79), charged(80), onBattery(80), charged(80)]) == [.chargingDone(percent: 80)])
    }

    @Test func reportsAgainAfterADrainAndAFullRecharge() {
        let notices = run([charging(99), charged(100), onBattery(60), charging(70), charging(99), charged(100)])
        #expect(notices == [.chargingDone(percent: 100), .chargingDone(percent: 100)])
    }
}

@Suite("Telegram text")
struct TelegramTextTests {
    @Test func onWithTimeLeft() {
        var state = onBattery(94)
        state.minutesToEmpty = 1_200
        #expect(TelegramText.on(state) == "Pauline is on\nBattery 94%, 20 h left")
    }

    @Test func batteryLines() {
        #expect(TelegramText.battery(onBattery(41)) == "Battery 41%, on battery")
        var charging64 = charging(64)
        charging64.minutesToFull = 72
        #expect(TelegramText.battery(charging64) == "Battery 64%, charging, full in 1 h 12 min")
        #expect(TelegramText.battery(charging(50)) == "Battery 50%, charging")
        #expect(TelegramText.battery(charged(100)) == "Battery 100%, charged")
        #expect(TelegramText.battery(weakAdapter(60)) == "Battery 60%, plugged in, not charging")
        #expect(TelegramText.battery(PowerState(sleepDisabled: false)) == "No battery")
    }

    @Test func timeLeftOnlyOnBattery() {
        var state = charged(80)
        state.minutesToEmpty = 200
        #expect(TelegramText.battery(state) == "Battery 80%, charged")
    }

    @Test func statusSaysOnOrOff() {
        #expect(TelegramText.status(onBattery(41)).hasPrefix("Pauline is on\n"))
        #expect(TelegramText.status(onBattery(41, awake: false)) == "Pauline is off\nBattery 41%, on battery")
    }

    @Test func closingIsBareWhenTurnedOffByHand() {
        for reason in [CloseReason.mac, .telegram, .quit, .stopped, .elsewhere] {
            #expect(TelegramText.closed(reason, state: onBattery(90)) == "Pauline is off\nBattery 90%, on battery")
        }
    }

    @Test func closingSaysWhyOtherwise() {
        #expect(TelegramText.closed(.lowBattery, state: onBattery(5)) == "Pauline is off (battery low)\nBattery 5%, on battery")
        #expect(TelegramText.closed(.overheating, state: charging(70)).hasPrefix("Pauline is off (too hot)\n"))
        #expect(TelegramText.closed(.shutdown, state: onBattery(50)).hasPrefix("Pauline is off (Mac shut down)\n"))
        #expect(TelegramText.closed(.crash, state: onBattery(50)).hasPrefix("Pauline is off (Pauline crashed)\n"))
        #expect(TelegramText.closed(.restart, state: onBattery(50)).hasPrefix("Pauline is off (Mac restarted)\n"))
        #expect(TelegramText.closed(.logout, state: onBattery(50)).hasPrefix("Pauline is off (logged out)\n"))
        #expect(TelegramText.closed(.restarting, state: onBattery(50)).hasPrefix("Pauline is off (Mac restarting)\n"))
    }

    @Test func everyClosingStartsTheSameWay() {
        for reason in CloseReason.allCases {
            #expect(TelegramText.closed(reason, state: onBattery(50)).hasPrefix("Pauline is off"))
        }
    }

    @Test func durations() {
        #expect(TelegramText.duration(0) == "under 1 min")
        #expect(TelegramText.duration(45) == "45 min")
        #expect(TelegramText.duration(60) == "1 h")
        #expect(TelegramText.duration(135) == "2 h 15 min")
    }
}
