import XCTest
@testable import SwctxCore

/// GlobalRecords.git pipe draining: a child writing more than the 64KB
/// pipe buffer used to deadlock — waitUntilExit ran before the pipes
/// were read, the child blocked on write, the timeout fired and callers
/// saw nil (checkpoint then recorded dirty_files:[] on a dirty repo).
final class GitRunnerTests: SwctxTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-gitr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Executable stand-in for git that prints exactly `bytes` of
    /// stdout ("ABCDEFGH\n" repeated and truncated) and exits 0.
    private func fakeGit(bytes: Int, dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("git")
        try "#!/bin/sh\nyes ABCDEFGH | head -c \(bytes)\n".write(
            to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// >128KB of stdout must come back whole: the pipes drain while the
    /// child runs, so it never blocks on a full buffer.
    func testGitDrainsLargeStdout() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = try fakeGit(bytes: 200_000, dir: dir)
        let out = GlobalRecords.git(["status", "--porcelain"],
                                    cwd: dir, binary: bin.path)
        XCTAssertEqual(out?.count, 200_000)
        XCTAssertTrue(out?.hasPrefix("ABCDEFGH") ?? false)
    }

    /// Large stdout AND large stderr at once — both pipes drain
    /// concurrently, neither can starve the other.
    func testGitDrainsBothPipes() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("git")
        try "#!/bin/sh\nyes ABCDEFGH | head -c 150000\nyes zyxwvuts | head -c 150000 1>&2\n".write(
            to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        let out = GlobalRecords.git(["status"], cwd: dir, binary: url.path)
        XCTAssertEqual(out?.count, 150_000)
    }

    /// A non-zero exit still maps to nil through the injected seam.
    func testGitNonZeroExitReturnsNil() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("git")
        try "#!/bin/sh\necho nope 1>&2\nexit 3\n".write(
            to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        XCTAssertNil(GlobalRecords.git(["status"], cwd: dir, binary: url.path))
    }
}
