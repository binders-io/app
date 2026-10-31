import AppKit
import Foundation
import ImageIO
import BindersKit

/// Pictures in linked binders' notes, kept on the hub so the web app and the agents see them too (lane HB3).
///
/// - Going up: a picture added to a linked note here is in the attachments folder (`attachments/<name>`). When the note
///   is compared with the hub (HubNotesSync), each such picture goes on POST /api/files, and the note then names the
///   hub's copy, `/api/files/<hash>.png`, as the web app writes it; that edit goes like any other. The hub takes PNG,
///   JPEG, GIF, WebP, SVG and AVIF up to 20 MB: HEIC, TIFF and BMP are made into JPEG or PNG first. Videos and other
///   files stay on this Mac.
/// - Coming down: a note naming one of the hub's pictures shows the copy kept here, in the attachments folder under the
///   hub's name; one that isn't here yet is fetched from GET /api/files/<name>, then shown. Tidying keeps the ones notes
///   use, and a picture tidied away is fetched again when it's needed.
@MainActor
final class HubPictures {
    static let shared = HubPictures()

    private var account: HubAccount { .shared }

    /// Where a picture goes: the hub, its Binder and the project there. The hub keeps a picture with its note's project
    /// and looks for it only in the Binders the reader may open, so each place gets its own copy: one sent to another
    /// Binder, or another hub, isn't one this place's readers can see.
    struct Place: Hashable {
        let hub: URL
        let space: String
        let binder: String

        init(_ place: HubLink.Place) {
            hub = place.hub
            space = place.space
            binder = place.binder
        }
    }

    /// A picture here on its way to one place.
    private struct Upload: Hashable {
        let place: Place
        let name: String
    }

    /// Notes whose pictures are on their way up: their words wait for them, so the hub gets the note naming its copies.
    private var notesSending: Set<UUID> = []
    private var sending: Set<Upload> = []
    /// Pictures here that have gone up, for each place: their name in the attachments folder, to the hub's name there.
    private var sent: [Place: [String: String]] = [:]
    /// Ones the hub won't take (too big, or not a picture it keeps): they stay on this Mac.
    private var refused: Set<String> = []
    private var fetching: Set<String> = []
    /// The hub's pictures known to be here, so drawing a note doesn't look on disk each time.
    private var here: Set<String> = []
    /// When a picture last couldn't be fetched, or sent to a place: a hub that's away isn't asked again on every save.
    private var failed: [String: Date] = [:]
    private var failedSending: [Upload: Date] = [:]
    var retryAfter: TimeInterval = 30
    /// How many went each way, for the self-tests: "sent", "fetched", "refused".
    private(set) var counts: [String: Int] = [:]

    // MARK: Going up

    /// Whether `note`'s pictures are on their way up, so its words wait.
    func isSending(_ note: UUID) -> Bool { notesSending.contains(note) }

    /// A linked note's pictures that are only on this Mac go to the hub, then the note names the hub's copies.
    /// `hubID`: the note's id on the hub, which keeps its pictures with its binder; `link`: where its binder is linked.
    func send(_ note: NoteItem, hubID: String, link: HubLink.Place) {
        guard account.isSignedIn, !notesSending.contains(note.id) else { return }
        let pictures = HubFiles.localPictures(in: note.text)
        guard !pictures.isEmpty else { return }
        let place = Place(link)
        let there = sent[place] ?? [:]
        let waiting = pictures.filter { name in
            there[name] == nil && !refused.contains(name) && !recentlyFailed(Upload(place: place, name: name))
                && FileManager.default.fileExists(atPath: Attachments.folder.appendingPathComponent(name).path)
        }
        // Nothing to send, and none of its pictures went up to this place before: nothing to change.
        guard !waiting.isEmpty || pictures.contains(where: { there[$0] != nil }) else { return }
        let id = note.id
        notesSending.insert(id)
        Task {
            for name in waiting {
                let upload = Upload(place: place, name: name)
                guard !sending.contains(upload) else { continue }
                sending.insert(upload)
                await self.upload(upload, note: hubID)
                sending.remove(upload)
            }
            point(id, to: place)
            notesSending.remove(id)
            // Its words go now, naming the hub's copies (or as they were, for pictures that couldn't go yet).
            HubNotesSync.shared.sweepSoon()
        }
    }

    /// The note names the hub's copies of the pictures that have gone up to its place.
    private func point(_ id: UUID, to place: Place) {
        MarkdownEditor.flushAll()
        guard let note = Store.shared.note(id) else { return }
        let text = HubFiles.pointing(note.text, to: sent[place] ?? [:])
        guard text != note.text else { return }
        NoteHistory.willChange(note, to: text, always: true, by: .you)
        note.text = text
        note.updatedAt = Date()
        Store.shared.save()
    }

    private func upload(_ upload: Upload, note: String) async {
        let name = upload.name
        let file = Attachments.folder.appendingPathComponent(name)
        guard let (data, type) = Self.prepared(file) else {
            refuse(name, "it isn't a picture the hub keeps, or it's over 20 MB")
            return
        }
        // Signed in to another hub since: it waits for this one.
        guard account.address == upload.place.hub, var request = account.authorized("api/files"), let url = request.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        components.queryItems = [URLQueryItem(name: "note", value: note)]
        request.url = components.url
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        request.setValue(upload.place.space, forHTTPHeaderField: "x-binders-space")
        request.timeoutInterval = 120
        guard let (body, response) = try? await account.send(request) else {
            failedSending[upload] = Date()
            return
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200:
            let answer = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            guard let hubName = answer?["name"] as? String, HubFiles.isHubName(hubName) else {
                failedSending[upload] = Date()
                return
            }
            // Kept here under the hub's name, so the note shows it as soon as it names it.
            keep(data, as: hubName)
            sent[upload.place, default: [:]][name] = hubName
            counts["sent", default: 0] += 1
        case 401:
            failedSending[upload] = Date()
            await account.refresh()
        case 400, 413, 415:
            refuse(name, HubLink.error(in: body) ?? "the hub turned it down")
        default:
            failedSending[upload] = Date()
        }
    }

    private func refuse(_ name: String, _ why: String) {
        refused.insert(name)
        counts["refused", default: 0] += 1
        Log.app.error("A picture stays on this Mac, \(name, privacy: .private): \(why)")
    }

    /// The picture as the hub takes it, and its type: as it is when it can, else made into a JPEG (photos, and anything
    /// too big) or a PNG (screenshots and drawings), upright and at most 4,096 pixels across.
    nonisolated static func prepared(_ file: URL) -> (Data, String)? {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        if let type = HubFiles.contentType(of: file.lastPathComponent), data.count <= HubFiles.largest { return (data, type) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 4096]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        let photo = ["heic", "heif", "jpg", "jpeg"].contains(file.pathExtension.lowercased())
        if !photo, let png = rep.representation(using: .png, properties: [:]), png.count <= HubFiles.largest { return (png, "image/png") }
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]), jpeg.count <= HubFiles.largest else { return nil }
        return (jpeg, "image/jpeg")
    }

    // MARK: Coming down

    /// Where the hub's picture `name` is kept here. Fetched from the hub when it isn't here yet: the note shows it once
    /// it's come (AttachmentPreviews.ready).
    func file(for name: String, space: String? = nil) -> URL {
        let url = Attachments.folder.appendingPathComponent(name)
        if !here.contains(name) {
            if FileManager.default.fileExists(atPath: url.path) { here.insert(name) } else { fetch(name, space: space) }
        }
        return url
    }

    /// The hub's pictures `text` shows that aren't here yet are fetched, so they're here offline too.
    func fetchMissing(in text: String, space: String? = nil) {
        for name in HubFiles.hubNames(in: text) { _ = file(for: name, space: space) }
    }

    private func fetch(_ name: String, space: String? = nil) {
        guard account.isSignedIn, !fetching.contains(name), !recentlyFailed(name), var request = account.authorized("api/files/\(name)") else { return }
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        // Any Binder of the person's will do: the hub looks for a picture in all of theirs.
        if let space = space ?? HubNotesSync.shared.spaces.keys.sorted().first { request.setValue(space, forHTTPHeaderField: "x-binders-space") }
        fetching.insert(name)
        Task {
            defer { fetching.remove(name) }
            guard let (data, response) = try? await account.send(request), (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                failed[name] = Date()
                return
            }
            keep(data, as: name)
            counts["fetched", default: 0] += 1
            let url = Attachments.folder.appendingPathComponent(name)
            AttachmentPreviews.shared.forget(url)
            NotificationCenter.default.post(name: AttachmentPreviews.ready, object: url)
        }
    }

    private func keep(_ data: Data, as name: String) {
        let url = Attachments.folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: Attachments.folder, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        here.insert(name)
    }

    // MARK: Trying again

    private func recentlyFailed(_ name: String) -> Bool {
        failed[name].map { Date().timeIntervalSince($0) < retryAfter } ?? false
    }

    private func recentlyFailed(_ upload: Upload) -> Bool {
        failedSending[upload].map { Date().timeIntervalSince($0) < retryAfter } ?? false
    }

    /// The hub's back: what couldn't go or come is tried again on the next look.
    func backOnline() {
        failed = [:]
        failedSending = [:]
    }

    /// A picture tidied away is no longer here.
    func forget(_ name: String) {
        here.remove(name)
    }
}
