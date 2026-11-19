import ScreenSaver
import WebKit
import os

private let log = Logger(subsystem: "com.claude.lockscreen.saver", category: "view")

/// Web view that never takes mouse or keyboard events, so the screen saver engine
/// still sees them and can dismiss itself.
private final class PassiveWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

/// Shows the lock screen page served by server.js. If the server isn't running it shows
/// the bundled copy (offline fun mode) and switches to the live page once the server is back.
@objc(ClaudeLockscreenView)
final class ClaudeLockscreenView: ScreenSaverView, WKNavigationDelegate {
    private static let liveURL = URL(string: "http://127.0.0.1:4777/?screensaver=1")!
    private static let statusURL = URL(string: "http://127.0.0.1:4777/status")!

    /// One web view per screen size, kept alive between activations: the page is already loaded
    /// and painted when the screensaver starts, instead of loading behind a black screen.
    private static var cache: [String: PassiveWebView] = [:]

    private var webView: PassiveWebView?
    private var probeTimer: Timer?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        log.notice("init frame=\(NSStringFromRect(frame), privacy: .public) preview=\(isPreview)")
        animationTimeInterval = 1 // the page animates itself
        autoresizesSubviews = true
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        attachWebView() // start loading now; startAnimation comes ~0.5s later
        // No lock UI watch here: macOS sometimes creates a view it starts much later, or never, and a watch
        // started now caught you using the Mac and switched the shared page into Unlock mode for nothing.
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }

    override func startAnimation() {
        super.startAnimation()
        // macOS reuses views without stopping them, and another display's view may have taken our cached page.
        if let view = webView, view.superview !== self { webView = nil }
        attachWebView()
        fitWebView()
        checkServer()
        log.notice("start bounds=\(NSStringFromRect(self.bounds), privacy: .public) screen=\(self.window.flatMap { $0.screen.map { NSStringFromRect($0.frame) } } ?? "-", privacy: .public)")
        startLockUIWatch()
    }

    // The page always fills this view: when macOS moves or resizes it (displays change, a reused view
    // ends up on another screen), a page sized for the old frame would be cropped or leave a gap.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitWebView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fitWebView()
    }

    private func fitWebView() {
        guard let view = webView, view.superview === self, view.frame != bounds else { return }
        log.notice("resizing page \(NSStringFromRect(view.frame), privacy: .public) -> \(NSStringFromRect(self.bounds), privacy: .public)")
        view.frame = bounds
    }

    override func stopAnimation() {
        super.stopAnimation()
        log.notice("stop")
        stopLockUIWatch()
        probeTimer?.invalidate()
        probeTimer = nil
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview() // stays cached (and hidden, so it stops animating) for next time
        webView = nil
    }

    private func attachWebView() {
        guard webView == nil, bounds.width > 0 else { return }
        let key = "\(Int(bounds.width))x\(Int(bounds.height))\(isPreview ? "-preview" : "")"
        let view: PassiveWebView
        // Reuse a warm page only if no other view is showing it: taking it would leave that display
        // with nothing, and (when it's on another screen) put a page of the wrong size here.
        if let cached = Self.cache[key], cached.superview === self || cached.superview?.window?.isVisible != true {
            cached.removeFromSuperview()
            view = cached
            view.frame = bounds
            log.notice("reusing warm page for \(key, privacy: .public)")
        } else {
            view = PassiveWebView(frame: bounds, configuration: WKWebViewConfiguration())
            view.autoresizingMask = [.width, .height]
            view.setValue(false, forKey: "drawsBackground")
            // The screen saver window can look occluded to WebKit, which then stops painting (black screen).
            if view.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) {
                view.setValue(false, forKey: "windowOcclusionDetectionEnabled")
            }
            view.load(URLRequest(url: Self.liveURL))
            Self.cache[key] = view
        }
        view.navigationDelegate = self
        addSubview(view)
        webView = view
        if view.url?.isFileURL == true || view.url == Self.blankURL { waitForServer() } // cached while the server was down
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log.notice("loaded \(webView.url?.absoluteString ?? "-", privacy: .public) frame=\(NSStringFromRect(webView.frame), privacy: .public)")
        webView.evaluateJavaScript("window.setSystemLockUI && window.setSystemLockUI(\(systemLockUI))")
        let probe = "JSON.stringify([innerWidth, innerHeight, document.documentElement.dataset.theme, document.body.dataset.state, document.visibilityState])"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            webView.evaluateJavaScript(probe) { result, error in
                log.notice("page \(String(describing: result ?? error), privacy: .public)")
            }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.error("web content process terminated, reloading")
        webView.reload()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log.error("load failed: \(error.localizedDescription, privacy: .public)")
        serverDown(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        serverDown(webView)
    }

    /// No server means the app was quit (Agent Aquarium is off), or it's starting up: the screensaver shows
    /// nothing (black) and switches to the live page when the server is back. The small preview in System
    /// Settings still shows the bundled copy, so you can see what you're picking.
    private static let blankURL = URL(string: "about:blank")!
    private func serverDown(_ webView: WKWebView) {
        if isPreview { return showOfflineCopy(in: webView) }
        if webView.url != Self.blankURL { webView.load(URLRequest(url: Self.blankURL)) }
        waitForServer()
    }

    /// A warm page from before the app was quit would keep showing its last state: check the server is there.
    private func checkServer() {
        URLSession.shared.dataTask(with: Self.statusURL) { [weak self] _, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode != 200 else { return }
            DispatchQueue.main.async {
                guard let self, let webView = self.webView else { return }
                log.notice("server not running, showing nothing")
                self.serverDown(webView)
            }
        }.resume()
    }

    private func showOfflineCopy(in webView: WKWebView) {
        guard webView.url?.isFileURL != true,
              let page = Bundle(for: Self.self).url(forResource: "index", withExtension: "html") else { return }
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        waitForServer()
    }

    /// On a locked Mac, input makes macOS draw its lock screen (its own clock, the user picture and
    /// the password field) on top of the still-running screensaver, then hide it once there has been
    /// no input for 30 seconds (loginwindow logs "set idleTime to 30.000000"; measured, it hides
    /// about 29.4 s after the last input). There's no public signal for that overlay, so this mirrors
    /// the same rule from the time since the last input, and tells the page so it can hide its own
    /// clock while macOS shows one. The page's own animation leaves room for macOS's fade.
    private static let lockUITimeout: TimeInterval = 29.4
    /// Timing, measured from loginwindow's logs: macOS never raised its lock UI sooner than 0.8 s after
    /// the screensaver started, so input in that first moment (the hot corner or shortcut that started it,
    /// trackpad momentum, letting go of keys) doesn't count. Comparing these logs with loginwindow's
    /// ("lock UI is showing") on 2026-10-16: 94 of 173 Unlock switches had no lock UI behind them, nearly
    /// all within 0.7 s of a start or from views that were never started.
    private static let startGrace: TimeInterval = 0.8
    /// Only the screensaver view that started last on the sign-in display follows the lock UI.
    private static weak var activeView: ClaudeLockscreenView?
    private var lockUITimer: Timer?
    private var watchActivity: NSObjectProtocol?
    private var createdAt = Date.distantPast
    private var systemLockUI = false
    /// macOS draws its sign-in (picture, name, password field) and its big clock on the main display only, the one with
    /// the menu bar (Dan checked both on a locked Mac with an external monitor, 2026-10-19).
    /// With two displays both screensavers start together, and the one that started last used to follow the lock UI
    /// wherever it was: on 2026-10-19 the laptop's crab crawled under a field macOS showed only on the external monitor.
    private var onSignInDisplay: Bool {
        guard let screen = window?.screen, let main = NSScreen.screens.first else { return true } // not known yet: as before
        return screen.displayID == main.displayID
    }
    private func startLockUIWatch() {
        guard !isPreview else { return }
        createdAt = Date() // when this screensaver started showing
        setSystemLockUI(false, force: true)
        guard onSignInDisplay else { return log.notice("not the sign-in display: not following the lock UI") }
        Self.activeView = self
        guard lockUITimer == nil else { return }
        // While loginwindow covers this process, macOS coalesces its timers and naps it; this keeps
        // the 0.1 s checks on time so the page reacts together with macOS.
        watchActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Follow the lock screen overlay")
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkLockUI() }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common) // keeps ticking while the run loop is in other modes
        lockUITimer = timer
    }
    private func stopLockUIWatch() {
        lockUITimer?.invalidate()
        lockUITimer = nil
        if let activity = watchActivity { ProcessInfo.processInfo.endActivity(activity) }
        watchActivity = nil
        createdAt = .distantPast
        if Self.activeView === self {
            Self.activeView = nil
            setSystemLockUI(false, force: true) // the cached page starts clean next time
        }
    }
    private func checkLockUI() {
        // A newer screensaver took over, this one left the screen, or the displays changed and it's no longer on the sign-in one.
        guard Self.activeView === self, window != nil, onSignInDisplay else { return stopLockUIWatch() }
        // Hardware input only (.hidSystemState): macOS raises its lock UI for a real keyboard, mouse or trackpad,
        // not for events other apps post (keep-awake mouse jiggles, automation, remote control), which the
        // session-wide state counts too and which made the crab sneak under a password field that wasn't there.
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        let lastInput = Date().addingTimeInterval(-idle)
        let showing = lastInput > createdAt.addingTimeInterval(Self.startGrace) && idle < Self.lockUITimeout
        setSystemLockUI(showing)
    }
    private func setSystemLockUI(_ on: Bool, force: Bool = false) {
        guard force || on != systemLockUI else { return }
        systemLockUI = on
        log.notice("macOS lock UI \(on ? "showing" : "hidden", privacy: .public)")
        webView?.evaluateJavaScript("window.setSystemLockUI && window.setSystemLockUI(\(on))")
    }

    private func waitForServer() {
        probeTimer?.invalidate()
        probeTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            URLSession.shared.dataTask(with: Self.statusURL) { _, response, _ in
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                DispatchQueue.main.async {
                    timer.invalidate()
                    self?.webView?.load(URLRequest(url: Self.liveURL))
                }
            }.resume()
        }
    }
}

private extension NSScreen {
    var displayID: UInt32 { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
}
