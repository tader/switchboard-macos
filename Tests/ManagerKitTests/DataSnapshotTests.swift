import XCTest
@testable import ManagerKit

final class DataSnapshotTests: XCTestCase {
    func testInternalLinksRemainInsideSnapshotAfterOriginalIsRemoved() throws {
        let fm = FileManager.default, base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let original = base.appendingPathComponent("original"), backup = base.appendingPathComponent("backup")
        try fm.createDirectory(at: original.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let payload = original.appendingPathComponent("payload")
        try Data("synthetic".utf8).write(to: payload)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: payload.path)
        for (name, target) in [("relative", "../payload"), ("absolute", payload.path), ("directory", original.path)] {
            try fm.createSymbolicLink(atPath: original.appendingPathComponent("nested/" + name).path, withDestinationPath: target)
        }
        for name in DataSnapshot.transientLinks {
            try fm.createSymbolicLink(atPath: original.appendingPathComponent(name).path, withDestinationPath: "/tmp/synthetic-missing/" + name)
        }
        try DataSnapshot.copyVerified(from: original, to: backup)
        XCTAssertEqual((try fm.attributesOfItem(atPath: payload.path)[.posixPermissions] as? NSNumber)?.intValue, 0o644)
        try fm.removeItem(at: original)
        for name in ["relative", "absolute", "directory/payload"] {
            XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("nested/" + name), encoding: .utf8), "synthetic")
        }
        for name in DataSnapshot.transientLinks { XCTAssertThrowsError(try fm.destinationOfSymbolicLink(atPath: backup.appendingPathComponent(name).path)) }
    }
    func testDanglingInternalLinkIsPreservedButDanglingExternalLinkIsRejected() throws {
        let fm = FileManager.default, base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let original = base.appendingPathComponent("original"), backup = base.appendingPathComponent("backup")
        try fm.createDirectory(at: original, withIntermediateDirectories: true)
        let link = original.appendingPathComponent("link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "missing")
        try DataSnapshot.copyVerified(from: original, to: backup)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: backup.appendingPathComponent("link").path), "missing")
        try fm.removeItem(at: backup); try fm.removeItem(at: link)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../missing-outside")
        XCTAssertThrowsError(try DataSnapshot.copyVerified(from: original, to: backup))
        XCTAssertFalse(fm.fileExists(atPath: backup.path))
    }
    func testSymlinkCycleFailsWithoutRecursingForever() throws {
        let fm = FileManager.default, base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let original = base.appendingPathComponent("original"), backup = base.appendingPathComponent("backup")
        try fm.createDirectory(at: original, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: original.appendingPathComponent("cycle").path, withDestinationPath: "cycle")
        XCTAssertThrowsError(try DataSnapshot.copyVerified(from: original, to: backup)) { error in
            XCTAssertTrue(error.localizedDescription.contains("cyclic symbolic link"))
        }
    }
    func testExternalAndChainedExternalLinksAreRejectedWithoutChangingTargets() throws {
        for chained in [false, true] {
            let fm = FileManager.default, base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? fm.removeItem(at: base) }
            let original = base.appendingPathComponent("original"), backup = base.appendingPathComponent("backup"), external = base.appendingPathComponent("outside")
            try fm.createDirectory(at: original, withIntermediateDirectories: true)
            try Data("preserve".utf8).write(to: external)
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: external.path)
            try fm.createSymbolicLink(atPath: original.appendingPathComponent("external").path, withDestinationPath: external.path)
            if chained { try fm.createSymbolicLink(atPath: original.appendingPathComponent("chain").path, withDestinationPath: "external") }
            XCTAssertThrowsError(try DataSnapshot.copyVerified(from: original, to: backup)) { error in
                XCTAssertTrue(error.localizedDescription.contains("external symbolic link"))
            }
            XCTAssertFalse(fm.fileExists(atPath: backup.path))
            XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "preserve")
            XCTAssertEqual((try fm.attributesOfItem(atPath: external.path)[.posixPermissions] as? NSNumber)?.intValue, 0o644)
        }
    }
}
