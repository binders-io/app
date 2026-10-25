import Foundation
import SwiftData
import BindersKit

extension SelfTest {
    /// Distill in the background while you write (lane DS9), in a throwaway folder (BINDERS_DATA_DIR) with the v2 stand-in:
    /// typing then a pause reads only the changed section, once; nothing for a note without Distill, for space alone, while
    /// dictating, recording or capturing, or with the setting off; one reading at a time; one stops when you start
    /// dictating, keeping what it read; its items counted as new, never placed; and Distill with nothing changed asks the
    /// model nothing.
    ///
    ///     BINDERS_DATA_DIR=<new empty folder> Binders --selftest-distill-background -notesShowMarkdown NO
    @MainActor
    static func distillBackgroundSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes notes and cards")
            return 1
        }
        let controller = DictationController()
        let run = DistillTestRun(controller: controller)
        let store = Store.shared
        let service = controller.distill
        let board = controller.board
        service.start()
        service.settleDelay = .seconds(600)
        service.format = .v2
        service.progressEvery = 0
        let reader = service.background
        reader.idle = .milliseconds(300)
        reader.recheck = .milliseconds(200)
        reader.watchEvery = .milliseconds(50)
        var conditions = DistillBackground.Conditions()
        reader.conditionsOverride = { conditions }
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

        run.check(DistillBackgroundReader.enabled, "Distill in the background is on unless turned off")
        let web = BinderRecord(name: "Web", colorIndex: 2)
        store.insert(web)
        let spec = DistillBench.specs.first { $0.name == "Checkout redesign" }!
        let note = NoteItem(text: spec.text)
        note.binderID = web.id
        store.insert(note)
        service.setDistill(true, for: note)
        // The foreground model and the background lane's: the background must use its own.
        let foreground = DistillV2StandIn(spec: spec)
        let later = DistillV2StandIn(spec: spec)
        later.everyLine = true
        service.model = { foreground }
        service.backgroundModel = { later }
        guard case .success = await service.distill(note) else {
            run.check(false, "the note is read first")
            return 1
        }
        let cardsBefore = DistillBoard.cards(of: note.id).count
        func type(_ change: (inout String) -> Void, in item: NoteItem = note) {
            var text = item.text
            change(&text)
            let previous = item.text
            item.text = text
            NoteHistory.changed(item.id, previous: previous)
        }
        func waitDone() async {
            for _ in 0..<200 where reader.current != nil || !reader.due.isEmpty { await settle(20) }
        }

        // MARK: Typing, then a pause: one reading of the changed section
        let foregroundAsks = foreground.asks.count
        let laterAsks = later.asks.count
        for word in ["\n\n## Receipts\n", "Send a receipt ", "by email ", "after paying, ", "with the order number."] {
            type { $0 += word }
            await settle(60)
        }
        run.check(later.asks.count == laterAsks, "nothing is read while you type")
        await settle(500)
        await waitDone()
        run.check(later.asks.count == laterAsks + 1, "after the pause, one reading: \(later.asks.count - laterAsks)")
        run.check(foreground.asks.count == foregroundAsks, "with the background lane's model, not the one you read with")
        let asked = later.asks.last?.user ?? ""
        run.check(asked.contains("Receipts") && !asked.contains("Apple Pay"), "only the changed section is read")
        run.check(reader.started.filter { $0 == note.id }.count == 1, "one reading for the whole run of typing")
        let list = service.list(for: note.id)
        run.check(DistillBoard.cards(of: note.id).count == cardsBefore, "nothing reaches the board without your accepting it")
        print("NOTE: background reading found \(list.newItems.count) items (\(reader.finished.last?.outcome ?? "none"))")
        run.check(reader.finished.last?.note == note.id, "the reading ended: \(reader.finished.last?.outcome ?? "none")")

        // MARK: Space alone: nothing
        let quietAsks = later.asks.count
        type { $0 += "\n\n   \n" }
        await settle(500)
        await waitDone()
        run.check(later.asks.count == quietAsks, "space alone isn't read")
        type { $0 = $0.replacingOccurrences(of: "One page instead", with: "**One page** instead") }
        await settle(500)
        await waitDone()
        run.check(later.asks.count == quietAsks, "nor bold alone")

        // MARK: A note without Distill: nothing
        let plain = NoteItem(text: "# Shopping\n\nMilk and bread.")
        plain.binderID = web.id
        store.insert(plain)
        type({ $0 += "\nAnd apples, pears and a good cheese for Friday." }, in: plain)
        await settle(500)
        run.check(!reader.started.contains(plain.id), "a note without Distill is never read in the background")

        // MARK: While dictating: held back, then read
        conditions.dictating = true
        let heldAsks = later.asks.count
        type { $0 += "\n\n## Gift cards\nAccept gift cards at checkout, one per order." }
        await settle(600)
        run.check(later.asks.count == heldAsks && reader.lastPause == .dictating, "while you dictate it waits: \(reader.lastPause?.words ?? "")")
        for (flag, pause) in [(\DistillBackground.Conditions.recording, DistillBackground.Pause.recording), (\.capturing, .capturing)] {
            conditions.dictating = false
            conditions[keyPath: flag] = true
            await settle(300)
            run.check(later.asks.count == heldAsks && reader.lastPause == pause, "and while \(pause == .recording ? "a meeting is recorded" : "all-day capture is on")")
            conditions[keyPath: flag] = false
        }
        conditions.lowPower = true
        await settle(300)
        run.check(later.asks.count == heldAsks && reader.lastPause == .lowPower, "and in Low Power Mode")
        conditions.lowPower = false
        conditions.onBattery = true
        conditions.battery = 0.12
        await settle(300)
        run.check(later.asks.count == heldAsks && reader.lastPause == .battery, "and on a low battery")
        conditions.onBattery = false
        conditions.hot = true
        await settle(300)
        run.check(later.asks.count == heldAsks && reader.lastPause == .hot, "and when the Mac is hot")
        conditions.hot = false
        await settle(400)
        await waitDone()
        run.check(later.asks.count == heldAsks + 1, "then it's read")

        // MARK: Stopped by dictating, keeping what it read
        let gate = DistillItemGate()
        later.peek = { await gate.pass() }
        type { $0 += "\n\n## Accessibility\nLabel every field for screen readers.\n\nCheck the colour contrast of the error text." }
        for _ in 0..<100 where gate.written < 1 { await settle(20) }
        run.check(service.quietReading.contains(note.id), "a reading in the background is under way")
        conditions.dictating = true
        for _ in 0..<100 where service.reading.contains(note.id) { await settle(20) }
        run.check(!service.reading.contains(note.id), "dictating stops it")
        gate.openWide()
        later.peek = nil
        conditions.dictating = false
        await waitDone()

        // MARK: One at a time
        let second = NoteItem(text: spec.text.replacingOccurrences(of: "Checkout redesign", with: "Checkout, second shop"))
        second.binderID = web.id
        store.insert(second)
        service.setDistill(true, for: second)
        _ = await service.distill(second)
        let both = DistillV2StandIn(spec: spec)
        both.everyLine = true
        both.slowFirst = true
        service.backgroundModel = { both }
        type { $0 += "\n\n## Refunds\nRefund to the card used, within five days." }
        type({ $0 += "\n\n## Refunds\nRefund to the card used, within five days." }, in: second)
        await settle(500)
        await waitDone()
        for _ in 0..<100 where both.asks.count < 2 { await settle(20) }
        await waitDone()
        run.check(both.asks.count == 2, "both notes are read: \(both.asks.count)")
        run.check(both.most == 1, "one reading at a time across the app: \(both.most) at once")

        // MARK: A Distill you start stops it
        let gate2 = DistillItemGate()
        both.slowFirst = false
        both.peek = { await gate2.pass() }
        type { $0 += "\n\n## Invoices\nSend an invoice to business customers on request." }
        for _ in 0..<100 where gate2.written < 1 { await settle(20) }
        let stoppedFor = reader.current
        run.check(stoppedFor == note.id, "a reading in the background is under way again")
        service.model = { DistillV2StandIn(spec: spec) }
        let mine = Task { await service.distill(second) }
        for _ in 0..<100 where service.quietReading.contains(note.id) { await settle(20) }
        run.check(!service.quietReading.contains(note.id), "a Distill you start stops it")
        gate2.openWide()
        _ = await mine.value
        both.peek = nil
        await waitDone()

        // MARK: Off: nothing
        DistillBackgroundReader.enabled = false
        let offAsks = both.asks.count
        type { $0 += "\n\n## Coupons\nOne coupon per order, typed in the summary." }
        await settle(500)
        run.check(both.asks.count == offAsks, "with the setting off, nothing is read")
        DistillBackgroundReader.enabled = true

        // MARK: New items counted, never placed
        run.check(!list.newItems.isEmpty, "what it found is counted as new: \(list.newItems.count)")
        run.check(DistillBoard.cards(of: note.id).count == cardsBefore, "and still nothing is on the board")

        // MARK: Up to date: no model asked
        _ = await service.distill(note)
        let counted = DistillV2StandIn(spec: spec)
        service.model = { counted }
        run.check(!service.hasChangedSections(note: note), "nothing changed since the last reading")
        DistillActions.press(note, controller: controller)
        await settle(200)
        run.check(counted.asks.isEmpty && !service.reading.contains(note.id), "Distill then asks the model nothing")
        run.check(list.upToDateUntil.map { $0 > Date() } == true, "and says Up to date")

        reader.conditionsOverride = nil
        return run.failures == 0 ? 0 : 1
    }
}
