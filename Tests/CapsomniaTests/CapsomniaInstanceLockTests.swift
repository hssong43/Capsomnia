import Darwin
import Foundation
import XCTest
@testable import Capsomnia

final class CapsomniaInstanceLockTests: XCTestCase {
    func testSecondOwnerConflictsUntilDeinitAndReusesTheSameFile() throws {
        try withLockURL { url in
            var owner: CapsomniaInstanceLock? = try CapsomniaInstanceLock.acquire(url: url)
            let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
            try withExtendedLifetime(owner) {
                XCTAssertThrowsError(try CapsomniaInstanceLock.acquire(url: url)) {
                    XCTAssertEqual($0 as? CapsomniaInstanceLock.Failure, .alreadyRunning)
                }
            }

            owner = nil

            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            let next = try CapsomniaInstanceLock.acquire(url: url)
            try withExtendedLifetime(next) {
                XCTAssertThrowsError(try CapsomniaInstanceLock.acquire(url: url)) {
                    XCTAssertEqual($0 as? CapsomniaInstanceLock.Failure, .alreadyRunning)
                }
            }
            let nextInode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
            XCTAssertNotNil(inode)
            XCTAssertEqual(nextInode, inode)
        }
    }

    func testNewLockFileHasPrivatePermissions() throws {
        try withLockURL { url in
            let owner = try CapsomniaInstanceLock.acquire(url: url)
            try withExtendedLifetime(owner) {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
                XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
                XCTAssertEqual((attributes[.ownerAccountID] as? NSNumber)?.uint32Value, getuid())
            }
        }
    }

    func testInsecureExistingFileIsRejectedWithoutChangingIt() throws {
        try withLockURL { url in
            let contents = Data("preserve existing file".utf8)
            try contents.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

            XCTAssertThrowsError(try CapsomniaInstanceLock.acquire(url: url)) {
                XCTAssertEqual($0 as? CapsomniaInstanceLock.Failure, .unsafeFile)
            }

            XCTAssertEqual(try Data(contentsOf: url), contents)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o644)
        }
    }

    func testSymlinkIsRejectedWithoutChangingItsTarget() throws {
        try withLockURL { url in
            let target = url.deletingLastPathComponent().appendingPathComponent("target")
            let contents = Data("preserve symlink target".utf8)
            try contents.write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)

            XCTAssertThrowsError(try CapsomniaInstanceLock.acquire(url: url)) {
                XCTAssertEqual($0 as? CapsomniaInstanceLock.Failure, .unsafeFile)
            }

            XCTAssertEqual(try Data(contentsOf: target), contents)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), target.path)
        }
    }

    func testNonRegularPathIsRejected() throws {
        try withLockURL { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])

            XCTAssertThrowsError(try CapsomniaInstanceLock.acquire(url: url)) {
                XCTAssertEqual($0 as? CapsomniaInstanceLock.Failure, .unsafeFile)
            }

            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType,
                           .typeDirectory)
        }
    }

    private func withLockURL(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("instance.lock"))
    }
}
