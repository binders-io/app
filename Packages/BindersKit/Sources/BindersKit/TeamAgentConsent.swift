import Foundation

/// Giving a card to a teammate's agent, on the iPhone, as an earlier Binders for Mac listed them: the first time, Binders
/// asks once, naming its owner and who it sends cards to.
public enum TeamAgentConsent {
    /// "It sends them to Anthropic. It runs on Dana's Mac."
    public static func message(owner: String, sendsTo: String?, headless: Bool = false) -> String {
        let sends = sendsTo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let first = sends.isEmpty ? "\(owner) hasn't said where it sends them." : "It sends them to \(sends)."
        return first + (headless ? " It runs on its own, as \(owner)'s agent." : " It runs on \(owner)'s Mac.")
    }
}
