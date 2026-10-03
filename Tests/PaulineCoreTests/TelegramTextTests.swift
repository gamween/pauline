import Testing
@testable import PaulineCore

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
        #expect(TelegramText.closed(.unexpectedRestart, state: onBattery(50)).hasPrefix("Pauline is off (Mac restarted)\n"))
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
