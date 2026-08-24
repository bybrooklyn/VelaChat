import XCTest
@testable import VelaCore

@MainActor
final class OneShotResumeTests: XCTestCase {
    /// The reason the primitive exists: a second tap on an approval card is
    /// an ordinary double-click, and resuming a continuation twice is a
    /// crash rather than a no-op.
    func testExtraCallsAfterTheFirstAreIgnored() async {
        var handler: (@Sendable (String) -> Void)?
        let value = await withOneShotResume { (resume: @escaping @Sendable (String) -> Void) in
            handler = resume
            resume("first")
            resume("second")
            resume("third")
        }
        XCTAssertEqual(value, "first")
        // Still safe once the awaiting task has already been resumed.
        handler?("late")
    }

    func testInstallRunsBeforeSuspending() async {
        // The pending-state assignment must have happened by the time the
        // caller is waiting, or the card would never make it on screen.
        var installed = false
        let value = await withOneShotResume { (resume: @escaping @Sendable (Int) -> Void) in
            installed = true
            resume(7)
        }
        XCTAssertTrue(installed)
        XCTAssertEqual(value, 7)
    }

    func testResumesWithAnswerDeliveredLater() async {
        // The real shape: install stashes the handler, and something else
        // (a button) calls it after the caller is already suspended.
        final class Box: @unchecked Sendable { var handler: (@Sendable (String?) -> Void)? }
        let box = Box()
        async let answer: String? = withOneShotResume { (resume: @escaping @Sendable (String?) -> Void) in
            box.handler = resume
        }
        while box.handler == nil { await Task.yield() }
        box.handler?("answered")
        let result = await answer
        XCTAssertEqual(result, "answered")
    }

    func testConcurrentClaimsElectExactlyOneWinner() async {
        let gate = OneShotGate()
        let winners = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<64 { group.addTask { gate.claim() } }
            var count = 0
            for await won in group where won { count += 1 }
            return count
        }
        XCTAssertEqual(winners, 1)
    }
}
