import AppKit
import WebKit
import BindersKit

// Lane MM1: Mermaid diagrams, drawn on this Mac with the copy of Mermaid in Binders' resources. One web view, offscreen,
// made when the first diagram needs drawing and let go after a while unused, so a note without diagrams costs nothing.
//
// Locked down: the page is a blank one Binders writes, with no address it could reach; a content rule list blocks every
// load; the page's own JavaScript is off, so nothing in a diagram can run (Mermaid and the few lines that call it run as
// Binders' scripts, in a world of their own); there's no message handler, so the page can't call Binders; and no UI
// delegate, so it can't open windows or alerts. The note's text goes in as an argument (callAsyncJavaScript), never pasted
// into a script. What comes back is the drawing's size or Mermaid's message, and then a snapshot of the page.
//
// Why a snapshot and not NSImage(data:) from the SVG: Mermaid's drawings carry their look in CSS and their labels in
// foreignObject HTML, which AppKit's SVG reading leaves out. The snapshot is what WebKit drew, at the screen's scale.

@MainActor
final class MermaidRenderer: NSObject, WKNavigationDelegate {
    static let shared = MermaidRenderer()

    /// Posted when a drawing, or the reason there's none, is ready; the object is its cache key.
    static let drawn = Notification.Name("BindersMermaidDrawn")

    /// Mermaid's themes: "neutral" in the light (greys that sit on paper and on a binder's colour), "dark" in the dark.
    enum Theme: String {
        case light = "neutral"
        case dark = "dark"
    }

    /// One diagram to draw: its text, the theme, and the width of the text it's shown in.
    struct Request: Hashable {
        let source: String
        let theme: Theme
        let width: CGFloat

        var key: String { MarkdownDiagrams.cacheKey(source: source, theme: theme.rawValue, width: Double(width)) }
        /// The widest it's drawn: the width rounded down to a step, so drawings are kept per step.
        var maxWidth: Int { MarkdownDiagrams.widthBucket(Double(width)) }
    }

    enum Drawing {
        case image(NSImage)
        /// The quiet line shown under the code instead: "Mermaid couldn't draw this: …".
        case failed(String)
    }

    private final class Entry: NSObject {
        let drawing: Drawing
        init(_ drawing: Drawing) { self.drawing = drawing }
    }

    /// How long the web view stays after its last drawing before it's let go.
    static var idleRelease: TimeInterval = 90
    /// A diagram that takes longer than this isn't drawn, and the page that was drawing it goes.
    static var timeout: TimeInterval = 10
    /// The tallest a diagram is drawn; taller ones are scaled down to it.
    static let maxHeight = 900
    /// Text longer than this isn't sent to Mermaid (its own limit is 50,000 characters).
    static let maxSource = 50_000

    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 400
        // Pixels × 4 bytes: about 96 MB of drawings, a few hundred diagrams at a Retina screen's scale.
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    private var queue: [Request] = []
    private var waiting = Set<String>()
    private var busy = false
    private var webView: WKWebView?
    private var pageReady = false
    private var pageWaiters: [CheckedContinuation<Bool, Never>] = []
    private var idleTimer: Timer?
    private static var ruleList: WKContentRuleList?

    /// For the self-test: pages loaded, diagrams drawn, and whether a web view is held now.
    private(set) var pagesLoaded = 0
    private(set) var drawings = 0
    /// How long the last page took to be ready, from making the web view (the self-test).
    private(set) var lastLoadTime: TimeInterval = 0
    private var loadStarted = Date()
    var isLoaded: Bool { webView != nil }

    /// The drawing kept for `request`, if it's been drawn.
    func drawing(for request: Request) -> Drawing? {
        cache.object(forKey: request.key as NSString)?.drawing
    }

    /// Draws `request` in turn, unless it's drawn or waiting already; `drawn` is posted when it's done.
    func draw(_ request: Request) {
        guard drawing(for: request) == nil, waiting.insert(request.key).inserted else { return }
        queue.append(request)
        pump()
    }

    /// Forgets every drawing (the self-test, timing a cold start).
    func forgetDrawings() {
        cache.removeAllObjects()
    }

    /// Lets the web view go now; the next diagram makes a new one.
    func release() {
        idleTimer?.invalidate()
        idleTimer = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        pageReady = false
        let waiters = pageWaiters
        pageWaiters = []
        waiters.forEach { $0.resume(returning: false) }
    }

    private func pump() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        idleTimer?.invalidate()
        let request = queue.removeFirst()
        Task { @MainActor in
            let drawing = await self.drawWithTimeout(request)
            let cost: Int
            if case .image(let image) = drawing {
                cost = image.representations.map { $0.pixelsWide * $0.pixelsHigh * 4 }.max() ?? 0
            } else {
                cost = 64
            }
            self.cache.setObject(Entry(drawing), forKey: request.key as NSString, cost: cost)
            self.waiting.remove(request.key)
            self.drawings += 1
            self.busy = false
            NotificationCenter.default.post(name: Self.drawn, object: request.key)
            if self.queue.isEmpty { self.scheduleRelease() } else { self.pump() }
        }
    }

    private func scheduleRelease() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleRelease, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.busy, self.queue.isEmpty else { return }
                self.release()
            }
        }
    }

    private func drawWithTimeout(_ request: Request) async -> Drawing {
        guard (request.source as NSString).length <= Self.maxSource else {
            return .failed("Mermaid couldn't draw this: it's longer than \(Self.maxSource.formatted()) characters.")
        }
        return await withCheckedContinuation { continuation in
            var finished = false
            func finish(_ drawing: Drawing) {
                guard !finished else { return }
                finished = true
                continuation.resume(returning: drawing)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
                MainActor.assumeIsolated {
                    guard !finished else { return }
                    // The page is stuck on it: it goes, and the next diagram gets a fresh one.
                    self?.release()
                    finish(.failed("Mermaid couldn't draw this: it took longer than \(Int(Self.timeout)) seconds."))
                }
            }
            Task { @MainActor in finish(await self.render(request)) }
        }
    }

    private func render(_ request: Request) async -> Drawing {
        guard let webView = await readyWebView() else {
            return .failed("Mermaid couldn't draw this: Binders' copy of Mermaid didn't load.")
        }
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(
                "return await bindersDrawDiagram(source, theme, maxWidth, maxHeight)",
                arguments: ["source": request.source, "theme": request.theme.rawValue, "maxWidth": request.maxWidth, "maxHeight": Self.maxHeight],
                in: nil, contentWorld: .defaultClient)
        } catch {
            return .failed(MarkdownDiagrams.errorLine(error.localizedDescription))
        }
        guard let reply = result as? [String: Any] else { return .failed(MarkdownDiagrams.errorLine("")) }
        if let message = reply["error"] as? String { return .failed(MarkdownDiagrams.errorLine(message)) }
        guard let width = (reply["width"] as? NSNumber)?.doubleValue, let height = (reply["height"] as? NSNumber)?.doubleValue,
              width >= 1, height >= 1, width <= 10_000, height <= 10_000 else {
            return .failed("Mermaid couldn't draw this: the drawing came out empty.")
        }
        let size = NSSize(width: ceil(width), height: ceil(height))
        // The view as big as the drawing, which sits at its top left, then a picture of it.
        webView.setFrameSize(size)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(origin: .zero, size: size)
        configuration.afterScreenUpdates = true
        do {
            let image = try await webView.takeSnapshot(configuration: configuration)
            image.size = size
            return .image(image)
        } catch {
            return .failed("Mermaid couldn't draw this: \(error.localizedDescription)")
        }
    }

    // MARK: The page

    /// The web view with Mermaid loaded, made now if there's none; nil if it can't load.
    private func readyWebView() async -> WKWebView? {
        if let webView, pageReady { return webView }
        if webView == nil {
            loadStarted = Date()
            guard let made = await makeWebView() else { return nil }
            webView = made
            made.loadHTMLString(Self.page, baseURL: nil)
        }
        let ready = await withCheckedContinuation { continuation in
            if pageReady { continuation.resume(returning: true) } else { pageWaiters.append(continuation) }
        }
        return ready ? webView : nil
    }

    private func makeWebView() async -> WKWebView? {
        guard let script = Self.mermaidScript() else { return nil }
        if Self.ruleList == nil {
            let store = WKContentRuleListStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("Binders diagram rules", isDirectory: true))
            Self.ruleList = try? await store?.compileContentRuleList(forIdentifier: "io.binders.mermaid.offline", encodedContentRuleList: Self.rules)
        }
        // No drawing without the rule list: it's what keeps the page off the network.
        guard let ruleList = Self.ruleList else { return nil }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(ruleList)
        // Mermaid and the lines that call it, as Binders' scripts in their own world; the page's own scripts never run.
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController.addUserScript(WKUserScript(source: Self.drawScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        // A clear page: the drawing goes on the note's own background.
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        return webView
    }

    /// Mermaid, from Binders' resources.
    private static func mermaidScript() -> String? {
        let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js")
            ?? Bundle.main.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "Mermaid")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// Every load blocked: the page is written in, and nothing else may come.
    static let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#

    private static let page = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
    <style>html,body{margin:0;padding:0;background:transparent}#diagram svg{display:block}</style>
    </head><body><div id="diagram"></div></body></html>
    """

    /// Draws one diagram in the page at the size it's shown, and says how big, or Mermaid's message.
    private static let drawScript = """
    (() => {
      let count = 0;
      globalThis.bindersDrawDiagram = async (source, theme, maxWidth, maxHeight) => {
        const holder = document.getElementById('diagram');
        holder.replaceChildren();
        const id = 'binders-diagram-' + (++count);
        mermaid.initialize({
          startOnLoad: false, securityLevel: 'strict', theme: theme, suppressErrorRendering: true,
          fontFamily: '-apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif'
        });
        try {
          const { svg } = await mermaid.render(id, source);
          holder.innerHTML = svg;
          const drawing = holder.querySelector('svg');
          if (!drawing) { return { error: 'the drawing came out empty' }; }
          const box = drawing.viewBox && drawing.viewBox.baseVal;
          let width = box && box.width ? box.width : drawing.getBBox().width;
          let height = box && box.height ? box.height : drawing.getBBox().height;
          if (!(width > 0 && height > 0)) { return { error: 'the drawing came out empty' }; }
          const scale = Math.min(1, maxWidth / width, maxHeight / height);
          drawing.removeAttribute('style');
          drawing.setAttribute('width', String(width * scale));
          drawing.setAttribute('height', String(height * scale));
          const shown = drawing.getBoundingClientRect();
          return { width: shown.width, height: shown.height };
        } catch (error) {
          for (const leftover of [id, 'd' + id]) { const node = document.getElementById(leftover); if (node) node.remove(); }
          return { error: String((error && (error.message || error.str)) || error) };
        }
      };
    })();
    """

    // MARK: WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated {
            // The blank page Binders writes, once; never anywhere else.
            let first = !pageReady && (navigationAction.request.url?.absoluteString ?? "about:blank") == "about:blank"
            decisionHandler(first ? .allow : .cancel)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            guard webView === self.webView else { return }
            pageReady = true
            pagesLoaded += 1
            lastLoadTime = Date().timeIntervalSince(loadStarted)
            let waiters = pageWaiters
            pageWaiters = []
            waiters.forEach { $0.resume(returning: true) }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { if webView === self.webView { release() } }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { if webView === self.webView { release() } }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { if webView === self.webView { release() } }
    }

    // MARK: Self-test

    /// What a load from the page does (the self-test): Binders' scripts ask for `address` by fetch and by a picture
    /// added straight to the page, past Mermaid's own cleaning. True when the fetch failed.
    func probeLoad(_ address: String) async -> Bool {
        guard let webView = await readyWebView() else { return false }
        let script = """
        const picture = document.createElement('img'); picture.src = address; document.body.appendChild(picture);
        try { await fetch(address); return false; } catch (e) { return true; }
        """
        let blocked = try? await webView.callAsyncJavaScript(script, arguments: ["address": address], in: nil, contentWorld: .defaultClient)
        return (blocked as? Bool) ?? (blocked as? NSNumber)?.boolValue ?? false
    }

    /// The rule list on its own (the self-test): a page with a picture at `address` and nothing else holding it back, in a
    /// web view with only the rule list. Whatever listens there should hear nothing.
    static func ruleListAlone(loading address: String) async {
        let store = WKContentRuleListStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("Binders diagram rules", isDirectory: true))
        guard let list = try? await store?.compileContentRuleList(forIdentifier: "io.binders.mermaid.offline", encodedContentRuleList: rules) else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(list)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
        let escaped = address.replacingOccurrences(of: "\"", with: "&quot;")
        webView.loadHTMLString("<!doctype html><img src=\"\(escaped)/alone.png\"><script>fetch(\"\(escaped)/alone-fetch\")</script>", baseURL: nil)
        for _ in 0..<30 where webView.isLoading { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(500))
        webView.stopLoading()
    }

    /// Whether the page's own JavaScript runs (the self-test: it mustn't).
    func pageScriptsRun() async -> Bool {
        guard let webView = await readyWebView() else { return false }
        _ = try? await webView.callAsyncJavaScript(
            "const s = document.createElement('div'); s.setAttribute('onclick', \"document.body.dataset.ran = 'yes'\"); document.body.appendChild(s); s.click(); return true",
            arguments: [:], in: nil, contentWorld: .defaultClient)
        let page = try? await webView.callAsyncJavaScript("return document.body.dataset.ran || 'no'", arguments: [:], in: nil, contentWorld: .defaultClient)
        return (page as? String) == "yes"
    }
}
