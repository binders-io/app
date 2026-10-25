import Foundation
import IOKit.ps
import BindersKit

/// Lane DS9: Distill in the background while you write. For a note with Distill on, once your typing in it has paused for
/// `idle` (20 seconds) and what you changed is more than space and markup (`DistillBackground.meaningful`), the sections
/// that changed are read again quietly (`DistillService.refresh(note:background:)`), in the background model lane: no sweep,
/// no flying cards, no sheet, alert or notification; the new items wait in the Distill list and as a count on the Distill
/// button and the Work bar. One reading at a time across the app, and none while you dictate, record a meeting or capture
/// all day, on a low battery or in Low Power Mode, while the Mac is hot, or while you run a Distill yourself: one under way
/// then stops, keeping what it read. Nothing is placed on the board until you accept it.
@MainActor
final class DistillBackgroundReader {
    /// "Distill in the background while I write" in Settings → AI: on unless turned off.
    nonisolated static let enabledKey = "distillInBackground"

    nonisolated static var enabled: Bool {
        get { AppDefaults.store.object(forKey: enabledKey) as? Bool ?? true }
        set { AppDefaults.store.set(newValue, forKey: enabledKey) }
    }

    private weak var service: DistillService?
    /// How long a note's typing pauses before it's looked at. The self-tests make it short.
    var idle: Duration = .seconds(DistillBackground.idle)
    /// How often a held-back reading looks again whether it can go, and how often one under way looks whether it must stop.
    var recheck: Duration = .seconds(15)
    var watchEvery: Duration = .milliseconds(500)
    /// In place of what the Mac says, for the self-tests.
    var conditionsOverride: (() -> DistillBackground.Conditions)?
    /// Each note's pause in typing being waited out.
    private var timers: [UUID: Task<Void, Never>] = [:]
    /// Notes due a reading, oldest first, and the one being read.
    private(set) var due: [UUID] = []
    private(set) var current: UUID?
    private var running: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    /// Why the last look didn't read, for the self-tests and the list's line.
    private(set) var lastPause: DistillBackground.Pause?
    /// For the self-tests: each note a reading in the background started for, and each that ended, with its outcome.
    private(set) var started: [UUID] = []
    private(set) var finished: [(note: UUID, outcome: String)] = []

    init(service: DistillService) {
        self.service = service
    }

    /// You typed in the note: its pause starts again. Nothing is read on a keystroke.
    func typed(_ id: UUID) {
        guard Self.enabled, Store.shared.note(id)?.distill == true else { return }
        timers[id]?.cancel()
        let idle = idle
        timers[id] = Task { [weak self] in
            try? await Task.sleep(for: idle)
            guard !Task.isCancelled, let self else { return }
            self.timers[id] = nil
            self.look(at: id)
        }
    }

    /// The pause is over: due a reading when what changed since the last one is worth it.
    func look(at id: UUID) {
        guard let service, let note = Store.shared.note(id), note.distill, Self.enabled else { return }
        guard worthReading(note, service: service) else { return }
        if !due.contains(id), current != id { due.append(id) }
        pump()
    }

    /// Whether what changed since the note was last read is more than space and markup, in a section read before.
    func worthReading(_ note: NoteItem, service: DistillService) -> Bool {
        guard service.hasChangedSections(note: note) else { return false }
        guard let before = service.lastRead[note.id] ?? lastReadText(of: note) else { return true }
        return DistillBackground.meaningful(from: before, to: note.text)
    }

    /// The text the note's last distill read, kept in its history, when this Mac hasn't read it since it started.
    private func lastReadText(of note: NoteItem) -> String? {
        guard let version = DistillStore.shared.file(for: note.id).distills.last?.version else { return nil }
        return NoteHistory.text(of: version, note: note)
    }

    /// What holds a reading back now, if anything.
    func pause() -> DistillBackground.Pause? {
        DistillBackground.pause(conditions())
    }

    /// What the Mac is doing now.
    func conditions() -> DistillBackground.Conditions {
        if let conditionsOverride { return conditionsOverride() }
        guard let service, let controller = service.controller else { return DistillBackground.Conditions(enabled: false) }
        var dictating = true
        if case .idle = controller.phase { dictating = false }
        let power = Self.power()
        let thermal = ProcessInfo.processInfo.thermalState
        return DistillBackground.Conditions(enabled: Self.enabled, dictating: dictating, recording: controller.meetings.isRecording,
                                            capturing: controller.allDay.isOn, onBattery: power.onBattery, battery: power.level,
                                            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, hot: thermal == .serious || thermal == .critical,
                                            foreground: service.reading.subtracting(service.quietReading).isEmpty == false)
    }

    /// On battery or not, and how full it is (IOKit's power sources); a Mac without a battery is never on it.
    nonisolated static func power() -> (onBattery: Bool, level: Double?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (false, nil) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onBattery = providing == kIOPMBatteryPowerKey
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (onBattery, nil) }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let now = description[kIOPSCurrentCapacityKey] as? Int, let most = description[kIOPSMaxCapacityKey] as? Int, most > 0 else { continue }
            return (onBattery, Double(now) / Double(most))
        }
        return (onBattery, nil)
    }

    /// Starts the next reading due, when none is under way and nothing holds it back; held back, it looks again in a while.
    func pump() {
        guard running == nil, let service else { return }
        guard !due.isEmpty else { return }
        if let why = pause() {
            lastPause = why
            guard why != .off else {
                due.removeAll()
                return
            }
            guard retry == nil else { return }
            let wait = recheck
            retry = Task { [weak self] in
                try? await Task.sleep(for: wait)
                guard let self, !Task.isCancelled else { return }
                self.retry = nil
                self.pump()
            }
            return
        }
        lastPause = nil
        let id = due.removeFirst()
        guard let note = Store.shared.note(id), note.distill, !service.reading.contains(id) else { return pump() }
        current = id
        started.append(id)
        let watch = watchEvery
        running = Task { [weak self] in
            // Stops the reading, keeping what it read, the moment something should hold it back.
            let watcher = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: watch)
                    guard let self, !Task.isCancelled else { return }
                    if let why = self.pause(), service.reading.contains(id) {
                        self.lastPause = why
                        service.stopReading(id)
                        return
                    }
                }
            }
            let result = await service.refresh(note: note, background: true)
            watcher.cancel()
            guard let self else { return }
            switch result {
            case .success(let record):
                // The items it found wait in the list, counted as new until you look.
                service.list(for: id).found(record.waiting.map(\.id))
                self.finished.append((id, "\(record.waiting.count) items"))
            case .failure(let problem):
                self.finished.append((id, "\(problem)"))
            }
            self.current = nil
            self.running = nil
            self.pump()
        }
    }

    /// You started a Distill yourself: a reading in the background stops, keeping what it read, and goes on after.
    func foregroundStarted() {
        guard let current, let service else { return }
        service.stopReading(current)
    }

    /// Until the reading in the background under way, if any, is done (the Distill button waits on it for the same note).
    func settle() async {
        while let running { await running.value }
    }

    /// Whether a reading in the background is due or under way for the note.
    func pending(_ id: UUID) -> Bool { current == id || due.contains(id) || timers[id] != nil }

    /// Every pause and reading forgotten, for the self-tests.
    func reset() {
        timers.values.forEach { $0.cancel() }
        timers = [:]
        due = []
        retry?.cancel()
        retry = nil
        started = []
        finished = []
        lastPause = nil
    }
}

/// Says yes once: the first words of a reply have come (lane DS9), so "Loading …" can go.
final class DistillFirstWords: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func first() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
