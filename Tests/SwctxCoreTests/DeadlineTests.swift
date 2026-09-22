import XCTest
@testable import SwctxCore

/// `MCPServer.withDeadline` contract: a tools/call must always answer —
/// a fast op returns its value; anything still running past its budget
/// surfaces `DeadlineError` (enveloped as E_DEADLINE_EXCEEDED upstream)
/// instead of hanging the client.
final class DeadlineTests: SwctxTestCase {
    func testFastOperationReturnsValueWithinDeadline() async throws {
        let v = try await MCPServer.withDeadline(.seconds(5), tool: "probe") {
            try await Task.sleep(for: .milliseconds(10))
            return 42
        }
        XCTAssertEqual(v, 42)
    }

    func testSlowOperationThrowsDeadlineError() async throws {
        let start = ContinuousClock.now
        do {
            _ = try await MCPServer.withDeadline(.milliseconds(50), tool: "probe") {
                try await Task.sleep(for: .seconds(5))
                return 0
            }
            XCTFail("expected DeadlineError")
        } catch let e as MCPServer.DeadlineError {
            XCTAssertEqual(e.tool, "probe")
            // Timely response: well under the op's 5s sleep.
            XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        }
    }

    /// The P0 wedge class: a task that ignores cancellation and never
    /// returns must still lose the race at the deadline — the response is
    /// timely even though the wedged task leaks in the background.
    func testNonCooperativeWedgeStillTimesOut() async throws {
        let start = ContinuousClock.now
        do {
            _ = try await MCPServer.withDeadline(.milliseconds(50), tool: "probe") { () -> Int in
                while true { await Task.yield() }
            }
            XCTFail("expected DeadlineError")
        } catch is MCPServer.DeadlineError {
            XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        }
    }

    func testOperationErrorPropagates() async throws {
        struct OpError: Error {}
        do {
            _ = try await MCPServer.withDeadline(.seconds(5), tool: "probe") { () -> Int in
                throw OpError()
            }
            XCTFail("expected OpError")
        } catch is OpError {}
    }
}
