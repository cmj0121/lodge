import Testing

@testable import LodgeKit

@Suite struct BeforeUnloadScheduleTests {
    let start = ContinuousClock.now
    let every: Duration = .seconds(300)

    @Test func anUnaskedTabIsAsked() {
        #expect(BeforeUnloadSchedule().known(TabID(), now: start, every: every) == nil)
    }

    @Test func notAskingStandsForTheDocument() {
        var schedule = BeforeUnloadSchedule()
        let tab = TabID()
        schedule.record(tab, asks: false, at: start)
        #expect(schedule.known(tab, now: start + .seconds(3600), every: every) == false)
    }

    @Test func askingStandsUntilTheIntervalPassesThenIsAskedAgain() {
        var schedule = BeforeUnloadSchedule()
        let tab = TabID()
        schedule.record(tab, asks: true, at: start)
        #expect(schedule.known(tab, now: start + .seconds(299), every: every) == true)
        #expect(schedule.known(tab, now: start + .seconds(300), every: every) == nil)
        schedule.record(tab, asks: false, at: start + .seconds(300))
        #expect(schedule.known(tab, now: start + .seconds(301), every: every) == false)
    }

    @Test func askingAgainRestartsTheInterval() {
        var schedule = BeforeUnloadSchedule()
        let tab = TabID()
        schedule.record(tab, asks: true, at: start)
        schedule.record(tab, asks: true, at: start + .seconds(300))
        #expect(schedule.known(tab, now: start + .seconds(500), every: every) == true)
    }

    @Test func forgetAsksAfreshAndTabsStayApart() {
        var schedule = BeforeUnloadSchedule()
        let (one, other) = (TabID(), TabID())
        schedule.record(one, asks: false, at: start)
        schedule.record(other, asks: true, at: start)
        schedule.forget(one)
        #expect(schedule.known(one, now: start, every: every) == nil)
        #expect(schedule.known(other, now: start, every: every) == true)
        #expect(schedule != BeforeUnloadSchedule())
    }
}
