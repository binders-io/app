import Foundation

/// A language model that suits a Mac, by how much memory it has.
public struct ModelRecommendation: Equatable, Sendable {
    /// The Ollama tag.
    public let model: String
    /// Size of the download, in gigabytes.
    public let downloadGB: Double
    /// One line on why this one.
    public let reason: String
}

/// Picks the default language model from the Mac's memory. A model has to share unified memory with the system, your
/// apps, the speech model and its own working context, so the download should stay well under half of what the Mac has.
/// Sizes are the published Ollama downloads for the Gemma 4 family.
public enum ModelAdvisor {
    public static let tiers: [(minimumGB: Int, recommendation: ModelRecommendation)] = [
        (48, ModelRecommendation(model: "gemma4:26b", downloadGB: 18.6, reason: "The most capable; quick for its size because only part of it runs per word.")),
        (24, ModelRecommendation(model: "gemma4:12b", downloadGB: 7.6, reason: "Strong notes and answers with room left for your apps.")),
        (12, ModelRecommendation(model: "gemma4:e4b-it-qat", downloadGB: 6.1, reason: "Fast, and light enough for a 16 GB Mac.")),
        (0, ModelRecommendation(model: "gemma4:e2b-it-qat", downloadGB: 4.3, reason: "The smallest that still formats well; right for 8 GB.")),
    ]

    public static func recommendation(memoryGB: Int) -> ModelRecommendation {
        tiers.first { memoryGB >= $0.minimumGB }?.recommendation ?? tiers[tiers.count - 1].recommendation
    }

    /// Physical memory in whole gigabytes, as Apple counts them (8, 16, 24, 36…).
    public static func memoryGB(bytes: UInt64) -> Int {
        Int((Double(bytes) / 1_073_741_824).rounded())
    }

    /// True when a model is likely too large for this Mac: a known tier above the one recommended.
    public static func isTooLarge(_ model: String, memoryGB: Int) -> Bool {
        guard let index = tiers.firstIndex(where: { $0.recommendation.model == model }),
              let fit = tiers.firstIndex(where: { memoryGB >= $0.minimumGB }) else { return false }
        return index < fit
    }
}
