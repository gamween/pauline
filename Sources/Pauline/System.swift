import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import PaulineCore

/// The system-wide sleep flag and the lid, read straight from the kernel and written through pmset.
enum SleepSetting {
    /// `pmset -a disablesleep` is the only switch that also covers a closed lid.
    /// It needs root, so it goes through `sudo -n`, allowed by the rule `install.sh` adds.
    /// `-k` ignores cached sudo credentials, so only that rule can make it pass.
    /// Returns false when the rule is missing.
    @discardableResult
    static func setSleepDisabled(_ disabled: Bool) -> Bool {
        Shell.run("/usr/bin/sudo", "-k", "-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0") == 0
    }

    /// powerd applies the change a moment after pmset returns. Waits up to `timeout` seconds for it.
    static func waitForSleepAllowed(timeout: Double = 2) {
        var waited = 0.0
        while isSleepDisabled, waited < timeout {
            usleep(50_000)
            waited += 0.05
        }
    }

    static func sleepNow() {
        Shell.run("/usr/bin/pmset", "sleepnow")
    }

    static func sleepDisplayNow() {
        Shell.run("/usr/bin/pmset", "displaysleepnow")
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
    /// Whether the Mac runs on battery, whether the internal battery charges, and its charge if there is one.
    static func read() -> (onBattery: Bool, charging: Bool, percent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (false, false, nil) }
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
        return (providing == kIOPSBatteryPowerValue, charging, percent)
    }
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
            lidClosed: SleepSetting.isLidClosed,
            builtInDisplayAwake: displays.builtInAwake,
            externalDisplayConnected: displays.externalConnected,
            overheating: ProcessInfo.processInfo.thermalState == .critical
        )
    }
}

enum Shell {
    /// Runs a program, waits for it and returns its exit code (-1 if it could not run or crashed).
    /// Uses posix_spawn and waitpid rather than Process, whose waitUntilExit spins the run loop
    /// and could let a timer tick fire in the middle of a toggle.
    @discardableResult
    static func run(_ path: String, _ arguments: String...) -> Int32 {
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), nil]
        defer { (argv + envp).forEach { free($0) } }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        // Pauline ignores SIGTERM, SIGINT and SIGHUP to quit cleanly. Children get the defaults back.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for code in [SIGTERM, SIGINT, SIGHUP] {
            sigaddset(&defaultSignals, code)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF))

        var pid = pid_t()
        guard posix_spawn(&pid, path, &actions, &attributes, argv, envp) == 0 else { return -1 }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { return -1 }
        }
        // WIFEXITED and WEXITSTATUS are C macros Swift cannot import.
        let exitedNormally = status & 0x7f == 0
        return exitedNormally ? (status >> 8) & 0xff : -1
    }
}
