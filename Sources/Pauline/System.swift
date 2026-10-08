import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import PaulineCore

/// The system-wide sleep flag and the lid, read straight from the kernel and written through pmset.
enum SleepSetting {
    /// `pmset -a disablesleep` is the only setting that also covers a closed lid.
    /// It needs root, so it goes through `sudo -n`, allowed by the rule `install.sh` adds.
    /// `-k` ignores cached sudo credentials, so only that rule can make it pass.
    /// Returns false on command failure, timeout or an unconfirmed flag.
    @discardableResult
    static func setSleepDisabled(_ disabled: Bool) async -> Bool {
        guard await Shell.runAsync("/usr/bin/sudo", ["-k", "-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]) == 0 else { return false }
        return await waitForFlag(disabled: disabled)
    }

    /// powerd applies a change a moment after pmset returns. Waits up to `timeout` seconds for the flag
    /// to read `disabled`, usually a few milliseconds.
    static func waitForFlag(disabled: Bool, timeout: Duration = .seconds(2),
                            read: @Sendable () -> Bool = { isSleepDisabled }) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while read() != disabled {
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        return true
    }

    static func sleepNow() async {
        await Shell.runAsync("/usr/bin/pmset", ["sleepnow"])
    }

    static func sleepDisplayNow() async {
        await Shell.runAsync("/usr/bin/pmset", ["displaysleepnow"])
    }

    static var isSleepDisabled: Bool { rootDomainFlag("SleepDisabled") }
    static var isLidClosed: Bool { rootDomainFlag("AppleClamshellState") }

    /// Reads a boolean property of IOPMrootDomain, the kernel's power manager. No root needed.
    private static func rootDomainFlag(_ key: String) -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return value as? Bool ?? false
    }
}

enum PowerSource {
    /// Whether the Mac runs on battery and, when it has an internal battery, its charge, whether it charges,
    /// whether charging has ended, and the minutes left until full or empty.
    static func read() -> (onBattery: Bool, charging: Bool, percent: Int?, minutesToFull: Int?, minutesToEmpty: Int?, complete: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (false, false, nil, nil, nil, false) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []

        let battery = sources.lazy
            .compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
            .first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
        var percent: Int?
        if let current = battery?[kIOPSCurrentCapacityKey] as? Int,
           let maximum = battery?[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
            percent = current * 100 / maximum
        }
        let charging = battery?[kIOPSIsChargingKey] as? Bool ?? false
        // -1 while macOS is still estimating, 0 when it does not apply (no time to empty while charging).
        let minutesToFull = (battery?[kIOPSTimeToFullChargeKey] as? Int).flatMap { $0 >= 0 ? $0 : nil }
        let minutesToEmpty = (battery?[kIOPSTimeToEmptyKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
        // "Is Charged" only appears once the battery is full.
        let complete = battery?[kIOPSIsChargedKey] as? Bool ?? false
            || battery?["Optimized Battery Charging Engaged"] as? Bool ?? false
        return (providing == kIOPSBatteryPowerValue, charging, percent, minutesToFull, minutesToEmpty, complete)
    }
}

/// When the Mac last booted, to tell a crash of Pauline from a restart of the Mac.
func bootTime() -> Date? {
    var time = timeval()
    var size = MemoryLayout<timeval>.size
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    guard sysctl(&mib, 2, &time, &size, nil, 0) == 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(time.tv_sec))
}

enum Displays {
    /// Whether the built-in screen is lit, and whether any other screen is connected.
    static func read() -> (builtInAwake: Bool, externalConnected: Bool) {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return (false, false) }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return (false, false) }

        var builtInAwake = false
        var externalConnected = false
        for id in ids.prefix(Int(count)) {
            if CGDisplayIsBuiltin(id) != 0 {
                builtInAwake = builtInAwake || (CGDisplayIsActive(id) != 0 && CGDisplayIsAsleep(id) == 0)
            } else {
                externalConnected = true
            }
        }
        return (builtInAwake, externalConnected)
    }
}

extension PowerState {
    /// One reading of everything the safety rules need.
    static func current() -> PowerState {
        let power = PowerSource.read()
        let displays = Displays.read()
        return PowerState(
            sleepDisabled: SleepSetting.isSleepDisabled,
            onBattery: power.onBattery,
            batteryCharging: power.charging,
            batteryPercent: power.percent,
            minutesToFull: power.minutesToFull,
            minutesToEmpty: power.minutesToEmpty,
            chargeComplete: power.complete,
            lidClosed: SleepSetting.isLidClosed,
            builtInDisplayAwake: displays.builtInAwake,
            externalDisplayConnected: displays.externalConnected,
            overheating: ProcessInfo.processInfo.thermalState == .critical
        )
    }
}

enum Shell {
    /// Runtime commands wait on a utility queue, never on AppKit's main thread.
    @discardableResult
    static func runAsync(_ path: String, _ arguments: [String], timeout: Duration = .seconds(2)) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBounded(path, arguments, timeout: timeout))
            }
        }
    }

    /// Only the pre-AppKit launchd handover uses the synchronous entry point.
    @discardableResult
    static func run(_ path: String, _ arguments: String...) -> Int32 {
        runBounded(path, arguments, timeout: .seconds(2))
    }

    /// Returns -1 on spawn failure, signal exit or timeout. The child has its own process group.
    static func runBounded(_ path: String, _ arguments: [String], timeout: Duration) -> Int32 {
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), nil]
        defer { (argv + envp).forEach { free($0) } }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        // Pauline ignores the signals it handles itself. Children start with every signal at its default.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETPGROUP))

        var pid = pid_t()
        guard posix_spawn(&pid, path, &actions, &attributes, argv, envp) == 0 else { return -1 }

        var status: Int32 = 0
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { break }
            if result == -1, errno != EINTR { return -1 }
            if ContinuousClock.now >= deadline {
                // TERM lets sudo forward termination to a privileged child. Kill the remaining
                // process group after a short grace period; reaping must not extend our deadline.
                kill(-pid, SIGTERM)
                usleep(50_000)
                kill(-pid, SIGKILL)
                let child = pid
                let reaper = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .global(qos: .utility))
                reaper.setEventHandler {
                    var discarded: Int32 = 0
                    while waitpid(child, &discarded, WNOHANG) == -1 && errno == EINTR {}
                    reaper.cancel()
                    reaper.setEventHandler {}
                }
                reaper.resume()
                return -1
            }
            usleep(10_000)
        }
        // WIFEXITED and WEXITSTATUS are C macros Swift cannot import.
        let exitedNormally = status & 0x7f == 0
        return exitedNormally ? (status >> 8) & 0xff : -1
    }
}
