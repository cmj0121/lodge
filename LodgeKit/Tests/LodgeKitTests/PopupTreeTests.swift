import Foundation
import Testing

@testable import LodgeKit

@Suite struct PopupTreeTests {
    @Test func aChainComesBackParentsFirst() {
        let opener = TabID(), popup = TabID(), inner = TabID()
        let openers = [inner: popup, popup: opener]
        #expect(PopupTree.descendants(of: opener, openers: openers) == [popup, inner])
        #expect(PopupTree.descendants(of: popup, openers: openers) == [inner])
        #expect(PopupTree.descendants(of: inner, openers: openers).isEmpty)
    }

    @Test func siblingsAllCloseButNotTheOpenersOtherTabs() {
        let opener = TabID(), first = TabID(), second = TabID(), stranger = TabID(), strangersPopup = TabID()
        let openers = [first: opener, second: opener, strangersPopup: stranger]
        #expect(Set(PopupTree.descendants(of: opener, openers: openers)) == [first, second])
        #expect(PopupTree.descendants(of: first, openers: openers).isEmpty)
    }

    @Test func aLoopAmongOpenersEnds() {
        let a = TabID(), b = TabID(), c = TabID()
        let openers = [b: a, c: b, a: c]
        #expect(PopupTree.descendants(of: a, openers: openers) == [b, c])
    }

    @Test func aTabWithNoPopupsHasNone() {
        #expect(PopupTree.descendants(of: TabID(), openers: [:]).isEmpty)
    }
}
