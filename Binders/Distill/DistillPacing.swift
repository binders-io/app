import Foundation
import BindersKit

// Lane DS7: what Distill keeps of how fast its models read, the stop you ask for while a note is read, and the quicker
// model a slow reading offers. The rules are BindersKit's (`StreamPace`, `DistillSpeed`, `DistillBudget.paced`,
// `DistillQuicker`).

/// How fast each model read Distill's questions and wrote its answers (`DistillSpeed`), in the app's defaults under
/// "distillSpeeds", by model name. Measured on every ask that says enough; used to size a slow model's parts.
enum DistillSpeeds {
    static let key = "distillSpeeds"
    private static let lock = NSLock()

    static func all() -> [String: DistillSpeed] {
        lock.withLock {
            guard let data = AppDefaults.store.data(forKey: key) else { return [:] }
            return (try? JSONDecoder().decode([String: DistillSpeed].self, from: data)) ?? [:]
        }
    }

    static func speed(of model: String) -> DistillSpeed? { all()[model] }

    /// One ask's measure, blended into what was kept for `model`. `prompt`: the question's characters, its instructions
    /// included.
    /// `tokens`: the reply's own count, where the model gives it (one in Binders, lane DS8), for its prefill and decode
    /// speeds in tokens.
    static func record(model: String, prompt: Int, timing: StreamTiming, tokens: ReplyTokens? = nil) {
        guard !model.isEmpty, var measured = DistillSpeed.measured(prompt: prompt, timing: timing) else { return }
        measured.prefillTokensPerSecond = tokens?.prefillPerSecond
        measured.decodeTokensPerSecond = tokens?.decodePerSecond
        lock.withLock {
            var speeds = (AppDefaults.store.data(forKey: key)).flatMap { try? JSONDecoder().decode([String: DistillSpeed].self, from: $0) } ?? [:]
            speeds[model] = speeds[model].map { $0.blended(measured) } ?? measured
            if let data = try? JSONEncoder().encode(speeds) { AppDefaults.store.set(data, forKey: key) }
        }
    }

    /// Forgets every measure (the self-test starts clean).
    static func forget() {
        lock.withLock { AppDefaults.store.removeObject(forKey: key) }
    }
}

/// Stop, for a note being read: set from the Work bar, looked at by the reply's pace and before each part.
final class DistillStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    var isSet: Bool { lock.withLock { set } }
    func raise() { lock.withLock { set = true } }
}

/// How often "9 items so far" is counted again from the reply as it grows.
final class DistillProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private let every: TimeInterval
    private var last = Date.distantPast

    init(every: TimeInterval) { self.every = every }

    /// Whether it's time to count again.
    func due() -> Bool {
        lock.withLock {
            let now = Date()
            guard now.timeIntervalSince(last) >= every else { return false }
            last = now
            return true
        }
    }
}

/// What a reading that took long, or was cut short, leaves on the Work bar: how long it took with which model, and a
/// quicker installed model for Distill, when there is one.
struct DistillSlowReading: Equatable {
    var line: String
    /// The quicker model's Hugging Face name, and its name for people.
    var quicker: String?
    var quickerName: String?

    /// "Use Gemma 4 26B for Distill?"
    var offer: String? { quickerName.map { "Use \($0) for Distill?" } }
}

extension DistillService {
    /// The quicker model to offer for Distill instead of `model`, among those installed in Binders, when `model` runs in
    /// Binders too (`DistillQuicker.pick`).
    func quicker(than model: String, place: ModelPlace) -> (id: String, name: String)? {
        guard place == .inApp else { return nil }
        let speeds = DistillSpeeds.all()
        let installed = MLXModels.shared.installed()
        let current = installed.first { $0.id == model || model.hasSuffix("/" + $0.id.replacingOccurrences(of: "/", with: "--")) }
        guard let current else { return nil }
        let pick = DistillQuicker.pick(current: DistillQuicker.Model(id: current.id, bytes: current.bytes, speed: speeds[current.id] ?? speeds[model]),
                                       among: installed.map { DistillQuicker.Model(id: $0.id, bytes: $0.bytes, speed: speeds[$0.id]) })
        guard let pick else { return nil }
        let name = MLXModels.known.first { $0.id == pick }?.name ?? (pick.split(separator: "/").last.map(String.init) ?? pick)
        return (pick, name)
    }

    /// The line a reading leaves when it was cut short or took `slowAfter` or longer: nil otherwise.
    func slowReading(seconds: TimeInterval, cutShort: Bool, model: String, place: ModelPlace) -> DistillSlowReading? {
        guard cutShort || seconds >= DistillQuicker.slowAfter else { return nil }
        let name = model.hasPrefix("/") ? (model as NSString).lastPathComponent : (model.split(separator: "/").last.map(String.init) ?? model)
        let quicker = quicker(than: model, place: place)
        return DistillSlowReading(line: DistillQuicker.tookLine(seconds: seconds, model: name), quicker: quicker?.id, quickerName: quicker?.name)
    }
}
