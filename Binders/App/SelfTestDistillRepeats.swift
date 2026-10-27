import AppKit
import SwiftUI
import BindersKit

extension SelfTest {
    /// Lane BF2: the repeats Distill Again proposed in other words, read by build 41's test copy again and again, left out
    /// of a note's proposals: the first of each stays, a placed card counts, a proposal with nothing left waiting is done,
    /// and nothing is left out twice. In a throwaway folder (BINDERS_DATA_DIR) only.
    ///
    ///     BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-distill-repeats -notesShowMarkdown NO
    @MainActor
    static func distillRepeatsSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes a note's distills")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let controller = DictationController()
        let service = controller.distill
        let store = DistillStore.shared
        let note = UUID()
        let placed = DistillItem(title: "Store 7 days of jobs, encrypted", brief: "", section: "Storage", card: UUID())
        let first = DistillRecord(note: note, ranBy: "You", readBy: "Binders", status: .placed, items: [placed])
        let repeated = DistillItem(title: "Store the last 7 days of jobs encrypted", brief: "", section: "Storage")
        let fresh = DistillItem(title: "Rotate the device key monthly", brief: "", section: "Storage")
        var waiter = DistillItem(title: "Wipe jobs older than 7 days", brief: "", section: "Storage")
        waiter.waitsFor = [repeated.id]
        let second = DistillRecord(note: note, ranBy: "You", readBy: "Binders", items: [repeated, fresh, waiter])
        let onlyRepeats = DistillRecord(note: note, ranBy: "You", readBy: "Binders",
                                        items: [DistillItem(title: "Rotate device keys monthly", brief: "", section: "Storage")])
        store.update(note) { $0.distills = [first, second, onlyRepeats] }

        check(service.coalesce(note) == 2, "two repeats left out")
        let file = store.file(for: note)
        let kept = file.distills[1].items
        check(kept.first { $0.id == repeated.id }?.dropped == true && kept.first { $0.id == fresh.id }?.dropped == false,
              "the one like a placed card goes; the first of the others stays")
        check(kept.first { $0.id == waiter.id }?.waitsFor.isEmpty == true, "a wait on a repeat goes with it")
        check(file.distills[1].status == .proposed && file.distills[2].status == .placed, "a proposal with nothing left waiting is done")
        check(file.distills[0] == first, "what was placed is as it was")
        check(service.coalesce(note) == 0, "nothing twice")

        print(failures == 0 ? "DISTILL_REPEATS_OK" : "DISTILL_REPEATS_FAILED \(failures)")
        return failures == 0 ? 0 : 1
    }
}
