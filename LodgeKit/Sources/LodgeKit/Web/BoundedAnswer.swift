/// An answer that must come within a deadline: whichever comes first, the answer or the deadline, wins, and the
/// other is ignored. The caller never waits for an answer that does not come (a page's looping `beforeunload`).
@MainActor
public enum BoundedAnswer {
    /// Calls `start` with a reply function and returns the first reply, or `fallback` once `sleep(deadline)` returns
    /// first. A reply after that, or a second reply, is dropped; the first reply cancels the deadline's task.
    /// `sleep` is injected so tests need no real wait.
    public static func first<Value: Sendable>(
        within deadline: Duration, fallback: Value,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        _ start: (@escaping @MainActor (Value) -> Void) -> Void
    ) async -> Value {
        await withCheckedContinuation { continuation in
            var isDone = false
            var deadlineTask: Task<Void, Never>?
            let reply: @MainActor (Value) -> Void = { value in
                guard !isDone else { return }
                isDone = true
                deadlineTask?.cancel()
                continuation.resume(returning: value)
            }
            start(reply)
            guard !isDone else { return }
            deadlineTask = Task { @MainActor in
                await sleep(deadline)
                reply(fallback)
            }
        }
    }
}
