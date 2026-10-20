import Foundation
import Testing

@testable import Upthere

struct ReminderParserTests {
    @Test func readsPriorityTagsAndList() {
        let p = ReminderParser.parse("buy milk !! #home #errands @shopping", detectDates: false)
        #expect(p.title == "buy milk")
        #expect(p.priority == .medium)
        #expect(p.tags == ["home", "errands"])
        #expect(p.listQuery == "shopping")
    }

    @Test func keepsAtWordsThatArentLists() {
        let p = ReminderParser.parse("email ola@example.com about @nobody", detectDates: false) { $0 == "work" }
        #expect(p.title == "email ola@example.com about @nobody")
        #expect(p.listQuery == nil)
    }

    @Test func duplicateTagsCountOnce() {
        #expect(ReminderParser.parse("x #Home #home", detectDates: false).tags == ["Home"])
    }

    @Test func dateWithTimeLeavesTheTitle() {
        let p = ReminderParser.parse("call mom tomorrow at 5pm")
        #expect(p.title == "call mom")
        let due = try! #require(p.due)
        #expect(due.hasTime)
        #expect(Calendar.current.isDateInTomorrow(due.date))
        #expect(Calendar.current.component(.hour, from: due.date) == 17)
    }

    @Test func dayAloneIsAllDay() {
        let p = ReminderParser.parse("water plants tomorrow")
        #expect(p.title == "water plants")
        #expect(p.due?.hasTime == false)
    }

    @Test func noDateDetectionKeepsThePhrase() {
        #expect(ReminderParser.parse("read tomorrow's notes", detectDates: false).title == "read tomorrow's notes")
    }

    @Test func eventKitPriorities() {
        #expect(ReminderParser.Priority(eventKit: 1) == .high)
        #expect(ReminderParser.Priority(eventKit: 5) == .medium)
        #expect(ReminderParser.Priority(eventKit: 9) == .low)
        #expect(ReminderParser.Priority(eventKit: 0) == .none)
    }
}

struct ReminderComposerTests {
    let lists = [
        ReminderList(id: "a", title: "Personal", hue: 30),
        ReminderList(id: "b", title: "Shopping list", hue: 140),
    ]

    @Test func listFromTextThenPickedWins() {
        var c = ReminderComposer(text: "oat milk @shop")
        #expect(c.resolve(lists: lists, defaultListID: "a").list?.id == "b")
        #expect(c.resolve(lists: lists, defaultListID: "a").listFromText)
        c.listID = "a"
        #expect(c.resolve(lists: lists, defaultListID: nil).list?.id == "a")
    }

    @Test func fallsBackToDefaultList() {
        #expect(ReminderComposer(text: "x").resolve(lists: lists, defaultListID: "b").list?.id == "b")
    }

    @Test func noDateKeepsTextAndPickedDateWins() {
        var c = ReminderComposer(text: "pay rent tomorrow")
        c.dueChoice = .none
        let r = c.resolve(lists: lists, defaultListID: nil)
        #expect(r.due == nil)
        #expect(r.title == "pay rent tomorrow")
        let picked = ReminderParser.Due(date: .distantFuture, hasTime: false)
        c.dueChoice = .picked(picked)
        #expect(c.resolve(lists: lists, defaultListID: nil).due == picked)
    }

    @Test func emptyTitleMakesNoDraft() {
        #expect(ReminderComposer(text: "#tag !!").draft(lists: lists, defaultListID: nil) == nil)
    }

    @Test func quickDatesAreInTheFuture() {
        let today = Calendar.current.startOfDay(for: .now)
        for pick in ReminderComposer.quickDates() { #expect(pick.due.date >= today) }
    }
}

struct RemindersModelTests {
    @Test func overdueFirstThenSoonest() {
        let list = ReminderList(id: "l", title: "L", hue: 0)
        let model = RemindersModel(defaults: UserDefaults(suiteName: "upthere.tests.reminders")!)
        model.debugPin([
            ReminderItem(id: "later", title: "later", list: list, due: .init(date: .now.addingTimeInterval(7200), hasTime: true), priority: .none, completed: false),
            ReminderItem(id: "none", title: "none", list: list, due: nil, priority: .none, completed: false),
            ReminderItem(id: "late", title: "late", list: list, due: .init(date: .now.addingTimeInterval(-60), hasTime: true), priority: .none, completed: false),
        ])
        #expect(model.collapsedReminders.map(\.id) == ["late", "later"])
        #expect(model.hiddenCount == 1)
    }
}
