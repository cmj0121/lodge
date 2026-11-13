import Foundation
import Testing

@testable import LodgeKit

/// Random windows, tabs and events against `WindowSelections`, checking after every step that each window shows
/// exactly one open tab of the active workspace, no tab is shown twice, and nothing closes but owned blanks still
/// blank and the tabs being closed.
@Suite struct WindowSelectionsPropertyTests {
    /// SplitMix64, so a failing seed replays.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private struct Tabs {
        var order: [TabID] = []
        var blank: Set<TabID> = []

        mutating func append(_ id: TabID, blank isBlank: Bool) {
            order.append(id)
            if isBlank { blank.insert(id) }
        }

        mutating func remove(_ ids: some Sequence<TabID>) {
            let ids = Set(ids)
            order.removeAll(where: ids.contains)
            blank.subtract(ids)
        }
    }

    /// The app side: every workspace's open tabs, kept as the resolver's changes say.
    private struct World {
        var rng: SeededGenerator
        var workspaces: [UUID: Tabs] = [:]
        var selections = WindowSelections(active: Workspace.defaultID)
        var issues: [String] = []

        init(seed: UInt64) {
            rng = SeededGenerator(state: seed)
            for id in [Workspace.defaultID, UUID(), UUID(), UUID()] { workspaces[id] = randomTabs() }
            let all = workspaces.values.flatMap(\.order)
            let windows = (0..<Int.random(in: 1...3, using: &rng)).map { _ in
                (id: WindowID(), selectedTab: Bool.random(using: &rng) ? all.randomElement(using: &rng) : nil)
            }
            let active = workspaces.keys.sorted { $0.uuidString < $1.uuidString }.randomElement(using: &rng)!
            let change = selections.restore(
                windows, fallback: all.randomElement(using: &rng), in: tabs(active))
            create(change.create)
            var saved: Set<TabID> = []
            for window in windows {
                guard let tab = window.selectedTab, workspaces[active]!.order.contains(tab), saved.insert(tab).inserted
                else { continue }
                if selections.shown(in: window.id) != tab { issues.append("restore: a saved selectedTab lost") }
            }
        }

        mutating func randomTabs() -> Tabs {
            var tabs = Tabs()
            for _ in 0..<Int.random(in: 0...4, using: &rng) { tabs.append(TabID(), blank: Bool.random(using: &rng)) }
            return tabs
        }

        var active: UUID { selections.active }
        var dormant: [UUID] { workspaces.keys.filter { $0 != active }.sorted { $0.uuidString < $1.uuidString } }
        var owned: Set<TabID> { selections.windows.reduce(into: []) { $0.formUnion($1.ownedBlanks) } }

        func tabs(_ workspace: UUID) -> WorkspaceTabs {
            let tabs = workspaces[workspace]!
            return WorkspaceTabs(workspace: workspace, order: tabs.order, blank: tabs.blank)
        }

        mutating func create(_ ids: [TabID]) {
            for id in ids { workspaces[active]!.append(id, blank: true) }
        }

        /// `close` must be blanks that `allowed` holds.
        mutating func close(_ close: [TabID], in workspace: UUID, allowed: Set<TabID>, event: String) {
            let blank = workspaces[workspace]!.blank
            if !close.allSatisfy({ allowed.contains($0) && blank.contains($0) }) {
                issues.append("\(event) closed a tab it does not own or that is not blank")
            }
            workspaces[workspace]!.remove(close)
        }

        mutating func step() -> String {
            let windows = selections.windows.map(\.id)
            switch Int.random(in: 0..<12, using: &rng) {
            case 0:
                let target = dormant.randomElement(using: &rng)!
                let leaving = active
                let owned = owned
                let change = selections.enter(tabs(target), leaving: tabs(leaving))
                close(change.close, in: leaving, allowed: owned, event: "enter")
                create(change.create)
                if !change.create.isEmpty && !Set(workspaces[target]!.order).subtracting(change.create)
                    .isSubset(of: selections.shownTabs)
                {
                    issues.append("enter made a blank while a tab was free")
                }
                return "enter"
            case 1:
                create(selections.addWindow(WindowID()).create)
                return "addWindow"
            case 2:
                guard let id = windows.randomElement(using: &rng) else { return "none" }
                let owned = selections.windows.first { $0.id == id }!.ownedBlanks
                let change = selections.removeWindow(id, in: tabs(active))
                close(change.close, in: active, allowed: owned, event: "removeWindow")
                return "removeWindow"
            case 3:
                let order = workspaces[active]!.order
                guard !order.isEmpty else { return "none" }
                let closing = Set(order.filter { _ in Int.random(in: 0..<3, using: &rng) == 0 } + [order.randomElement(using: &rng)!])
                let change = selections.closing(closing, in: tabs(active))
                create(change.create)
                if !change.create.isEmpty && !Set(order).subtracting(closing).isSubset(of: selections.shownTabs) {
                    issues.append("closing made a blank while a tab was free")
                }
                workspaces[active]!.remove(closing)
                return "closing"
            case 4:
                let workspace = dormant.randomElement(using: &rng)!
                guard let tab = workspaces[workspace]!.order.randomElement(using: &rng) else { return "none" }
                if selections.closing([tab], in: tabs(workspace)) != SelectionChange() {
                    issues.append("closing in a dormant workspace changed tabs")
                }
                workspaces[workspace]!.remove([tab])
                return "closing dormant"
            case 5:
                guard let window = windows.randomElement(using: &rng),
                    let tab = workspaces[active]!.order.randomElement(using: &rng)
                else { return "none" }
                let other = selections.window(showing: tab)
                let before = selections.shown(in: window)
                let outcome = selections.select(tab, in: window, of: tabs(active))
                if let other, other != window {
                    if outcome != .shownIn(other) || selections.shown(in: window) != before {
                        issues.append("select of a tab shown elsewhere")
                    }
                } else if outcome != .selected || selections.shown(in: window) != tab {
                    issues.append("select of a free tab")
                }
                return "select"
            case 6:
                guard let window = windows.randomElement(using: &rng) else { return "none" }
                let tab = TabID()
                workspaces[active]!.append(tab, blank: Bool.random(using: &rng))
                selections.opened(tab, in: active, window: window)
                return "opened"
            case 7:
                guard let window = windows.randomElement(using: &rng) else { return "none" }
                let workspace = dormant.randomElement(using: &rng)!
                let tab = TabID()
                workspaces[workspace]!.append(tab, blank: false)
                selections.opened(tab, in: workspace, window: window)
                return "receive"
            case 8:
                guard let tab = workspaces[active]!.blank.randomElement(using: &rng) else { return "none" }
                workspaces[active]!.blank.remove(tab)
                return "load blank"
            case 9:
                guard let window = windows.randomElement(using: &rng) else { return "none" }
                selections.makeKey(window)
                return "makeKey"
            case 10:
                guard let workspace = dormant.filter({ $0 != Workspace.defaultID }).randomElement(using: &rng)
                else { return "none" }
                selections.forget(workspace: workspace)
                workspaces[workspace] = nil
                workspaces[UUID()] = randomTabs()
                return "delete dormant"
            default:
                let deleted = active
                guard deleted != Workspace.defaultID else { return "none" }
                let change = selections.enter(tabs(Workspace.defaultID), leaving: tabs(deleted))
                create(change.create)
                selections.forget(workspace: deleted)
                workspaces[deleted] = nil
                workspaces[UUID()] = randomTabs()
                return "delete active"
            }
        }

        mutating func check(after event: String) {
            let open = Set(workspaces[active]!.order)
            let shown = selections.windows.map { selections.shown(in: $0.id) }
            if !shown.allSatisfy({ $0.map(open.contains) == true }) {
                issues.append("\(event): a window shows no open tab")
            }
            if Set(shown.compactMap { $0 }).count != shown.count { issues.append("\(event): a tab is shown twice") }
            for window in selections.windows where selections.window(showing: window.remembered[active]!) != window.id {
                issues.append("\(event): window(showing:) disagrees with shown(in:)")
            }
            if !owned.isSubset(of: open) { issues.append("\(event): an owned blank is not an open active tab") }
            for window in selections.windows {
                for (workspace, tab) in window.remembered where workspaces[workspace]?.order.contains(tab) != true {
                    issues.append("\(event): a window remembers a closed tab or a deleted workspace")
                }
            }
        }
    }

    @Test(arguments: 0..<10)
    func randomEventsKeepEveryWindowOnItsOwnOpenTab(batch: UInt64) {
        for seed in (batch * 40)..<(batch * 40 + 40) {
            var world = World(seed: seed)
            world.check(after: "restore")
            var events: [String] = ["restore"]
            for _ in 0..<80 where world.issues.isEmpty {
                let event = world.step()
                events.append(event)
                world.check(after: event)
            }
            #expect(world.issues.isEmpty, "seed \(seed): \(world.issues) after \(events.suffix(6))")
        }
    }
}
