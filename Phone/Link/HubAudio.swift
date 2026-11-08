import AVFoundation
import BindersKit
import Foundation
import UIKit

/// A conversation's audio, sent to the hub to write down when the hub has a transcription model (it lists
/// `transcribes`) and this iPhone is set to send it (on unless turned off under Your Brain). The iPhone still writes its
/// own transcript first, so the conversation is filed at once and everything here that reads its words works as before;
/// the hub writes it down again with its bigger model, keeps the voices this iPhone told apart, and puts its transcript
/// in place of this one. The audio stays on this iPhone until the hub has it (as AAC, made on the way), then goes, unless
/// Keep Audio is on. The hub doesn't keep it.
@MainActor
final class HubAudio {
    static let shared = HubAudio()
    /// The feature a hub lists at hello when it writes down audio.
    static let feature = "transcribes"
    /// On unless turned off: with a hub that writes down audio, this iPhone sends it each conversation's audio.
    static let sendKey = "hubWritesDown"
    private static let pendingKey = "hubAudioPending"
    /// Tries before one is let go: a hub that keeps failing on a recording won't take it on the seventh.
    private static let mostTries = 6

    /// A voice's turn, in seconds into the file, as the diarizer told it ("Speaker 1").
    struct Turn: Codable, Equatable {
        var start: Double
        var end: Double
        var speaker: String
    }

    /// Where a stretch of the file was heard: seconds into the file, and seconds since the conversation started.
    struct Clock: Codable, Equatable {
        var file: Double
        var wall: Double
    }

    struct Pending: Codable, Equatable {
        var id: UUID
        var started: Date
        var ended: Date
        var device: String
        var turns: [Turn]
        var speakers: [String: String]
        var clock: [Clock]
        /// Keep Audio was on: the file stays after it's sent, for the day that setting keeps it.
        var keepAudio: Bool
        var tries = 0
        /// The hub it's for: the one signed in to when it was recorded. Another hub signed in to since doesn't get it.
        var hub: String? = HubBrain.load()?.address.absoluteString
    }

    private enum Sent { case sent, refused, gone, later }

    private(set) var pending: [Pending]
    private var sending = false

    private init() {
        pending = UserDefaults.standard.data(forKey: Self.pendingKey).flatMap { try? JSONDecoder().decode([Pending].self, from: $0) } ?? []
    }

    /// Whether this iPhone sends a hub that writes down audio each conversation's audio.
    static var sends: Bool { UserDefaults.standard.object(forKey: sendKey) as? Bool ?? true }

    /// A conversation filed with this iPhone's transcript, whose audio goes to the hub next.
    func queue(_ item: Pending) {
        pending.removeAll { $0.id == item.id }
        pending.append(item)
        save()
        sendWaiting()
    }

    /// Sends what's waiting, one at a time, while the hub is the brain and the link is up: called when a recording is
    /// queued, and again when the link to the hub comes back.
    func sendWaiting() {
        guard !sending, !pending.isEmpty else { return }
        sending = true
        Task { @MainActor in
            await sendAll()
            sending = false
        }
    }

    private func sendAll() async {
        let background = UIApplication.shared.beginBackgroundTask(withName: "Sending audio to your hub") {}
        defer { UIApplication.shared.endBackgroundTask(background) }
        // Turned off: what was waiting isn't sent, and its audio goes as it would have.
        guard Self.sends else {
            for item in pending { finish(item) }
            return
        }
        var tried: Set<UUID> = []
        while true {
            guard let connection = MacConnection.current, connection.brain == .hub, connection.isConnected,
                  let hub = HubBrain.load(), let token = HubKeychain.load() else { return }
            // Only this hub's; one for a hub signed out of waits, and goes once its audio does (after three days).
            let address = hub.address.absoluteString
            guard let item = pending.first(where: { ($0.hub ?? address) == address && !tried.contains($0.id) }) else { return }
            tried.insert(item.id)
            switch await send(item, to: hub.address, token: token) {
            case .sent, .refused, .gone:
                finish(item)
            case .later:
                guard let index = pending.firstIndex(where: { $0.id == item.id }) else { return }
                pending[index].tries += 1
                if pending[index].tries >= Self.mostTries {
                    finish(pending[index])
                } else {
                    save()
                }
                return
            }
        }
    }

    /// Done with one, sent or not: off the list, and its audio gone unless Keep Audio keeps it.
    private func finish(_ item: Pending) {
        pending.removeAll { $0.id == item.id }
        save()
        if !item.keepAudio { CaptureStore.shared.deleteAudio(item.id) }
    }

    private func save() {
        if pending.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        } else if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: Self.pendingKey)
        }
    }

    private func send(_ item: Pending, to address: URL, token: String) async -> Sent {
        let source = CaptureFiles.audioURL(item.id)
        guard FileManager.default.fileExists(atPath: source.path) else { return .gone }
        guard let described = Self.described(item) else { return .refused }
        guard let compressed = try? await Self.compressed(source) else { return .later }
        defer { try? FileManager.default.removeItem(at: compressed) }
        var request = URLRequest(url: address.appendingPathComponent("api/app/audio"), timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue(described, forHTTPHeaderField: "X-Binders-Capture")
        do {
            let (_, response) = try await URLSession.shared.upload(for: request, fromFile: compressed)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200..<300: return .sent
            // Too long, or the hub has no transcription model now: this iPhone's transcript stays as it was filed.
            case 413, 422: return .refused
            // Signed out (the link says so and waits for signing in again), or the hub is busy: later.
            default: return .later
            }
        } catch {
            return .later
        }
    }

    /// What the recording is, as the hub reads it from the X-Binders-Capture header: JSON, percent-encoded.
    private static func described(_ item: Pending) -> String? {
        let iso = ISO8601DateFormatter()
        let object: [String: Any] = [
            "id": item.id.uuidString, "started": iso.string(from: item.started), "ended": iso.string(from: item.ended), "device": item.device,
            "turns": item.turns.map { ["start": $0.start, "end": $0.end, "speaker": $0.speaker] }, "speakers": item.speakers,
            "clock": item.clock.map { ["file": $0.file, "wall": $0.wall] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object), let json = String(data: data, encoding: .utf8) else { return nil }
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-_.!~*'()")
        return json.addingPercentEncoding(withAllowedCharacters: unreserved)
    }

    /// The capture's audio as AAC in an .m4a, a tenth of its size, for the trip to the hub.
    nonisolated private static func compressed(_ source: URL) async throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("hub-audio-\(UUID().uuidString).m4a")
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw CocoaError(.fileReadUnknown) }
        if #available(iOS 18, *) {
            try await export.export(to: out, as: .m4a)
        } else {
            export.outputURL = out
            export.outputFileType = .m4a
            await export.export()
            if let error = export.error { throw error }
            guard export.status == .completed else { throw CocoaError(.fileWriteUnknown) }
        }
        return out
    }
}
