import Darwin
import Foundation

/// Keep this object alive through native mapping ownership and restoration.
/// The persistent inode must never be unlinked while another process can open it.
final class CapsomniaInstanceLock {
    enum Failure: LocalizedError, Equatable {
        case alreadyRunning, unsafeFile

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "Another Capsomnia process owns the instance lock."
            case .unsafeFile: return "The Capsomnia instance lock must be a private, user-owned regular file."
            }
        }
    }

    static let defaultURL = URL(fileURLWithPath: "/private/tmp/capsomnia-\(getuid()).instance.lock")
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    static func acquire(url: URL = CapsomniaInstanceLock.defaultURL) throws -> CapsomniaInstanceLock {
        let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        var created = true
        var descriptor = open(url.path, flags | O_CREAT | O_EXCL, 0o600)
        if descriptor < 0, errno == EEXIST {
            created = false
            descriptor = open(url.path, flags)
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP || code == EISDIR || code == EACCES { throw Failure.unsafeFile }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        var transferred = false
        defer { if !transferred { close(descriptor) } }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { throw Failure.unsafeFile }
        if created {
            guard fchmod(descriptor, 0o600) == 0, fstat(descriptor, &info) == 0 else { throw posixError() }
        }
        guard info.st_mode & 0o7777 == 0o600 else { throw Failure.unsafeFile }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN { throw Failure.alreadyRunning }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        transferred = true
        return CapsomniaInstanceLock(descriptor: descriptor)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
