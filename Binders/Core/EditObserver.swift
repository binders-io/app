import AppKit
import ApplicationServices
import BindersKit

/// Watches the field a dictation was pasted into and learns spelling fixes the user makes right afterwards.
@MainActor
final class EditObserver {
    private let element: AXUIElement
    private let inserted: String
    private let onCorrections: ([LearnedCorrection]) -> Void
    private var initialValue: String?
    private var lastValue: String?
    private var timer: Timer?
    private var ticks = 0
    private var finished = false

    init(element: AXUIElement, inserted: String, onCorrections: @escaping ([LearnedCorrection]) -> Void) {
        self.element = element
        self.inserted = inserted
        self.onCorrections = onCorrections
    }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.finished else { return }
            self.initialValue = ContextReader.value(of: self.element)
            self.lastValue = self.initialValue
            guard self.initialValue?.contains(self.inserted) == true else {
                self.finished = true
                return
            }
            self.timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    private func tick() {
        ticks += 1
        guard ticks <= 40, let focused = ContextReader.focusedElement(), CFEqual(focused, element),
              let value = ContextReader.value(of: element) else {
            finish()
            return
        }
        lastValue = value
    }

    func finish() {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        guard let initialValue, let lastValue, initialValue != lastValue,
              let edited = EditLearner.editedRegion(initialValue: initialValue, inserted: inserted, finalValue: lastValue) else { return }
        let corrections = EditLearner.corrections(inserted: inserted, edited: edited, isKnownWord: SpellCheck.isKnownWord)
        if !corrections.isEmpty { onCorrections(corrections) }
    }
}
