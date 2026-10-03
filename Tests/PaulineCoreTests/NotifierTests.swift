import Testing
@testable import PaulineCore

/// Runs readings through a notifier and returns everything it produced.
private func run(_ readings: [PowerState]) -> [Notice] {
    var notifier = Notifier()
    return readings.flatMap { notifier.check($0) }
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

    @Test func startsOverEachTimePaulineTurnsOn() {
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
