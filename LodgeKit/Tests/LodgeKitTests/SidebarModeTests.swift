import Testing

@testable import LodgeKit

@Suite struct SidebarModeTests {
    @Test func toggleSwitchesBetweenTheTwoModes() {
        #expect(SidebarMode.expanded.toggled == .rail)
        #expect(SidebarMode.rail.toggled == .expanded)
    }

    @Test func persistedRawValuesAreStable() {
        #expect(SidebarMode.defaultsKey == "sidebarMode")
        #expect(SidebarMode(rawValue: "expanded") == .expanded)
        #expect(SidebarMode(rawValue: "rail") == .rail)
        #expect(SidebarMode(rawValue: "bogus") == nil)
    }
}
