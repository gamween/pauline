import AppKit
import PaulineCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var safety = Safety()
    private var permitted = true
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var signalSources: [DispatchSourceSignal] = []

    /// `defaults write com.gamween.pauline BatteryFloor -int 30`, read on every check.
    private var policy: Policy {
        let floor = UserDefaults.standard.object(forKey: "BatteryFloor") as? Int
        return Policy(batteryFloor: floor ?? Policy.defaultBatteryFloor)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(buttonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        restoreSleepOnSignals()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil
        )

        // Fail safe: every launch gives sleep back, so a crash, a force quit or a restart
        // (the flag survives reboots) never leaves the Mac stuck awake. Doubles as a permission check.
        safety.policy = policy
        perform(safety.launch(PowerState.current()))

        let timer = Timer(timeInterval: 5, target: self, selector: #selector(check), userInfo: nil, repeats: true)
        timer.tolerance = 1
        // Common modes keep the checks running while a menu or an alert is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        check()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if SleepSetting.isSleepDisabled {
            SleepSetting.setSleepDisabled(false)
        }
    }

    // MARK: Checks

    @objc private func check() {
        safety.policy = policy
        let reading = PowerState.current()
        let actions = safety.check(reading)
        perform(actions)
        render(actions.isEmpty ? reading : PowerState.current())
    }

    private func perform(_ actions: [Action]) {
        for action in actions {
            switch action {
            case .restoreSleep:
                permitted = SleepSetting.setSleepDisabled(false)
                if permitted, actions.contains(.sleepNow) {
                    // sleepnow is refused until powerd has applied the change. Safety retries anyway.
                    SleepSetting.waitForSleepAllowed()
                }
            case .sleepNow:
                SleepSetting.sleepNow()
            case .sleepDisplay:
                SleepSetting.sleepDisplayNow()
            }
        }
    }

    private func render(_ state: PowerState) {
        statusItem.button?.image = SwitchIcon.image(on: state.sleepDisabled)
        statusItem.button?.toolTip = StatusText.tooltip(state)

        // Without this, App Nap could delay the battery and lid checks while the Mac runs lid closed.
        if state.sleepDisabled, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Watching the battery while the Mac stays awake"
            )
        } else if !state.sleepDisabled, let running = activity {
            ProcessInfo.processInfo.endActivity(running)
            activity = nil
        }
    }

    @objc private func didWake() {
        safety.didWake()
    }

    // MARK: Clicks

    @objc private func buttonClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            toggle()
        }
    }

    @objc private func toggle() {
        let state = PowerState.current()
        let turningOn = !state.sleepDisabled
        let policy = self.policy

        if turningOn, let danger = policy.danger(state) {
            let refusal = StatusText.refusal(danger, policy: policy)
            alert(refusal.title, refusal.message)
            return
        }
        permitted = SleepSetting.setSleepDisabled(turningOn)
        if !permitted {
            alert(
                "Pauline is not allowed to change sleep",
                "Run ./install.sh from the Pauline folder again. It asks for your password once to allow it."
            )
        }
        render(PowerState.current())
    }

    private func showMenu() {
        let state = PowerState.current()
        render(state)
        let menu = NSMenu()
        menu.addItem(info(StatusText.headline(state)))
        if let battery = StatusText.battery(state, policy: policy) {
            menu.addItem(info(battery))
        }
        if !permitted {
            menu.addItem(info("Not allowed yet, run ./install.sh"))
        }
        menu.addItem(.separator())
        let toggleItem = NSMenuItem(title: StatusText.toggleTitle(state), action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Pauline", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func alert(_ title: String, _ message: String) {
        // An accessory app has to force itself forward, or the alert opens behind other windows.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: Lifecycle

    /// launchd stops agents with SIGTERM at logout. Quit cleanly so sleep comes back.
    private func restoreSleepOnSignals() {
        for code in [SIGTERM, SIGINT, SIGHUP] {
            signal(code, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: code, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
