import Darwin
import Foundation
import IOKit.hidsystem

protocol NativeCapsMappingBackend: AnyObject {
    func services() throws -> [NativeCapsKeyMapping.Service]
    func mapping(for service: NativeCapsKeyMapping.Service) throws -> [NativeCapsKeyMapping.Entry]
    func setMapping(_ entries: [NativeCapsKeyMapping.Entry], for service: NativeCapsKeyMapping.Service) throws
}

protocol NativeCapsMappingBackupStore: AnyObject {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func remove() throws
}

/// Owns only the internal keyboard's Caps source while the dedicated input route is ready.
/// Callers must keep their F18 event filter running until restoration finishes.
final class NativeCapsKeyMapping {
    struct Entry: Codable, Equatable {
        let source: UInt64
        let destination: UInt64
    }

    struct Service: Codable, Equatable {
        let registryID: UInt64
        let product: String
        let vendorID: UInt64
        let productID: UInt64
        let locationID: UInt64
        let transport: String
        let isBuiltIn: Bool

        var isSupported: Bool {
            registryID != 0 && product == "Apple Internal Keyboard / Trackpad"
                && vendorID == 1452 && productID != 0 && locationID != 0
                && !transport.isEmpty && isBuiltIn
        }

        func matchesHardware(_ other: Service) -> Bool {
            product == other.product && vendorID == other.vendorID && productID == other.productID
                && locationID == other.locationID && transport == other.transport && isBuiltIn == other.isBuiltIn
        }
    }

    enum Failure: LocalizedError {
        case unsupportedService, unsupportedMapping, invalidBackup, unsafeBackup
        case capsChanged, writeFailed, verificationFailed
        case rollbackFailed(Error, Error)

        var errorDescription: String? {
            switch self {
            case .unsupportedService: return "A uniquely identified Apple internal keyboard is unavailable."
            case .unsupportedMapping: return "The keyboard has an unsupported UserKeyMapping value; it was preserved."
            case .invalidBackup: return "The native Caps Lock backup is invalid; it was preserved."
            case .unsafeBackup: return "The native Caps Lock backup is not a private, user-owned regular file."
            case .capsChanged: return "The Caps Lock mapping changed before activation; it was preserved."
            case .writeFailed: return "The keyboard rejected the native Caps Lock mapping."
            case .verificationFailed: return "The native Caps Lock mapping could not be verified."
            case let .rollbackFailed(action, recovery):
                return "\(action.localizedDescription) Recovery also failed: \(recovery.localizedDescription)"
            }
        }
    }

    private struct SavedService: Codable {
        let service: Service
        let originalCaps: [Entry]
    }

    private struct Backup: Codable {
        let version: Int
        let ownerPID: Int32
        let services: [SavedService]
    }

    private static let capsSource: UInt64 = 0x700000039
    private static let ownedCaps = Entry(source: 0x700000039, destination: 0x70000006D)
    private static let sourceKey = "HIDKeyboardModifierMappingSrc"
    private static let destinationKey = "HIDKeyboardModifierMappingDst"
    private let backend: NativeCapsMappingBackend
    private let store: NativeCapsMappingBackupStore
    private(set) var isActive = false

    convenience init() {
        self.init(backend: NativeCapsMappingHIDBackend(), store: NativeCapsMappingFileStore())
    }

    init(backend: NativeCapsMappingBackend, store: NativeCapsMappingBackupStore) {
        self.backend = backend
        self.store = store
    }

    func activate() throws {
        guard !isActive else { return }
        try restore()
        let services = try backend.services().filter(\.isSupported)
        guard !services.isEmpty, Set(services.map(\.registryID)).count == services.count else {
            throw Failure.unsupportedService
        }
        let saved = try services.map { service in
            SavedService(service: service, originalCaps: try backend.mapping(for: service).filter(Self.isCaps))
        }
        try store.save(JSONEncoder().encode(Backup(version: 1, ownerPID: getpid(), services: saved)))
        do {
            for item in saved {
                let current = try backend.mapping(for: item.service)
                guard current.filter(Self.isCaps) == item.originalCaps else { throw Failure.capsChanged }
                try writeAndVerify(current.filter { !Self.isCaps($0) } + [Self.ownedCaps], to: item.service)
            }
            isActive = true
        } catch {
            let actionError = error
            do { try restore() }
            catch { throw Failure.rollbackFailed(actionError, error) }
            throw actionError
        }
    }

    func restore(ownerPID: Int32? = nil) throws {
        guard let data = try store.load() else {
            isActive = false
            return
        }
        let backup: Backup
        do { backup = try JSONDecoder().decode(Backup.self, from: data) }
        catch { throw Failure.invalidBackup }
        guard backup.version == 1, backup.ownerPID > 0, !backup.services.isEmpty,
              Set(backup.services.map { $0.service.registryID }).count == backup.services.count,
              backup.services.allSatisfy({ $0.service.isSupported && $0.originalCaps.allSatisfy(Self.isCaps) }) else {
            throw Failure.invalidBackup
        }
        if let ownerPID, ownerPID != backup.ownerPID { return }
        let available = try backend.services().filter(\.isSupported)
        var firstError: Error?
        for item in backup.services {
            do {
                let matches = available.filter { $0.matchesHardware(item.service) }
                let exact = matches.filter { $0.registryID == item.service.registryID }
                guard let service = exact.count == 1 ? exact.first : (matches.count == 1 ? matches.first : nil) else {
                    throw Failure.unsupportedService
                }
                let current = try backend.mapping(for: service)
                guard current.filter(Self.isCaps) == [Self.ownedCaps] else { continue }
                try writeAndVerify(current.filter { !Self.isCaps($0) } + item.originalCaps, to: service)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        try store.remove()
        isActive = false
    }

    static func restoreSaved(ownerPID: Int32? = nil) throws {
        try NativeCapsKeyMapping().restore(ownerPID: ownerPID)
    }

    private static func isCaps(_ entry: Entry) -> Bool { entry.source == capsSource }

    private func writeAndVerify(_ entries: [Entry], to service: Service) throws {
        try backend.setMapping(entries, for: service)
        guard try backend.mapping(for: service) == entries else { throw Failure.verificationFailed }
    }

    // Unknown fields/types are rejected before writing, rather than silently dropped.
    static func decodeMapping(_ property: Any?) throws -> [Entry] {
        guard let property else { return [] }
        guard let values = property as? [[String: Any]] else { throw Failure.unsupportedMapping }
        return try values.map { value in
            guard Set(value.keys) == Set([sourceKey, destinationKey]),
                  let source = unsignedNumber(value[sourceKey]),
                  let destination = unsignedNumber(value[destinationKey]) else {
                throw Failure.unsupportedMapping
            }
            return Entry(source: source, destination: destination)
        }
    }

    fileprivate static func unsignedNumber(_ value: Any?, allowSigned: Bool = false) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        if let unsigned = UInt64(number.stringValue) { return unsigned }
        if allowSigned, let signed = Int64(number.stringValue) { return UInt64(bitPattern: signed) }
        return nil
    }

    fileprivate static func property(_ entries: [Entry]) -> CFArray {
        entries.map { [sourceKey: NSNumber(value: $0.source), destinationKey: NSNumber(value: $0.destination)] } as CFArray
    }
}

private final class NativeCapsMappingHIDBackend: NativeCapsMappingBackend {
    private var client: IOHIDEventSystemClient?
    private var handles: [UInt64: IOHIDServiceClient] = [:]

    func services() throws -> [NativeCapsKeyMapping.Service] {
        // A client retained across sleep can keep services that reject all writes.
        handles.removeAll()
        client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        guard let client, let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else {
            throw NativeCapsKeyMapping.Failure.unsupportedService
        }
        var result: [NativeCapsKeyMapping.Service] = []
        var handles: [UInt64: IOHIDServiceClient] = [:]
        for service in services {
            guard IOHIDServiceClientConformsTo(service, 1, 6) != 0,
                  let product = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String,
                  product == "Apple Internal Keyboard / Trackpad" else { continue }
            func number(_ key: String, allowSigned: Bool = false) -> UInt64? {
                NativeCapsKeyMapping.unsignedNumber(IOHIDServiceClientCopyProperty(service, key as CFString),
                                                   allowSigned: allowSigned)
            }
            guard let id = NativeCapsKeyMapping.unsignedNumber(IOHIDServiceClientGetRegistryID(service)),
                  let vendor = number("VendorID"), let productID = number("ProductID"),
                  let location = number("LocationID", allowSigned: true),
                  let transport = IOHIDServiceClientCopyProperty(service, "Transport" as CFString) as? String else {
                throw NativeCapsKeyMapping.Failure.unsupportedService
            }
            let builtIn = (IOHIDServiceClientCopyProperty(service, "Built-In" as CFString) as? NSNumber)?.boolValue == true
            let identity = NativeCapsKeyMapping.Service(registryID: id, product: product, vendorID: vendor,
                                                       productID: productID, locationID: location,
                                                       transport: transport, isBuiltIn: builtIn)
            guard identity.isSupported, handles[id] == nil else { throw NativeCapsKeyMapping.Failure.unsupportedService }
            result.append(identity)
            handles[id] = service
        }
        self.handles = handles
        return result
    }

    func mapping(for service: NativeCapsKeyMapping.Service) throws -> [NativeCapsKeyMapping.Entry] {
        guard service.isSupported, let handle = handles[service.registryID] else {
            throw NativeCapsKeyMapping.Failure.unsupportedService
        }
        return try NativeCapsKeyMapping.decodeMapping(IOHIDServiceClientCopyProperty(handle, "UserKeyMapping" as CFString))
    }

    func setMapping(_ entries: [NativeCapsKeyMapping.Entry], for service: NativeCapsKeyMapping.Service) throws {
        guard service.isSupported, let handle = handles[service.registryID] else {
            throw NativeCapsKeyMapping.Failure.unsupportedService
        }
        guard IOHIDServiceClientSetProperty(handle, "UserKeyMapping" as CFString, NativeCapsKeyMapping.property(entries)) else {
            throw NativeCapsKeyMapping.Failure.writeFailed
        }
    }
}

/// A crash during backup creation leaves an invalid backup and no HID writes.
/// O_EXCL and O_NOFOLLOW keep unknown files and symlinks intact.
final class NativeCapsMappingFileStore: NativeCapsMappingBackupStore {
    private let url: URL
    private static let maximumBytes = 1_048_576

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Capsomnia/native-caps-mapping.json")) {
        self.url = url
    }

    func load() throws -> Data? {
        guard try checkDirectory(create: false) else { return nil }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o7777 == 0o600, info.st_size <= Self.maximumBytes else {
            throw NativeCapsKeyMapping.Failure.unsafeBackup
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            if count == 0 { return data }
            guard data.count + count <= Self.maximumBytes else { throw NativeCapsKeyMapping.Failure.unsafeBackup }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    func save(_ data: Data) throws {
        guard data.count <= Self.maximumBytes else { throw NativeCapsKeyMapping.Failure.invalidBackup }
        _ = try checkDirectory(create: true)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        do {
            guard fchmod(descriptor, 0o600) == 0 else { throw posixError() }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw posixError()
                    }
                    guard count > 0 else { throw POSIXError(.EIO) }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else { throw posixError() }
            try syncDirectory()
        } catch {
            unlink(url.path)
            try? syncDirectory()
            throw error
        }
    }

    func remove() throws {
        guard try load() != nil else { return }
        guard unlink(url.path) == 0 else { throw posixError() }
        try syncDirectory()
    }

    private func checkDirectory(create: Bool) throws -> Bool {
        let directory = url.deletingLastPathComponent()
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw posixError() }
            guard create else { return false }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            guard lstat(directory.path, &info) == 0 else { throw posixError() }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw NativeCapsKeyMapping.Failure.unsafeBackup
        }
        if info.st_mode & 0o7777 != 0o700 {
            guard create else { throw NativeCapsKeyMapping.Failure.unsafeBackup }
            guard chmod(directory.path, 0o700) == 0 else { throw posixError() }
        }
        return true
    }

    private func syncDirectory() throws {
        let descriptor = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posixError() }
    }

    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
