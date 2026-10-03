import Testing
@testable import PaulineCore

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
                == "Battery 100%, plugged in"
        )
    }

    @Test func explainsRefusals() {
        #expect(StatusText.refusal(.lowBattery, policy: policy).message.contains("20%"))
        #expect(StatusText.refusal(.overheating, policy: policy).title == "Mac too hot")
    }
}
