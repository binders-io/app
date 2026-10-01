import AppKit
import AVFoundation
import ImageIO

/// What notes show for their pictures and videos: the picture scaled for the screen, or a video's first frame, with how
/// big it is. Each is loaded once, away from the main thread, and editors are told when it's ready.
@MainActor
final class AttachmentPreviews {
    static let shared = AttachmentPreviews()
    /// Posted with the file's URL as the object when its preview is ready, or known to be missing.
    static let ready = Notification.Name("BindersAttachmentPreviewReady")

    struct Preview {
        let image: NSImage
        /// Its own size, in points.
        let size: NSSize
        let isVideo: Bool
        /// A video's length in seconds.
        let duration: Double?
    }

    enum State {
        case loading
        case ready(Preview)
        /// Not there, or not something that can be shown.
        case missing
    }

    private var previews: [URL: Preview] = [:]
    private var missing: Set<URL> = []
    private var loading: Set<URL> = []

    func state(of url: URL) -> State {
        if let preview = previews[url] { return .ready(preview) }
        if missing.contains(url) { return .missing }
        load(url)
        return .loading
    }

    /// Forgets a file, e.g. once it's been replaced.
    func forget(_ url: URL) {
        previews[url] = nil
        missing.remove(url)
    }

    private func load(_ url: URL) {
        guard loading.insert(url).inserted else { return }
        let isVideo = ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased())
        Task.detached(priority: .userInitiated) {
            let loaded: (CGImage, NSSize, Double?)? = isVideo ? await Self.videoFrame(url) : await Self.picture(url)
            await MainActor.run {
                self.loading.remove(url)
                if let (image, size, duration) = loaded {
                    self.previews[url] = Preview(image: NSImage(cgImage: image, size: size), size: size, isVideo: isVideo, duration: duration)
                } else {
                    self.missing.insert(url)
                }
                NotificationCenter.default.post(name: Self.ready, object: url)
            }
        }
    }

    /// A picture, at most 2,400 pixels across, the way it should stand; its size in points from its own resolution.
    private nonisolated static func picture(_ url: URL) async -> (CGImage, NSSize, Double?)? {
        let source: CGImageSource?
        if url.isFileURL {
            source = CGImageSourceCreateWithURL(url as CFURL, nil)
        } else {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
            source = CGImageSourceCreateWithData(data as CFData, nil)
        }
        guard let source, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        var width = (properties[kCGImagePropertyPixelWidth] as? CGFloat) ?? 0
        var height = (properties[kCGImagePropertyPixelHeight] as? CGFloat) ?? 0
        // Turned on its side by its orientation: the other way round.
        if let orientation = properties[kCGImagePropertyOrientation] as? UInt32, orientation >= 5 { swap(&width, &height) }
        let dpi = (properties[kCGImagePropertyDPIWidth] as? CGFloat) ?? 72
        let scale = dpi >= 144 ? 2 : 1 as CGFloat
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 2400, kCGImageSourceShouldCacheImmediately: true]
        guard width > 0, height > 0, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return (image, NSSize(width: width / scale, height: height / scale), nil)
    }

    /// A video's first frame, upright, and how long it runs.
    private nonisolated static func videoFrame(_ url: URL) async -> (CGImage, NSSize, Double?)? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 2400, height: 2400)
        guard let (image, _) = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)) else { return nil }
        let duration = try? await asset.load(.duration).seconds
        let size = NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
        return (image, size, duration)
    }
}
