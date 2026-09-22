import XCTest
import SwctxCore

/// Base class for every SwctxCore test. Points `SWCTX_HOME` at one
/// per-process temp dir so Store.baseDir() — and with it indexes/,
/// workspaces.json, records.db, watchd.json, translate_cache.json —
/// resolves there instead of the real ~/.swctx. (The `swctx gc` audit
/// found ~5.4k orphaned index dirs, almost all `swctx-test-*` fixtures
/// these tests wrote into the real home.)
///
/// One home per test process, not per test: `GlobalRecords.shared` and
/// `Translation.sharedCache` bind their path once on first access, so a
/// moving SWCTX_HOME would strand them. The var propagates to spawned
/// `swctx` binaries too (McpColdCwdTests' `swctx mcp` child). The dir is
/// left for the OS tmp sweeper — index pools may still be open at exit.
class SwctxTestCase: XCTestCase {
    static let testHome: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swctx-test-home-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        setenv("SWCTX_HOME", dir.path, 1)
        // GitRunnerTests flaked under full-suite parallel load — the 15s
        // git() deadline is right for production but tight when hundreds of
        // tests compete for the global queue. Tests get headroom.
        setenv("SWCTX_GIT_TIMEOUT_S", "60", 0)
        return dir
    }()

    override func setUp() {
        super.setUp()
        _ = SwctxTestCase.testHome
    }
}
