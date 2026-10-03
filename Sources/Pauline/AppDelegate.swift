import AppKit
import PaulineCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let telegram = TelegramBot()
    private var safety = Safety()
    private var notifier = Notifier()
    private var permitted = true
    /// While a closing message is on its way, a closed Mac waits for it before sleeping (10 s at most).
    private var sleepHeldUntil: Date?
    /// Why Pauline is quitting, for the closing message: set by a signal or a shutdown.
    private var quitReason = CloseReason.quit
    private var isTerminating = false
    /// "Could not turn stay awake off" goes out once per session, not every 5 s.
    private var warnedCouldNotTurnOff = false
    /// Pauline closed the session during this check: the flag it just changed may still read the old value.
    private var closedThisCheck = false
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var signalSources: [DispatchSourceSignal] = []

    /// `defaults write com.gamween.pauline BatteryFloor -int 10`, read on every check.
    private var policy: Policy {
        let floor = UserDefaults.standard.object(forKey: "BatteryFloor") as? Int
        return Policy(batteryFloor: floor ?? Policy.defaultBatteryFloor)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(buttonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        restoreSleepOnSignals()
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(willPowerOff), name: NSWorkspace.willPowerOffNotification, object: nil)

        // Fail safe: every launch gives sleep back, so a crash, a force quit or a restart
        // (the flag survives reboots) never leaves the Mac stuck awake. Doubles as a permission check.
        safety.policy = policy
        let actions = safety.launch(PowerState.current())
        perform(actions.filter { $0 == .restoreSleep })

        // A session a crash, a restart or an offline quit left open gets its closing message,
        // once it is known whether sleep really came back.
        telegram.onCommand = { [weak self] command in self?.handle(command) }
        telegram.start(bootedAt: bootTime(), state: PowerState.current())

        // A closed Mac waits for that closing message before it sleeps.
        if actions.contains(.sleepNow) {
            if telegram.hasPendingMessages {
                sleepHeldUntil = Date().addingTimeInterval(10)
                releaseHeldSleepAfterDrain()
            } else {
                perform([.sleepNow])
            }
        }

        let timer = Timer(timeInterval: 5, target: self, selector: #selector(check), userInfo: nil, repeats: true)
        timer.tolerance = 1
        // Common modes keep the checks running while a menu or an alert is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        check()
    }

    /// Quit, logout, shutdown or a signal: give sleep back and let the closing message leave first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        timer?.invalidate()
        // Quitting: no more clicks that could start a new session behind the closing message.
        statusItem.isVisible = false
        if let reason = Self.quitReasonFromMacOS() {
            quitReason = reason
        }
        let state = PowerState.current()
        if state.sleepDisabled {
            permitted = SleepSetting.setSleepDisabled(false)
        }
        if state.sleepDisabled, !permitted {
            // Still awake: say so, and keep the session on disk for the next launch to close as a quit.
            telegram.keepOpenAfterQuit()
            telegram.notify(TelegramText.quitStillAwake, allowSleepButton: false)
        } else {
            telegram.close(quitReason, state: state)
        }
        guard telegram.hasPendingMessages else { return .terminateNow }

        Task {
            // launchd sends SIGKILL a few seconds after SIGTERM.
            await telegram.drain(timeout: quitReason == .stopped ? 4 : 5)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Logout, restart or shutdown, as named by the quit Apple event macOS sends.
    private static func quitReasonFromMacOS() -> CloseReason? {
        let event = NSAppleEventManager.shared().currentAppleEvent
        guard let why = event?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue else { return nil }
        switch why {
        case kAELogOut, kAEReallyLogOut: return .logout
        case kAERestart, kAEShowRestartDialog: return .restarting
        case kAEShutDown, kAEShowShutdownDialog: return .shutdown
        default: return nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if SleepSetting.isSleepDisabled {
            SleepSetting.setSleepDisabled(false)
        }
    }

    // MARK: Checks

    @objc private func check() {
        guard !isTerminating else { return }
        closedThisCheck = false
        let policy = self.policy
        safety.policy = policy
        let reading = PowerState.current()

        for notice in notifier.check(reading) {
            switch notice {
            case .batteryLow:
                telegram.notify(TelegramText.on(reading), allowSleepButton: true)
            case .chargingDone:
                telegram.notify(TelegramText.on(reading), allowSleepButton: false)
            }
        }

        let actions = safety.check(reading)
        if reading.sleepDisabled, actions.contains(.restoreSleep) {
            // Pauline gives sleep back on its own: battery floor or heat.
            let reason: CloseReason = policy.danger(reading) == .overheating ? .overheating : .lowBattery
            giveSleepBack(actions, reason: reason, state: reading)
        } else {
            perform(actions)
        }

        let state = actions.isEmpty ? reading : PowerState.current()
        if !state.sleepDisabled {
            warnedCouldNotTurnOff = false
        }
        // Right after Pauline closed the session the flag may read stale: the next check reconciles.
        if !closedThisCheck {
            telegram.sync(state)
        }
        render(state)
    }

    /// The one way Pauline turns stay awake off: switch, menu, Telegram, battery floor or heat.
    /// Sleep comes back right away; a closed Mac waits for the closing message before it sleeps.
    private func giveSleepBack(_ actions: [Action], reason: CloseReason, state: PowerState) {
        let sleeping = actions.contains(.sleepNow)
        if sleeping, telegram.isLinked {
            sleepHeldUntil = Date().addingTimeInterval(10)
        }
        perform(actions)

        guard permitted else {
            // pmset refused: stay awake is still on, say so instead of closing the session.
            // Every /off gets its answer; the automatic tries warn once.
            sleepHeldUntil = nil
            if reason == .telegram {
                telegram.reply(TelegramText.couldNotTurnOff)
            } else if !warnedCouldNotTurnOff {
                warnedCouldNotTurnOff = true
                telegram.notify(TelegramText.couldNotTurnOff, allowSleepButton: false)
            }
            return
        }
        warnedCouldNotTurnOff = false
        closedThisCheck = true
        telegram.close(reason, state: state)
        if sleeping, telegram.isLinked {
            releaseHeldSleepAfterDrain()
        }
    }

    private func releaseHeldSleepAfterDrain() {
        Task {
            await telegram.drain(timeout: 10)
            releaseHeldSleep()
        }
    }

    private func perform(_ actions: [Action]) {
        for action in actions {
            switch action {
            case .restoreSleep:
                permitted = SleepSetting.setSleepDisabled(false)
                if permitted {
                    // powerd applies it a moment later: until then sleepnow is refused and the flag reads stale.
                    SleepSetting.waitForFlag(disabled: false)
                }
            case .sleepNow:
                if let until = sleepHeldUntil, Date() < until { continue }
                SleepSetting.sleepNow()
            case .sleepDisplay:
                SleepSetting.sleepDisplayNow()
            }
        }
    }

    /// The closing message went out (or gave up): a closed Mac can sleep now if it still has to.
    /// Decided on a fresh reading, so a Mac opened in the meantime stays awake.
    private func releaseHeldSleep() {
        guard sleepHeldUntil != nil else { return }
        sleepHeldUntil = nil
        perform(safety.check(PowerState.current()))
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

    @objc private func willPowerOff() {
        quitReason = .shutdown
    }

    // MARK: Telegram commands

    private func handle(_ command: TelegramBot.Command) {
        let state = PowerState.current()
        switch command {
        case .status:
            telegram.reply(TelegramText.status(state))
        case .off:
            guard state.sleepDisabled else {
                telegram.reply(TelegramText.alreadyOff)
                return
            }
            giveSleepBack(safety.allowSleep(state), reason: .telegram, state: state)
            render(PowerState.current())
        }
    }

    // MARK: Clicks

    @objc private func buttonClicked() {
        guard !isTerminating else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            toggle()
        }
    }

    @objc private func toggle() {
        guard !isTerminating else { return }
        let state = PowerState.current()
        let policy = self.policy

        if state.sleepDisabled {
            giveSleepBack(safety.allowSleep(state), reason: .mac, state: state)
        } else {
            if let danger = policy.danger(state) {
                let refusal = StatusText.refusal(danger, policy: policy)
                alert(refusal.title, refusal.message)
                return
            }
            permitted = SleepSetting.setSleepDisabled(true)
            if permitted {
                SleepSetting.waitForFlag(disabled: true)
                telegram.sync(PowerState.current())
            }
        }
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
        menu.addItem(item(StatusText.toggleTitle(state), #selector(toggle)))
        menu.addItem(.separator())
        if let problem = telegram.problem {
            menu.addItem(info(problem))
        }
        if telegram.isLinked, let bot = telegram.botUsername {
            if telegram.problem == nil {
                menu.addItem(info("Telegram: @\(bot)"))
            }
            menu.addItem(item("Disconnect Telegram", #selector(disconnectTelegram)))
        } else if telegram.isWaitingForStart {
            menu.addItem(info("Telegram: tap Start in the bot chat"))
            menu.addItem(item("Open the Bot Chat…", #selector(openBotChat)))
            menu.addItem(item("Disconnect Telegram", #selector(disconnectTelegram)))
        } else {
            menu.addItem(item("Connect Telegram…", #selector(connectTelegram)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit Pauline", #selector(quit)))

        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: Telegram setup

    @objc private func quit() {
        guard !isTerminating else { return }
        NSApp.terminate(nil)
    }

    @objc private func connectTelegram() {
        guard !isTerminating else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "123456789:AAH..."
        let alert = NSAlert()
        alert.messageText = "Connect Telegram"
        alert.informativeText = """
            1. Click Open BotFather, send /newbot and follow the steps.
            2. Paste the token BotFather gives you below.
            3. Tap Start in the chat with your bot.

            Use a new bot for each Mac.
            """
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open BotFather")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let token = field.stringValue
            Task {
                do {
                    _ = try await telegram.connect(token: token)
                    afterThisTask { $0.openBotChat() }
                } catch {
                    let message = error.localizedDescription
                    afterThisTask { $0.alert("Telegram is not connected", message) }
                }
            }
        case .alertThirdButtonReturn:
            open(telegramApp: "tg://resolve?domain=BotFather", web: "https://t.me/BotFather")
            connectTelegram()
        default:
            break
        }
    }

    /// Opens the bot chat with the Start link, and shows it as a QR code for a phone.
    @objc private func openBotChat() {
        guard !isTerminating, let link = telegram.startLink, let bot = telegram.botUsername,
              let code = link.query?.replacingOccurrences(of: "start=", with: "") else { return }
        open(telegramApp: "tg://resolve?domain=\(bot)&start=\(code)", web: link.absoluteString)

        let alert = NSAlert()
        alert.messageText = "Tap Start in Telegram"
        alert.informativeText = """
            Telegram opens the chat with @\(bot). Tap Start, and Pauline answers that it is connected.

            Telegram is on your phone only? Scan this code with it.
            """
        if let image = qrCode(for: link, size: 180) {
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 180, height: 180))
            view.image = image
            alert.accessoryView = view
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Opens Telegram for Mac directly when it is installed, the web link otherwise.
    private func open(telegramApp: String, web: String) {
        if let app = URL(string: telegramApp), NSWorkspace.shared.urlForApplication(toOpen: app) != nil {
            NSWorkspace.shared.open(app)
        } else if let url = URL(string: web) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func disconnectTelegram() {
        guard !isTerminating else { return }
        // Settle the session first, so the last message says the truth about Pauline.
        telegram.sync(PowerState.current())
        Task {
            if await telegram.disconnect() == false {
                afterThisTask { $0.alert("Telegram was not told", "No internet: the chat keeps its last message.") }
            }
        }
    }

    /// Runs a modal alert outside the current MainActor job. A modal run from inside a Task or a
    /// main queue block would freeze every other MainActor job, Telegram polling included, until it closes.
    private func afterThisTask(_ body: @escaping @MainActor (AppDelegate) -> Void) {
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                if let self { body(self) }
            }
        }
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

    /// The menu bar never shows it, but without an Edit menu Cmd+V cannot paste the bot token.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    /// launchd stops agents with SIGTERM at logout or on reinstall. Quit cleanly so sleep comes back
    /// and the session gets its closing message.
    private func restoreSleepOnSignals() {
        for code in [SIGTERM, SIGINT, SIGHUP] {
            signal(code, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: code, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isTerminating else { return }
                    if self.quitReason == .quit {
                        self.quitReason = .stopped
                    }
                    // Not from this main queue block: AppKit would wait for the closing message inside it,
                    // and the main queue (the send included) could not run until it returned.
                    RunLoop.main.perform(inModes: [.common]) {
                        MainActor.assumeIsolated { NSApp.terminate(nil) }
                    }
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
