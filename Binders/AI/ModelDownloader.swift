import Foundation
import Observation
import BindersKit

/// Downloads a language model through Ollama's own pull API, with progress, so nobody has to open a terminal.
@MainActor
@Observable
final class ModelDownloader {
    static let shared = ModelDownloader()

    private(set) var model: String?
    private(set) var progress: Double?
    private(set) var error: String?

    var isDownloading: Bool { model != nil }

    static var memoryGB: Int { ModelAdvisor.memoryGB(bytes: ProcessInfo.processInfo.physicalMemory) }
    static var recommendation: ModelRecommendation { ModelAdvisor.recommendation(memoryGB: memoryGB) }

    /// Returns true once the model is installed.
    @discardableResult
    func pull(_ name: String, from baseURL: String) async -> Bool {
        guard !isDownloading, let base = URL(string: baseURL) else { return false }
        model = name
        progress = 0
        error = nil
        defer { model = nil; progress = nil }
        var request = URLRequest(url: base.appendingPathComponent("api/pull"), timeoutInterval: 7_200)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name, "stream": true])
        do {
            let (bytes, _) = try await URLSession.shared.bytes(for: request)
            for try await line in bytes.lines {
                guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                if let message = json["error"] as? String {
                    error = message
                    return false
                }
                if let total = json["total"] as? Double, total > 0, let completed = json["completed"] as? Double {
                    progress = max(progress ?? 0, completed / total)
                }
            }
            return true
        } catch {
            self.error = "Download failed: \(error.localizedDescription)"
            return false
        }
    }
}
