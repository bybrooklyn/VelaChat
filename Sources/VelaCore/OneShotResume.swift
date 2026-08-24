import Foundation

/// Suspends until the handler installed by `install` is called, and resumes
/// the awaiting task exactly once no matter how many times that handler
/// fires.
///
/// Every "pause the generation on a card in the transcript" flow needs this:
/// a command approval, a subagent fan-out confirmation, an `ask_user`
/// question. Each installs some pending-state object holding a callback, and
/// each awaits the answer.
///
/// The exactly-once guarantee is the whole point. A second tap on an
/// approval card is not a programmer error — it is an ordinary double-click,
/// and the buttons stay on screen for the frame or two before the card is
/// torn down — but resuming a continuation twice is a hard crash, not a
/// no-op. That invariant was previously re-derived at each call site with
/// its own mutable box; a single primitive means a new prompt cannot
/// forget it.
///
/// `install` runs synchronously before this function suspends, so the
/// pending-state assignment inside it has already happened by the time the
/// caller is waiting.
@MainActor
public func withOneShotResume<T: Sendable>(
    _ install: (@escaping @Sendable (T) -> Void) -> Void
) async -> T {
    await withCheckedContinuation { continuation in
        let gate = OneShotGate()
        install { value in
            guard gate.claim() else { return }
            continuation.resume(returning: value)
        }
    }
}

/// A latch that exactly one caller can win.
///
/// Locked rather than a bare `Bool`: the callbacks this guards are wired to
/// UI controls and are expected on the main actor, but "expected on the main
/// actor" is an assumption a future caller can break silently, and the
/// failure mode is a crash rather than a glitch. The lock costs nothing at
/// this frequency.
final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// True for the first caller only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
