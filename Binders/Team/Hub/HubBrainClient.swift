import Foundation
import BindersKit

/// The hub's brain, from this Mac: a linked binder's questions answered from the notes and cards the team keeps on the
/// hub, and something captured sent there as a note, which the hub sums up when it has a model.
@MainActor
enum HubBrainClient {
    enum Failure: LocalizedError {
        case signedOut
        case otherHub
        /// A hub from before its brain: it doesn't take this yet.
        case notTaken
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .signedOut: "This Mac isn't signed in to the hub."
            case .otherHub: "This binder is linked to a hub this Mac isn't signed in to."
            case .notTaken: "The hub doesn't answer questions yet: it may need updating."
            case .refused(let message): message
            }
        }
    }

    /// The answer from the hub's notes and cards in the binder's Binder there.
    static func ask(_ question: String, place: HubLink.Place) async throws -> HubBrainAnswer {
        let data = try await post("api/brain/ask", place: place, body: ["question": question], timeout: 120)
        guard let answer = HubBrain.answer(from: data) else { throw Failure.refused("The hub's answer couldn't be read.") }
        return answer
    }

    /// Something captured, as a note in the binder on the hub. The note's id.
    @discardableResult
    static func capture(_ request: HubCaptureRequest, place: HubLink.Place) async throws -> String {
        var body = request
        if body.binder == nil { body.binder = place.binder }
        let encoded = try JSONEncoder().encode(body)
        let object = (try JSONSerialization.jsonObject(with: encoded) as? [String: Any]) ?? [:]
        let data = try await post("api/captures", place: place, body: object, timeout: 60)
        struct Made: Decodable { struct Note: Decodable { let id: String }; let note: Note }
        guard let made = try? JSONDecoder().decode(Made.self, from: data) else { throw Failure.refused("The hub's answer couldn't be read.") }
        return made.note.id
    }

    private static func post(_ path: String, place: HubLink.Place, body: [String: Any], timeout: TimeInterval) async throws -> Data {
        let account = HubAccount.shared
        guard account.isSignedIn, var request = account.authorized(path) else { throw Failure.signedOut }
        guard account.address == place.hub else { throw Failure.otherHub }
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(place.space, forHTTPHeaderField: "x-binders-space")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await account.send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 || status == 405 || status == 501 { throw Failure.notTaken }
        guard (200..<300).contains(status) else {
            struct Problem: Decodable { let error: String }
            throw Failure.refused((try? JSONDecoder().decode(Problem.self, from: data))?.error ?? "The hub answered \(status).")
        }
        return data
    }
}
