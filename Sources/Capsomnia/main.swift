import AppKit

func acquireInstanceLock(notifyExisting: Bool, busyIsSuccess: Bool = true) -> CapsomniaInstanceLock {
    do {
        return try CapsomniaInstanceLock.acquire()
    } catch CapsomniaInstanceLock.Failure.alreadyRunning {
        if notifyExisting {
            DistributedNotificationCenter.default().post(name: openSettingsNotificationName, object: appLabel)
        }
        // A live owner is still using its mapping. Cleanup must leave it alone.
        exit(busyIsSuccess ? 0 : 75)
    } catch {
        FileHandle.standardError.write(Data("Capsomnia instance lock failed: \(error)\n".utf8))
        exit(1)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--restore-native-caps-lock" {
    var ownerPID: Int32?
    if arguments.count == 3, arguments[1] == "--owner-pid", let pid = Int32(arguments[2]), pid > 0 {
        ownerPID = pid
    } else if arguments.count != 1 {
        exit(64)
    }
    let instanceLock = acquireInstanceLock(notifyExisting: false, busyIsSuccess: ownerPID != nil)
    do {
        try withExtendedLifetime(instanceLock) {
            try NativeCapsKeyMapping.restoreSaved(ownerPID: ownerPID)
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Caps Lock mapping recovery failed: \(error)\n".utf8))
        exit(1)
    }
}

// Launch through the installed supervisor so even a crashed app releases its
// temporary Caps mapping. Interactive reopening reuses the managed instance.
if ProcessInfo.processInfo.environment["CAPSOMNIA_SUPERVISED"] != "1" {
    let result = CommandRunner.run("/bin/launchctl", ["kickstart", "gui/\(getuid())/\(appLabel)"])
    if result.status == 0 {
        DistributedNotificationCenter.default().post(name: openSettingsNotificationName, object: appLabel)
        exit(0)
    }
    FileHandle.standardError.write(Data("Start Capsomnia through its installed LaunchAgent or Contents/Resources/run-capsomnia.sh.\n".utf8))
    exit(1)
}

let instanceLock = acquireInstanceLock(notifyExisting: true)
let app = NSApplication.shared
let delegate = Capsomnia()
app.delegate = delegate
withExtendedLifetime(instanceLock) { app.run() }
