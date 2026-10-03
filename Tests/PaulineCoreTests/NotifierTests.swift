import Foundation
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
    let policy = Policy()
    let paris = TimeZone(identifier: "Europe/Paris")!
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func statusWhileCharging() {
        let state = PowerState(sleepDisabled: true, batteryCharging: true, batteryPercent: 64, minutesToFull: 72, lidClosed: true)
        #expect(TelegramText.status(state) == "Stay awake: on, lid closed\nBattery: 64%, charging, full in 1 h 12 min")
    }

    @Test func statusOtherwise() {
        #expect(TelegramText.battery(onBattery(41, awake: false)) == "Battery: 41%, not charging")
        #expect(TelegramText.battery(charged(80)) == "Battery: 80%, not charging, on power adapter")
        #expect(TelegramText.battery(charging(50)) == "Battery: 50%, charging")
        #expect(TelegramText.battery(PowerState(sleepDisabled: false)) == "No battery")
        #expect(TelegramText.status(onBattery(41, awake: false)).hasPrefix("Stay awake: off\n"))
    }

    @Test func timeLeftOnBattery() {
        var state = onBattery(41)
        state.minutesToEmpty = 200
        #expect(TelegramText.battery(state) == "Battery: 41%, not charging, 3 h 20 min left")
        state.lidClosed = true
        #expect(
            TelegramText.reminder(percent: 41, state: state, policy: policy)
                == "Battery at 41%, 3 h 20 min left. Your Mac is still awake, lid closed. Stay awake turns off on its own at 5%."
        )
    }

    @Test func noTimeLeftWhilePlugged() {
        var state = charged(80)
        state.minutesToEmpty = 200
        #expect(TelegramText.battery(state) == "Battery: 80%, not charging, on power adapter")
        #expect(TelegramText.reminder(percent: 20, state: state, policy: policy).hasPrefix("Battery at 20%. "))
    }

    @Test func opening() {
        #expect(TelegramText.started(charging(50)) == "Stay awake is on, lid open.\nBattery: 50%, charging")
    }

    @Test func durations() {
        #expect(TelegramText.duration(0) == "under 1 min")
        #expect(TelegramText.duration(45) == "45 min")
        #expect(TelegramText.duration(60) == "1 h")
        #expect(TelegramText.duration(135) == "2 h 15 min")
    }

    @Test func reminderSaysWhenStayAwakeStops() {
        var state = onBattery(20)
        state.lidClosed = true
        #expect(
            TelegramText.reminder(percent: 20, state: state, policy: policy)
                == "Battery at 20%. Your Mac is still awake, lid closed. Stay awake turns off on its own at 5%."
        )
    }

    @Test func closingRightAway() {
        let end = start.addingTimeInterval(12_600)
        let text = TelegramText.closed(.lowBattery, start: start, end: end, sleeping: true, policy: policy, timeZone: paris, now: end)
        #expect(text.hasPrefix("Stay awake is off. Battery reached 5%.\nOn from "))
        #expect(text.contains("(3 h 30 min)."))
        #expect(text.hasSuffix("\nYour Mac is going to sleep."))
    }

    @Test func closingAfterACrash() {
        let text = TelegramText.closed(.crash, start: start, end: nil, sleeping: nil, policy: policy, timeZone: paris, now: start)
        #expect(text.hasPrefix("Stay awake is off. Pauline stopped unexpectedly and started again.\nIt had been on since "))
        #expect(!text.contains("sleep"))
    }

    @Test func everyReasonReadsAsSleepNeverShutdownOfTheApp() {
        for reason in CloseReason.allCases {
            let text = TelegramText.closed(reason, start: start, end: start, sleeping: false, policy: policy, timeZone: paris, now: start)
            #expect(text.hasPrefix("Stay awake is off. "))
            #expect(text.hasSuffix("Normal sleep is back."))
        }
    }

    @Test func clockUsesTheGivenTimeZone() {
        // 1_790_000_000 is 2026-09-21 14:13:20 UTC, 16:13 in Paris.
        let end = start.addingTimeInterval(60)
        let text = TelegramText.closed(.mac, start: start, end: end, sleeping: nil, policy: policy, timeZone: paris, now: end)
        #expect(text.contains("On from 16:13 to 16:14 (1 min)."))
    }

    @Test func durationMatchesThePrintedTimes() {
        // 16:13:59 to 16:14:00 reads as one minute, like the two times say.
        let from = start.addingTimeInterval(39), to = start.addingTimeInterval(40)
        let text = TelegramText.closed(.mac, start: from, end: to, sleeping: nil, policy: policy, timeZone: paris, now: to)
        #expect(text.contains("On from 16:13 to 16:14 (1 min)."))
    }

    @Test func addsTheDayAcrossMidnight() {
        // 2026-09-20 23:50 to 2026-09-21 00:10 in Paris, a Sunday night.
        let from = Date(timeIntervalSince1970: 1_789_941_000), to = from.addingTimeInterval(1_200)
        let text = TelegramText.closed(.mac, start: from, end: to, sleeping: nil, policy: policy, timeZone: paris, now: to)
        #expect(text.contains("On from Sun 23:50 to 00:10 (20 min)."))
    }

    @Test func aLateClosingNamesTheDay() {
        let text = TelegramText.closed(
            .restart, start: start, end: nil, sleeping: nil, policy: policy, timeZone: paris, now: start.addingTimeInterval(86_400)
        )
        #expect(text.hasSuffix("It had been on since Mon 16:13."))
    }
}
