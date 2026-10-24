import Foundation
import XCTest
@testable import Capsomnia

final class NativeCapsKeyMappingTests: XCTestCase {
    func testActivationSavesBeforeWritingAndChangesOnlyInternalCaps() throws {
        let internalKeyboard = keyboard(1)
        let externalKeyboard = keyboard(2, builtIn: false)
        let touchBar = keyboard(3, product: "TouchBarUserDevice")
        let other = entry(0x70000003A, 0x70000003B)
        let originalCaps = entry(0x700000039, 0x700000029)
        let backend = FakeBackend([internalKeyboard, externalKeyboard, touchBar], mappings: [
            1: [other, originalCaps], 2: [originalCaps], 3: [originalCaps]
        ])
        let store = MemoryBackup()
        backend.beforeWrite = { _, _ in
            guard store.data != nil else { throw TestError.missingBackup }
        }
        let mapper = NativeCapsKeyMapping(backend: backend, store: store)

        try mapper.activate()

        XCTAssertTrue(mapper.isActive)
        XCTAssertEqual(backend.mappings[1], [other, entry(0x700000039, 0x70000006D)])
        XCTAssertEqual(backend.mappings[2], [originalCaps])
        XCTAssertEqual(backend.mappings[3], [originalCaps])
        XCTAssertNotNil(store.data)
        let writes = backend.writes.count
        try mapper.activate()
        XCTAssertEqual(backend.writes.count, writes)
    }

    func testRestorationMergesOriginalCapsIntoCurrentUnrelatedMappings() throws {
        let backend = FakeBackend([keyboard(1)], mappings: [1: [entry(0x700000039, 0x700000029)]])
        let store = MemoryBackup()
        let mapper = NativeCapsKeyMapping(backend: backend, store: store)
        try mapper.activate()
        backend.mappings[1] = [entry(0x70000003A, 0x70000003C), entry(0x700000039, 0x70000006D)]

        try NativeCapsKeyMapping(backend: backend, store: store).restore()

        XCTAssertEqual(backend.mappings[1], [entry(0x70000003A, 0x70000003C), entry(0x700000039, 0x700000029)])
        XCTAssertNil(store.data)
        let writes = backend.writes.count
        try mapper.restore()
        XCTAssertFalse(mapper.isActive)
        XCTAssertEqual(backend.writes.count, writes)
    }

    func testRestorationRemovesOnlyOwnedCapsWhenThereWasNoOriginalCapsMapping() throws {
        let backend = FakeBackend([keyboard(1)])
        let store = MemoryBackup()
        let mapper = NativeCapsKeyMapping(backend: backend, store: store)
        try mapper.activate()
        backend.mappings[1]?.insert(entry(0x70000003A, 0x70000003B), at: 0)

        try mapper.restore()

        XCTAssertEqual(backend.mappings[1], [entry(0x70000003A, 0x70000003B)])
        XCTAssertFalse(mapper.isActive)
        XCTAssertNil(store.data)
    }

    func testRestorationDoesNotOverwriteNewerUserCapsMapping() throws {
        let backend = FakeBackend([keyboard(1)])
        let store = MemoryBackup()
        let mapper = NativeCapsKeyMapping(backend: backend, store: store)
        try mapper.activate()
        backend.mappings[1] = [entry(0x700000039, 0x700000029)]
        let writes = backend.writes.count

        try mapper.restore()

        XCTAssertEqual(backend.mappings[1], [entry(0x700000039, 0x700000029)])
        XCTAssertEqual(backend.writes.count, writes)
        XCTAssertNil(store.data)
    }

    func testFailedBackupPreventsAllMappingWrites() {
        let backend = FakeBackend([keyboard(1)])
        let store = MemoryBackup()
        store.saveError = TestError.persistence
        let mapper = NativeCapsKeyMapping(backend: backend, store: store)

        XCTAssertThrowsError(try mapper.activate())

        XCTAssertFalse(mapper.isActive)
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertNil(store.data)
    }

    func testCorruptBackupFailsClosedWithoutClearingItOrWritingMappings() {
        let backend = FakeBackend([keyboard(1)], mappings: [1: [entry(0x700000039, 0x70000006D)]])
        let store = MemoryBackup()
        store.data = Data("broken backup".utf8)
        let mapper = NativeCapsKeyMapping(backend: backend, store: store)

        XCTAssertThrowsError(try mapper.activate())
        XCTAssertThrowsError(try mapper.restore())

        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertEqual(store.data, Data("broken backup".utf8))
    }

    func testNoSupportedInternalKeyboardFailsBeforeBackupOrMappingWrites() {
        let backend = FakeBackend([keyboard(1, product: "TouchBarUserDevice")])
        let store = MemoryBackup()
        let mapper = NativeCapsKeyMapping(backend: backend, store: store)

        XCTAssertThrowsError(try mapper.activate())

        XCTAssertFalse(mapper.isActive)
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertNil(store.data)
    }

    func testUnverifiedApplicationRollsBackOriginalMappings() {
        let original = entry(0x700000039, 0x700000029)
        let backend = FakeBackend([keyboard(1)], mappings: [1: [original]])
        let store = MemoryBackup()
        backend.ignoreNextWrite = true
        let mapper = NativeCapsKeyMapping(backend: backend, store: store)

        XCTAssertThrowsError(try mapper.activate())

        XCTAssertFalse(mapper.isActive)
        XCTAssertEqual(backend.mappings[1], [original])
        XCTAssertNil(store.data)
    }

    func testPartialFailureRestoresAlreadyChangedKeyboard() {
        let first = keyboard(1)
        let second = keyboard(2, location: 2)
        let backend = FakeBackend([first, second])
        let store = MemoryBackup()
        backend.beforeWrite = { service, entries in
            if service.registryID == 2, entries.contains(self.entry(0x700000039, 0x70000006D)) {
                backend.mappings[1]?.insert(self.entry(0x70000003A, 0x70000003B), at: 0)
                throw TestError.write
            }
        }
        let mapper = NativeCapsKeyMapping(backend: backend, store: store)

        XCTAssertThrowsError(try mapper.activate())

        XCTAssertFalse(mapper.isActive)
        XCTAssertEqual(backend.mappings[1], [entry(0x70000003A, 0x70000003B)])
        XCTAssertEqual(backend.mappings[2] ?? [], [])
        XCTAssertNil(store.data)
    }

    func testFailedRollbackKeepsBackupForAnotherProcessToRestore() throws {
        let backend = FakeBackend([keyboard(1), keyboard(2, location: 2)])
        let store = MemoryBackup()
        backend.beforeWrite = { service, entries in
            if service.registryID == 2 || entries.isEmpty { throw TestError.write }
        }
        let mapper = NativeCapsKeyMapping(backend: backend, store: store)

        XCTAssertThrowsError(try mapper.activate())
        XCTAssertNotNil(store.data)
        XCTAssertEqual(backend.mappings[1], [entry(0x700000039, 0x70000006D)])
        backend.beforeWrite = nil

        try NativeCapsKeyMapping(backend: backend, store: store).restore()

        XCTAssertEqual(backend.mappings[1], [])
        XCTAssertNil(store.data)
    }

    func testRecoveryMatchesStableInternalIdentityAfterRegistryIDChanges() throws {
        let backend = FakeBackend([keyboard(1)])
        let store = MemoryBackup()
        try NativeCapsKeyMapping(backend: backend, store: store).activate()
        backend.availableServices = [keyboard(99)]
        backend.mappings[99] = backend.mappings.removeValue(forKey: 1)

        try NativeCapsKeyMapping(backend: backend, store: store).restore()

        XCTAssertEqual(backend.mappings[99], [])
        XCTAssertNil(store.data)
    }

    func testAmbiguousRecoveryKeepsBackupWithoutTouchingEitherService() throws {
        let backend = FakeBackend([keyboard(1)])
        let store = MemoryBackup()
        try NativeCapsKeyMapping(backend: backend, store: store).activate()
        backend.availableServices = [keyboard(2), keyboard(3)]
        backend.mappings[2] = [entry(0x700000039, 0x70000006D)]
        backend.mappings[3] = [entry(0x700000039, 0x70000006D)]
        let writes = backend.writes.count

        XCTAssertThrowsError(try NativeCapsKeyMapping(backend: backend, store: store).restore())

        XCTAssertEqual(backend.writes.count, writes)
        XCTAssertNotNil(store.data)
    }

    func testRecoveryRejectsSameRegistryIDWithDifferentHardwareIdentity() throws {
        let backend = FakeBackend([keyboard(1)])
        let store = MemoryBackup()
        try NativeCapsKeyMapping(backend: backend, store: store).activate()
        backend.availableServices = [keyboard(1, location: 2)]
        let writes = backend.writes.count

        XCTAssertThrowsError(try NativeCapsKeyMapping(backend: backend, store: store).restore())

        XCTAssertEqual(backend.writes.count, writes)
        XCTAssertNotNil(store.data)
    }

    func testActivationRecoversStaleBackupBeforeSavingNewOriginalCaps() throws {
        let original = entry(0x700000039, 0x700000029)
        let backend = FakeBackend([keyboard(1)], mappings: [1: [original]])
        let store = MemoryBackup()
        try NativeCapsKeyMapping(backend: backend, store: store).activate()
        let newProcess = NativeCapsKeyMapping(backend: backend, store: store)

        try newProcess.activate()
        try newProcess.restore()

        XCTAssertEqual(backend.mappings[1], [original])
        XCTAssertNil(store.data)
    }

    func testCapsChangeAfterBackupIsPreservedInsteadOfClaimed() {
        let backend = FakeBackend([keyboard(1)])
        let store = MemoryBackup()
        store.afterSave = { backend.mappings[1] = [self.entry(0x700000039, 0x700000029)] }

        XCTAssertThrowsError(try NativeCapsKeyMapping(backend: backend, store: store).activate())

        XCTAssertEqual(backend.mappings[1], [entry(0x700000039, 0x700000029)])
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertNil(store.data)
    }

    func testUnverifiedRestorationRetainsBackupForRetry() throws {
        let backend = FakeBackend([keyboard(1)])
        let store = MemoryBackup()
        let mapper = NativeCapsKeyMapping(backend: backend, store: store)
        try mapper.activate()
        backend.ignoreNextWrite = true

        XCTAssertThrowsError(try mapper.restore())
        XCTAssertNotNil(store.data)
        XCTAssertEqual(backend.mappings[1], [entry(0x700000039, 0x70000006D)])

        try mapper.restore()
        XCTAssertEqual(backend.mappings[1], [])
        XCTAssertNil(store.data)
    }

    func testUnreadableBackupPreventsAllWrites() {
        let backend = FakeBackend([keyboard(1)])
        let store = MemoryBackup()
        store.loadError = TestError.persistence

        XCTAssertThrowsError(try NativeCapsKeyMapping(backend: backend, store: store).activate())

        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testSupervisorWithDifferentOwnerPIDCannotRestoreNewerAppMapping() throws {
        let backend = FakeBackend([keyboard(1)])
        let store = MemoryBackup()
        try NativeCapsKeyMapping(backend: backend, store: store).activate()
        let saved = store.data
        let writes = backend.writes.count
        let serviceReads = backend.serviceReads
        let recovery = NativeCapsKeyMapping(backend: backend, store: store)

        try recovery.restore(ownerPID: ProcessInfo.processInfo.processIdentifier + 1)

        XCTAssertEqual(backend.mappings[1], [entry(0x700000039, 0x70000006D)])
        XCTAssertEqual(backend.writes.count, writes)
        XCTAssertEqual(backend.serviceReads, serviceReads)
        XCTAssertEqual(store.data, saved)

        try recovery.restore(ownerPID: ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(backend.mappings[1], [])
        XCTAssertNil(store.data)
    }

    func testSemanticallyInvalidBackupCannotRestoreUnrelatedKeys() throws {
        let backend = FakeBackend([keyboard(1)])
        let store = MemoryBackup()
        try NativeCapsKeyMapping(backend: backend, store: store).activate()
        var backup = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(store.data)) as? [String: Any])
        var services = try XCTUnwrap(backup["services"] as? [[String: Any]])
        services[0]["originalCaps"] = [["source": 0x70000003A, "destination": 0x700000029]]
        backup["services"] = services
        store.data = try JSONSerialization.data(withJSONObject: backup)
        let corrupt = store.data
        let writes = backend.writes.count

        XCTAssertThrowsError(try NativeCapsKeyMapping(backend: backend, store: store).restore())

        XCTAssertEqual(backend.writes.count, writes)
        XCTAssertEqual(store.data, corrupt)
    }

    func testMappingDecoderPreservesStandardEntriesAndRejectsUnknownFormats() throws {
        XCTAssertEqual(try NativeCapsKeyMapping.decodeMapping(nil), [])
        XCTAssertEqual(try NativeCapsKeyMapping.decodeMapping([
            ["HIDKeyboardModifierMappingSrc": 0x70000003A, "HIDKeyboardModifierMappingDst": 0x70000003B]
        ]), [entry(0x70000003A, 0x70000003B)])
        let unsupported: [Any] = [
            "not an array",
            [["HIDKeyboardModifierMappingSrc": 1]],
            [["HIDKeyboardModifierMappingSrc": true, "HIDKeyboardModifierMappingDst": 1]],
            [["HIDKeyboardModifierMappingSrc": -1, "HIDKeyboardModifierMappingDst": 1]],
            [["HIDKeyboardModifierMappingSrc": 1.5, "HIDKeyboardModifierMappingDst": 1]],
            [["HIDKeyboardModifierMappingSrc": 1, "HIDKeyboardModifierMappingDst": 2, "unknown": 3]]
        ]
        for property in unsupported {
            XCTAssertThrowsError(try NativeCapsKeyMapping.decodeMapping(property))
        }
    }

    func testFileBackupIsPrivateExclusiveAndCanBeLoadedByAnotherInstance() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Capsomnia/native-caps-mapping.json")
        let store = NativeCapsMappingFileStore(url: url)
        XCTAssertNil(try store.load())

        try store.save(Data("private backup".utf8))

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try NativeCapsMappingFileStore(url: url).load(), Data("private backup".utf8))
        XCTAssertThrowsError(try store.save(Data("replacement".utf8)))
        XCTAssertEqual(try store.load(), Data("private backup".utf8))
        try store.remove()
        XCTAssertNil(try store.load())
    }

    func testFileBackupRejectsSymlinksAndInsecureExistingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let target = directory.appendingPathComponent("target.json")
        let url = directory.appendingPathComponent("native-caps-mapping.json")
        try Data("unchanged".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let store = NativeCapsMappingFileStore(url: url)

        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(Data()))
        XCTAssertThrowsError(try store.remove())
        XCTAssertEqual(try Data(contentsOf: target), Data("unchanged".utf8))

        try FileManager.default.removeItem(at: url)
        try Data("insecure".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertThrowsError(try store.load())
    }

    private func keyboard(
        _ id: UInt64,
        product: String = "Apple Internal Keyboard / Trackpad",
        builtIn: Bool = true,
        location: UInt64 = 0xffffffff80500000
    ) -> NativeCapsKeyMapping.Service {
        .init(registryID: id, product: product, vendorID: 1452, productID: 832,
              locationID: location, transport: "USB", isBuiltIn: builtIn)
    }

    private func entry(_ source: UInt64, _ destination: UInt64) -> NativeCapsKeyMapping.Entry {
        .init(source: source, destination: destination)
    }
}

private enum TestError: Error { case missingBackup, persistence, write }

private final class MemoryBackup: NativeCapsMappingBackupStore {
    var data: Data?
    var saveError: Error?
    var loadError: Error?
    var afterSave: (() -> Void)?

    func load() throws -> Data? {
        if let loadError { throw loadError }
        return data
    }
    func save(_ data: Data) throws {
        if let saveError { throw saveError }
        guard self.data == nil else { throw TestError.persistence }
        self.data = data
        afterSave?()
    }
    func remove() throws { data = nil }
}

private final class FakeBackend: NativeCapsMappingBackend {
    var availableServices: [NativeCapsKeyMapping.Service]
    var mappings: [UInt64: [NativeCapsKeyMapping.Entry]]
    var writes: [UInt64] = []
    var serviceReads = 0
    var beforeWrite: ((NativeCapsKeyMapping.Service, [NativeCapsKeyMapping.Entry]) throws -> Void)?
    var ignoreNextWrite = false

    init(_ services: [NativeCapsKeyMapping.Service], mappings: [UInt64: [NativeCapsKeyMapping.Entry]] = [:]) {
        availableServices = services
        self.mappings = mappings
    }

    func services() throws -> [NativeCapsKeyMapping.Service] {
        serviceReads += 1
        return availableServices
    }
    func mapping(for service: NativeCapsKeyMapping.Service) throws -> [NativeCapsKeyMapping.Entry] {
        mappings[service.registryID] ?? []
    }
    func setMapping(_ entries: [NativeCapsKeyMapping.Entry], for service: NativeCapsKeyMapping.Service) throws {
        writes.append(service.registryID)
        try beforeWrite?(service, entries)
        if ignoreNextWrite {
            ignoreNextWrite = false
        } else {
            mappings[service.registryID] = entries
        }
    }
}
