import AVFoundation
import BindersKit
import SwiftUI

/// Answers read out by the hub's speech model, when it has one (it lists `speaks`): the answer's words go to the hub
/// (binders/speak) and its audio comes back to play here. One at a time; tapping again stops it.
@MainActor @Observable
final class HubVoice: NSObject, AVAudioPlayerDelegate {
    static let shared = HubVoice()
    /// The feature a hub lists at hello when it reads answers out.
    static let feature = "speaks"

    /// The words being read out, or fetched to be.
    private(set) var reading: String?
    private(set) var fetching = false
    private(set) var problem: String?
    private var player: AVAudioPlayer?

    /// Reads `text` out, or stops when it's the one being read.
    func toggle(_ text: String, with connection: MacConnection) {
        if reading == text {
            stop()
            return
        }
        stop()
        reading = text
        fetching = true
        problem = nil
        Task { @MainActor in
            defer { fetching = false }
            do {
                let reply = try await connection.request("binders/speak", ["text": Self.spoken(text)]) as? [String: Any]
                guard reading == text else { return }
                guard let encoded = reply?["audio"] as? String, let audio = Data(base64Encoded: encoded) else { throw CocoaError(.fileReadCorruptFile) }
                let session = AVAudioSession.sharedInstance()
                // Dictating the question left the session for recording only: playing needs one that plays too. All-day
                // capture's own (play and record) already does, and is left as it is.
                if session.category == .record {
                    try? session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])
                }
                try? session.setActive(true)
                let player = try AVAudioPlayer(data: audio)
                player.delegate = self
                self.player = player
                player.play()
            } catch {
                guard reading == text else { return }
                reading = nil
                problem = (error as? LocalizedError)?.errorDescription ?? "Your hub couldn't read that out."
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        reading = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.player === player { self.stop() }
        }
    }

    /// An answer as words to say: no citation marks, links as their words, no Markdown's marks.
    static func spoken(_ markdown: String) -> String {
        let linked = markdown.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        let plain = linked.replacingOccurrences(of: #"[*_#`>]+"#, with: "", options: .regularExpression)
        return String(CaptureOutcome.speakable(plain).prefix(4000))
    }
}

/// Listen, under an answer, when the hub reads answers out.
struct HubListenButton: View {
    @Environment(MacConnection.self) private var connection
    let text: String
    private var voice: HubVoice { .shared }

    var body: some View {
        let playing = voice.reading == text
        VStack(alignment: .leading, spacing: 4) {
            Button {
                voice.toggle(text, with: connection)
            } label: {
                if playing && voice.fetching {
                    Label { Text("Getting your hub's voice…") } icon: { ProgressView() }
                } else {
                    Label(playing ? "Stop" : "Listen", systemImage: playing ? "stop.fill" : "speaker.wave.2")
                }
            }
            .font(.subheadline)
            .disabled(!connection.isConnected)
            .accessibilityIdentifier("hubListen")
            if let problem = voice.problem, !playing { ProblemLabel(problem) }
        }
        .onDisappear { if voice.reading == text { voice.stop() } }
    }
}
