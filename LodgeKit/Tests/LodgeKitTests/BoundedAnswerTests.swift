import Testing

@testable import LodgeKit

@MainActor
@Suite struct BoundedAnswerTests {
    @Test func anAnswerBeforeTheDeadlineWins() async {
        let value = await BoundedAnswer.first(within: .seconds(60), fallback: false, sleep: { _ in await never() }) {
            $0(true)
        }
        #expect(value)
    }

    @Test func noAnswerGivesTheFallbackOnceTheDeadlinePasses() async {
        let value = await BoundedAnswer.first(within: .milliseconds(500), fallback: false, sleep: { _ in }) { _ in }
        #expect(!value)
    }

    @Test func theDeadlineIsTheOneAskedFor() async {
        let asked = Recorder()
        _ = await BoundedAnswer.first(within: .milliseconds(500), fallback: 0, sleep: { await asked.record($0) }) {
            _ in
        }
        #expect(await asked.durations == [.milliseconds(500)])
    }

    @Test func anAnswerAfterTheStartCancelsTheDeadline() async {
        let (cancellations, cancelled) = AsyncStream.makeStream(of: Bool.self)
        let value = await BoundedAnswer.first(
            within: .seconds(3600), fallback: false,
            sleep: { deadline in
                try? await Task.sleep(for: deadline)
                cancelled.yield(Task.isCancelled)
            }
        ) { reply in
            Task { @MainActor in reply(true) }
        }
        #expect(value)
        var iterator = cancellations.makeAsyncIterator()
        #expect(await iterator.next() == true)
    }

    @Test func aLateOrSecondAnswerIsDropped() async {
        var late: (@MainActor (Bool) -> Void)?
        let value = await BoundedAnswer.first(within: .seconds(1), fallback: false, sleep: { _ in }) { reply in
            late = reply
        }
        late?(true)
        late?(true)
        #expect(!value)
        let twice = await BoundedAnswer.first(within: .seconds(1), fallback: 0, sleep: { _ in await never() }) {
            $0(1)
            $0(2)
        }
        #expect(twice == 1)
    }
}

/// A sleep that does not return within the test.
private func never() async {
    try? await Task.sleep(for: .seconds(3600))
}

private actor Recorder {
    private(set) var durations: [Duration] = []
    func record(_ duration: Duration) { durations.append(duration) }
}
