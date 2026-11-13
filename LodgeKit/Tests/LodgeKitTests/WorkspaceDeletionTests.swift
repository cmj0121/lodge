import Foundation
import Testing

@testable import LodgeKit

@MainActor
@Suite struct WorkspaceDeletionTests {
    private struct Failure: Error {}

    final class Steps: WorkspaceDeletionSteps {
        enum Step: Equatable {
            case removeFromList, saveNow, destroyViews, cancelDownloads, closeHistory, forgetStore, removeWebsiteData
            case removeFiles, clearPending
        }

        var log: [(Step, UUID?)] = []
        var failing: Step?
        /// How many removeWebsiteData calls fail before one succeeds.
        var dataFailures = 0

        var order: [Step] { log.map(\.0) }

        private func record(_ step: Step, _ id: UUID?) throws {
            log.append((step, id))
            if step == failing { throw Failure() }
        }

        func removeFromList(_ id: UUID) { log.append((.removeFromList, id)) }
        func saveNow() { log.append((.saveNow, nil)) }
        func destroyViews(of id: UUID) { log.append((.destroyViews, id)) }
        func cancelDownloads(of id: UUID) { log.append((.cancelDownloads, id)) }
        func closeHistory(of id: UUID) async throws { try record(.closeHistory, id) }
        func forgetStore(of id: UUID) { log.append((.forgetStore, id)) }
        func removeWebsiteData(of id: UUID) async throws {
            try record(.removeWebsiteData, id)
            if dataFailures > 0 {
                dataFailures -= 1
                throw Failure()
            }
        }
        func removeFiles(of id: UUID) throws { try record(.removeFiles, id) }
        func clearPending(_ id: UUID) { log.append((.clearPending, id)) }
    }

    private final class Sleeps: @unchecked Sendable {
        var delays: [Duration] = []
    }

    private let id = UUID()
    private let sleeps = Sleeps()
    private var sleep: WorkspaceDeletion.Sleep { { [sleeps] in sleeps.delays.append($0) } }

    @Test func runsEveryStepInOrderSavingTwice() async {
        let steps = Steps()
        let done = await WorkspaceDeletion.run(id, steps: steps, sleep: sleep)
        #expect(done)
        #expect(
            steps.order == [
                .removeFromList, .saveNow, .destroyViews, .cancelDownloads, .closeHistory, .forgetStore,
                .removeWebsiteData, .removeFiles, .clearPending, .saveNow,
            ])
        #expect(steps.log.compactMap(\.1).allSatisfy { $0 == id })
        #expect(sleeps.delays.isEmpty)
    }

    @Test(arguments: [Steps.Step.closeHistory, .removeWebsiteData, .removeFiles])
    func aFailingStepStopsAndLeavesItPending(_ step: Steps.Step) async {
        let steps = Steps()
        steps.failing = step
        let done = await WorkspaceDeletion.run(id, steps: steps, sleep: sleep)
        #expect(!done)
        #expect(!steps.order.contains(.clearPending))
        #expect(steps.order.last == step)
        #expect(steps.order.filter { $0 == .saveNow }.count == 1)
    }

    @Test func removingWebsiteDataIsTriedAgainAfterADelay() async {
        let steps = Steps()
        steps.dataFailures = 2
        let done = await WorkspaceDeletion.run(id, steps: steps, sleep: sleep)
        #expect(done)
        #expect(steps.order.filter { $0 == .removeWebsiteData }.count == 3)
        #expect(sleeps.delays == [WorkspaceDeletion.dataRemovalDelay, WorkspaceDeletion.dataRemovalDelay])
        #expect(steps.order.suffix(3) == [.removeFiles, .clearPending, .saveNow])
    }

    @Test func removingWebsiteDataGivesUpAfterItsAttempts() async {
        let steps = Steps()
        steps.dataFailures = WorkspaceDeletion.dataRemovalAttempts
        let done = await WorkspaceDeletion.run(id, steps: steps, sleep: sleep)
        #expect(!done)
        #expect(steps.order.filter { $0 == .removeWebsiteData }.count == WorkspaceDeletion.dataRemovalAttempts)
        #expect(sleeps.delays.count == WorkspaceDeletion.dataRemovalAttempts - 1)
        #expect(!steps.order.contains(.removeFiles))
        #expect(!steps.order.contains(.clearPending))
    }

    @Test func aFailedSleepStopsTheRetries() async {
        let steps = Steps()
        steps.dataFailures = 1
        let done = await WorkspaceDeletion.run(id, steps: steps, sleep: { _ in throw CancellationError() })
        #expect(!done)
        #expect(!steps.order.contains(.clearPending))
    }

    @Test(arguments: [Workspace.defaultID, Workspace.anonymousID])
    func fixedWorkspacesAreRefused(id: UUID) async {
        let steps = Steps()
        let done = await WorkspaceDeletion.run(id, steps: steps, sleep: sleep)
        #expect(!done)
        #expect(steps.log.isEmpty)
    }

    @Test func retryFinishesEachPendingWorkspace() async {
        let steps = Steps()
        let other = UUID()
        await WorkspaceDeletion.retry([id, other], steps: steps, sleep: sleep)
        let finish: [Steps.Step] = [.removeWebsiteData, .removeFiles, .clearPending, .saveNow]
        #expect(steps.order == finish + finish)
        #expect(steps.log.compactMap(\.1) == [id, id, id, other, other, other])
    }

    @Test func retryLeavesAFailingOnePendingAndGoesOn() async {
        let steps = Steps()
        steps.dataFailures = WorkspaceDeletion.dataRemovalAttempts
        let other = UUID()
        await WorkspaceDeletion.retry([id, other], steps: steps, sleep: sleep)
        #expect(!steps.log.contains { $0.0 == .clearPending && $0.1 == id })
        #expect(steps.log.contains { $0.0 == .clearPending && $0.1 == other })
    }

    @Test func retrySkipsDefaultAndAnonymous() async {
        let steps = Steps()
        await WorkspaceDeletion.retry([Workspace.defaultID, Workspace.anonymousID], steps: steps, sleep: sleep)
        #expect(steps.log.isEmpty)
    }
}
