// Agent Aquarium.app: the settings window around the page served by the built-in server, plus setup.
// On every launch it makes sure the pieces bundled inside the app are in place:
//   • the status server (Contents/MacOS/aquarium-node), started at login by a launch agent in ~/Library/LaunchAgents,
//   • the screensaver (Contents/Library/Screen Savers), copied into ~/Library/Screen Savers,
//   • the Claude Code hooks in ~/.claude/settings.json, added only after the user agrees,
//   • and, also only after the user agrees, a status line wrapper that saves Claude's plan usage
//     (it runs the user's own status line, so that one keeps working).
// It also moves an older script install (install.sh, ~/.claude/lockscreen) over to the app.
import Cocoa
import ServiceManagement
import WebKit

private let settingsURL = URL(string: "http://127.0.0.1:4777/settings")!
private let displayURL = URL(string: "http://127.0.0.1:4777/?display=1")!
/// The preview also gets your name, for the macOS sign-in it draws over the scene when you point at it.
private var previewURL: URL {
    var c = URLComponents(string: "http://127.0.0.1:4777/")!
    c.queryItems = [URLQueryItem(name: "preview", value: "1"), URLQueryItem(name: "user", value: NSFullUserName())]
    return c.url!
}
private let serverLabel = "com.danamsalem.agentaquarium.server"
private let saverName = "Agent Aquarium.saver"
private let hookMode = "agent-aquarium-hook"
private let statusLineMode = "agent-aquarium-statusline"

private let fm = FileManager.default
private let home = fm.homeDirectoryForCurrentUser
private let dataDir = home.appendingPathComponent(".claude/agent-aquarium")
private let claudeSettings = home.appendingPathComponent(".claude/settings.json")
private let userSavers = home.appendingPathComponent("Library/Screen Savers")

/// What older installs left behind, newest first: this app while it was called Agent Fishtank
/// (2026-10-16), and the script install (install.sh, before the app existed).
private struct OldInstall {
    let dataDir: URL, label: String, saver: URL, hookMarker: String
    var plist: URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
}
private let oldInstalls = [
    OldInstall(dataDir: home.appendingPathComponent(".claude/agent-fishtank"), label: "com.danamsalem.agentfishtank.server",
               saver: userSavers.appendingPathComponent("Agent Fishtank.saver"), hookMarker: "agent-fishtank-hook"),
    OldInstall(dataDir: home.appendingPathComponent(".claude/lockscreen"), label: "com.claude.lockscreen",
               saver: userSavers.appendingPathComponent("ClaudeLockscreen.saver"), hookMarker: "lockscreen/app/hook.js"),
]
private enum Legacy {
    static let fishtankApp = URL(fileURLWithPath: "/Applications/Agent Fishtank.app")
    static let fishtankBundleID = "com.danamsalem.agentfishtank"
    static let scriptDataDir = home.appendingPathComponent(".claude/lockscreen")
    static let desktopApps = ["Agent Fishtank.app", "Claude Lockscreen.app", "Claude Lockscreen Theme.app"]
}

private enum Pref {
    static let hooksDeclined = "hooksDeclined"
    static let usageDeclined = "usageDeclined"
    static let usageAsked = "usageAsked"
    static let saverPrompted = "saverPrompted"
    static let serverBuild = "serverBuild"
    static let desktopChecked = "legacyDesktopChecked"
    static let alwaysOnDisplay = "alwaysOnDisplay" // the CGDirectDisplayID of the screen it runs on, 0 when off
}

private extension NSScreen {
    var displayID: UInt32 { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
}

/// Always-on mode: the lock screen scene, full screen on a display you pick (typically an external one), shown all the
/// time rather than only as the screensaver. It covers that display's menu bar and stays put across Spaces; Esc closes it.
/// It doesn't keep the display awake, so the screensaver and locking still work as usual.
private final class AlwaysOnWindow: NSWindow, WKNavigationDelegate {
    private let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    private var retry: Timer?
    var onClose: (() -> Void)?

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        backgroundColor = .black
        webView.frame = contentView!.bounds
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        contentView!.addSubview(webView)
        place(on: screen)
        webView.load(URLRequest(url: displayURL))
    }

    override var canBecomeKey: Bool { true } // so Esc reaches it
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) } // 53: Esc
    }
    func place(on screen: NSScreen) { setFrame(screen.frame, display: true) }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        retry?.invalidate() // the server isn't up yet: try again shortly
        retry = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.webView.load(URLRequest(url: displayURL)) }
    }
    func stop() { retry?.invalidate(); webView.stopLoading(); orderOut(nil); close() }
}

/// "Preview lock screen" in settings: the scene in an ordinary window instead of the real screensaver. The page is laid
/// out at the size of the screen and the view is scaled down to the window (not page zoom, which measures text slightly
/// differently and can change what fits), so it looks like the real thing. Esc closes it.
private final class PreviewWindow: NSWindow, NSWindowDelegate {
    private let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    private let stage = NSView() // window-sized frame, screen-sized bounds: AppKit scales the page view inside it
    private let screenSize: NSSize
    var onClose: (() -> Void)?

    init(screen: NSScreen) {
        screenSize = screen.frame.size
        let width = (screen.visibleFrame.width * 0.75).rounded()
        let size = NSSize(width: width, height: (width * screenSize.height / screenSize.width).rounded())
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        title = "Lock Screen Preview"
        isReleasedWhenClosed = false
        contentAspectRatio = screenSize
        minSize = NSSize(width: 480, height: 300)
        backgroundColor = .black
        delegate = self
        stage.frame = contentView!.bounds
        stage.autoresizingMask = [.width, .height]
        contentView!.addSubview(stage)
        webView.frame = NSRect(origin: .zero, size: screenSize)
        stage.addSubview(webView)
        fit()
        center()
        webView.load(URLRequest(url: previewURL))
    }

    private func fit() { stage.bounds = NSRect(origin: .zero, size: screenSize) }
    func windowDidResize(_ notification: Notification) { fit() }
    override func cancelOperation(_ sender: Any?) { close() } // Esc
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) } // 53: Esc
    }
    func windowWillClose(_ notification: Notification) {
        webView.stopLoading(); webView.removeFromSuperview() // stop the page's timers and animation
        onClose?()
    }
}

/// The menu bar item: the agents' state at a glance (the fish fills in while one works, "!" when one needs you) and
/// quick actions: keep the Mac awake, the away message, the theme, start the screensaver, open settings.
/// It reads the same /status the lock screen does, every few seconds.
private final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?
    private var status: [String: Any] = [:]
    private var lastState = ""
    private var state = "idle"
    var openSettings: () -> Void = {}
    var openPreview: () -> Void = {}
    /// The Always-On Display submenu, filled by the app delegate (it lists the displays connected right now).
    var displayMenu: NSMenu?

    override init() {
        super.init()
        item.button?.imagePosition = .imageLeft
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        show(state: "idle", waiting: 0)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 1
    }

    private var config: [String: Any] { status["config"] as? [String: Any] ?? [:] }
    private var sessions: [[String: Any]] { status["sessions"] as? [[String: Any]] ?? [] }
    private var awake: [String: Any] { status["awake"] as? [String: Any] ?? [:] }

    private func refresh() {
        URLSession.shared.dataTask(with: URLRequest(url: URL(string: "http://127.0.0.1:4777/status")!, timeoutInterval: 2)) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { self.update(json ?? [:]) }
        }.resume()
    }

    private func update(_ json: [String: Any]) {
        status = json
        let live = liveSessions()
        let waiting = live.filter { $0.state == "waiting" }.count
        let state = waiting > 0 ? "waiting" : live.contains { $0.working && $0.active } ? "working"
            : live.contains { $0.working } ? "working" : live.contains { $0.state == "done" } ? "done" : "idle"
        show(state: state, waiting: waiting)
    }

    private func show(state: String, waiting: Int) {
        self.state = state
        let key = "\(state)\(waiting)"
        guard key != lastState, let button = item.button else { return }
        lastState = key
        let image = NSImage(systemSymbolName: state == "idle" || state == "done" ? "fish" : "fish.fill", accessibilityDescription: "Agent Aquarium")
        image?.isTemplate = true
        button.image = image
        button.title = waiting > 0 ? " !" : ""
        button.toolTip = "Agent Aquarium: " + headline(state)
    }

    // The lock screen's rules (index.html, derive): idle sessions aren't shown, finished ones for 10 minutes, the rest for
    // 45 minutes; a working one that hasn't reported for 5 min (thinking) or 20 min (inside a tool) has probably stalled.
    private struct Live { let project: String, action: String, state: String, updated: Double, working: Bool, active: Bool }
    private func liveSessions() -> [Live] {
        let now = (status["now"] as? Double) ?? Date().timeIntervalSince1970 * 1000
        return sessions.compactMap { s -> Live? in
            let state = s["state"] as? String ?? "idle", updated = s["updated_at"] as? Double ?? 0
            let doneAt = s["done_at"] as? Double ?? updated
            if state == "idle" { return nil }
            if state == "done" ? now - doneAt >= 10 * 60e3 : now - updated >= 45 * 60e3 { return nil }
            let working = state == "working" || state == "thinking"
            return Live(project: s["project"] as? String ?? "claude", action: s["action"] as? String ?? "", state: state,
                        updated: updated, working: working, active: now - updated <= (state == "thinking" ? 5 : 20) * 60e3)
        }.sorted { a, b in
            let rank = { (l: Live) -> Double in l.state == "waiting" ? 0 : l.working ? (l.active ? 1 : 2.5) : 2 }
            return rank(a) != rank(b) ? rank(a) < rank(b) : a.updated > b.updated
        }
    }

    private func headline(_ state: String) -> String {
        switch state {
        case "working": return "claude is working"
        case "waiting": return "claude needs you"
        case "done": return "claude is done"
        default: return "no agents running"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.forEach { $0.submenu = nil } // a submenu belongs to one item at a time: free the shared one
        menu.removeAllItems()
        let offline = status.isEmpty
        // A newer version on the website (the server checks about once a day): opens the download page.
        if let update = status["update"] as? [String: Any], let version = update["version"] as? String,
           let url = (update["url"] as? String).flatMap(URL.init(string:)), url.scheme == "https" {
            let item = add(menu, "Update Available: Agent Aquarium \(version)…", #selector(openUpdate(_:)))
            item.representedObject = url
            menu.addItem(.separator())
        }
        let live = liveSessions()
        let line = headline(state)
        let head = menu.addItem(withTitle: offline ? "The lock screen server isn't running" : line.prefix(1).uppercased() + line.dropFirst(), action: nil, keyEquivalent: "")
        head.isEnabled = false
        for s in live.prefix(6) {
            let dot = s.state == "waiting" ? "⚠︎" : s.working ? "●" : "✓"
            let text = s.action.isEmpty ? s.project : "\(s.project): \(s.action)"
            menu.addItem(withTitle: "\(dot)  \(text.count > 60 ? String(text.prefix(59)) + "…" : text)", action: nil, keyEquivalent: "").isEnabled = false
        }
        menu.addItem(.separator())

        let keepAwake = add(menu, "Keep Mac Awake While Agents Work", #selector(toggleAwake))
        keepAwake.state = awake["on"] as? Bool == true ? .on : .off
        keepAwake.isEnabled = !offline
        if awake["on"] as? Bool == true, awake["holding"] as? Bool == true {
            let n = awake["working"] as? Int ?? 0
            menu.addItem(withTitle: "Keeping your Mac awake: \(n == 1 ? "1 agent" : "\(n) agents") working", action: nil, keyEquivalent: "").isEnabled = false
        }

        let message = (config["customText"] as? String) ?? ""
        let messageMenu = NSMenu()
        for preset in (config["presets"] as? [String] ?? []).prefix(12) {
            let p = add(messageMenu, preset, #selector(pickMessage(_:)))
            p.representedObject = preset
            p.state = preset == message ? .on : .off
        }
        if messageMenu.numberOfItems > 0 { messageMenu.addItem(.separator()) }
        add(messageMenu, "Type a Message…", #selector(typeMessage))
        add(messageMenu, "Clear Message", #selector(clearMessage)).isEnabled = !message.isEmpty
        let messageItem = menu.addItem(withTitle: message.isEmpty ? "Away Message" : "Away Message: \(message.count > 30 ? String(message.prefix(29)) + "…" : message)", action: nil, keyEquivalent: "")
        messageItem.submenu = messageMenu
        messageItem.isEnabled = !offline

        let themeMenu = NSMenu()
        for id in config["themes"] as? [String] ?? [] {
            let t = add(themeMenu, id == "pixel" ? "Retro pixel" : id.prefix(1).uppercased() + id.dropFirst(), #selector(pickTheme(_:)))
            t.representedObject = id
            t.state = id == config["theme"] as? String ? .on : .off
        }
        let themeItem = menu.addItem(withTitle: "Theme", action: nil, keyEquivalent: "")
        themeItem.submenu = themeMenu
        themeItem.isEnabled = !offline
        if let displays = displayMenu {
            menu.addItem(withTitle: "Always-On Display", action: nil, keyEquivalent: "").submenu = displays
        }

        menu.addItem(.separator())
        add(menu, "Start Screen Saver", #selector(startScreenSaver))
        add(menu, "Preview Lock Screen", #selector(preview))
        add(menu, "Open Settings…", #selector(settings))
        menu.addItem(.separator())
        add(menu, "Open at Login", #selector(toggleLogin)).state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Quit Agent Aquarium", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let i = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func post(_ patch: [String: Any]) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:4777/config")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: patch)
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in DispatchQueue.main.async { self?.refresh() } }.resume()
    }

    @objc private func openUpdate(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) } }
    @objc private func toggleAwake() { post(["keepAwake": !(awake["on"] as? Bool == true)]) }
    @objc private func pickMessage(_ sender: NSMenuItem) { post(["customText": sender.representedObject as? String ?? ""]) }
    @objc private func clearMessage() { post(["customText": ""]) }
    @objc private func pickTheme(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { post(["theme": id]) } }
    @objc private func preview() { openPreview() }
    @objc private func settings() { openSettings() }

    @objc private func typeMessage() {
        let alert = NSAlert()
        alert.messageText = "Away message"
        alert.informativeText = "Shows on your lock screen until you clear it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Back in 10 min"
        field.stringValue = config["customText"] as? String ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Show")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        post(["customText": String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140))])
    }

    @objc private func startScreenSaver() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems(); return }
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

@discardableResult
private func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

private var buildNumber: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
private var nodeBinary: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/aquarium-node") }

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler, NSMenuDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var retryTimer: Timer?
    private var hooksItem: NSMenuItem!
    private var usageItem: NSMenuItem!
    private var displayMenu: NSMenu!
    private var fishDisplayMenu: NSMenu! // the same list, in the menu bar fish's menu
    private var alwaysOn: AlwaysOnWindow?
    private var preview: PreviewWindow?
    private var statusMenu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        if Bundle.main.bundlePath.contains("/AppTranslocation/") { return askToMoveToApplications() }

        // Opened at login (Open at Login in the menu bar item): set up quietly and wait in the menu bar.
        let atLogin = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem

        migrateLegacyInstall()
        installScreenSaver()
        startServer()
        makeWindow()
        statusMenu = StatusMenu()
        statusMenu?.openSettings = { [weak self] in self?.openSettings() }
        statusMenu?.openPreview = { [weak self] in self?.showPreview() }
        fishDisplayMenu = NSMenu(title: "Always-On Display")
        fishDisplayMenu.delegate = self
        statusMenu?.displayMenu = fishDisplayMenu
        if atLogin { NSApp.setActivationPolicy(.accessory) } else { openSettings() }
        updateAlwaysOn()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateAlwaysOn() // a display was plugged in, unplugged or rearranged
        }
    }

    // Keeps running in the menu bar after its windows close (Quit is in the menu bar item); without a window it also
    // leaves the Dock. Opening it again (Finder, Spotlight, the menu bar item) brings the settings window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Quitting turns Agent Aquarium off: the server stops (and won't start at login), so the screensaver shows
    // nothing until the app is opened again. Logging out, restarting or shutting down quits apps too; those
    // leave it on, so it's back after a restart.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reason = NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        let sessionEnding: Set<OSType> = [OSType(kAELogOut), OSType(kAEReallyLogOut), OSType(kAEShowRestartDialog),
                                          OSType(kAEShowShutdownDialog), OSType(kAERestart), OSType(kAEShutDown)]
        if serverStarted, !sessionEnding.contains(reason ?? 0) { stopServer() }
        return .terminateNow
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !window.isVisible { openSettings() }
        return true
    }

    // MARK: Always-on display

    private var alwaysOnID: UInt32 {
        get { UInt32(UserDefaults.standard.integer(forKey: Pref.alwaysOnDisplay)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: Pref.alwaysOnDisplay) }
    }

    /// Opens, moves or closes the always-on window to match the saved choice and the displays connected now.
    /// The choice is kept while its display is unplugged, so it comes back when the display does.
    private func updateAlwaysOn() {
        guard alwaysOnID != 0, let screen = NSScreen.screens.first(where: { $0.displayID == alwaysOnID }) else {
            alwaysOn?.stop(); alwaysOn = nil
            sendDisplays()
            return
        }
        defer { sendDisplays() }
        if let w = alwaysOn { w.place(on: screen); return }
        let w = AlwaysOnWindow(screen: screen)
        w.onClose = { [weak self] in self?.setAlwaysOn(0) }
        w.orderFrontRegardless()
        alwaysOn = w
    }

    /// Tells the settings page which displays are connected and which one shows the scene, for its picker.
    private func sendDisplays() {
        let displays = NSScreen.screens.map { screen -> [String: Any] in
            ["id": Int(screen.displayID), "name": screen.localizedName + (screen == NSScreen.screens.first ? " (main display)" : "")]
        }
        let state: [String: Any] = ["displays": displays, "current": alwaysOn != nil ? Int(alwaysOnID) : 0]
        guard let data = try? JSONSerialization.data(withJSONObject: state), let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.setDisplays && window.setDisplays(\(json))")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { sendDisplays() }

    private func setAlwaysOn(_ id: UInt32) {
        alwaysOnID = id
        alwaysOn?.stop(); alwaysOn = nil // reopened fresh, so it fits the new display
        updateAlwaysOn()
    }

    @objc private func pickAlwaysOnDisplay(_ sender: NSMenuItem) {
        let id = UInt32(sender.tag)
        setAlwaysOn(id == alwaysOnID ? 0 : id)
    }

    // The Always-On Display submenu lists the displays connected right now.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === displayMenu || menu === fishDisplayMenu else { return }
        menu.removeAllItems()
        let off = menu.addItem(withTitle: "Off", action: #selector(pickAlwaysOnDisplay(_:)), keyEquivalent: "")
        off.target = self; off.tag = 0; off.state = alwaysOn == nil ? .on : .off
        menu.addItem(.separator())
        for screen in NSScreen.screens {
            let main = screen == NSScreen.screens.first ? " (main display)" : ""
            let item = menu.addItem(withTitle: screen.localizedName + main, action: #selector(pickAlwaysOnDisplay(_:)), keyEquivalent: "")
            item.target = self; item.tag = Int(screen.displayID); item.state = alwaysOn != nil && screen.displayID == alwaysOnID ? .on : .off
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Shows the scene full screen all the time. Press Esc on it to close.", action: nil, keyEquivalent: "").isEnabled = false
    }

    // MARK: Settings window

    private func makeWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Agent Aquarium"
        window.isReleasedWhenClosed = false // reopened from the menu bar item or the Dock
        window.delegate = self
        window.minSize = NSSize(width: 680, height: 520)
        window.setFrameAutosaveName("ClaudeLockscreenSettings")
        if window.frameAutosaveName.isEmpty || !window.setFrameUsingName("ClaudeLockscreenSettings") { window.center() }

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "preview") // the page's Preview lock screen button
        config.userContentController.add(self, name: "alwaysOn") // the page's Always-on display picker
        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        window.contentView!.addSubview(webView)
        webView.load(URLRequest(url: settingsURL))
    }

    private var asked = false
    private func openSettings() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard !asked else { return }
        asked = true
        // Questions come after the window is up, as sheets on it.
        DispatchQueue.main.async {
            self.checkHooks()
            self.promptForScreenSaverOnce()
            if !self.isServerLoaded() { self.askForLoginItemApproval() }
        }
    }

    /// With no window left, the app leaves the Dock and stays in the menu bar.
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { if !self.window.isVisible && self.preview == nil { NSApp.setActivationPolicy(.accessory) } }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "preview" { showPreview() }
        if message.name == "alwaysOn", let id = message.body as? NSNumber { setAlwaysOn(id.uint32Value) }
    }

    private func showPreview() {
        if let p = preview { p.makeKeyAndOrderFront(nil); return }
        let p = PreviewWindow(screen: window.screen ?? NSScreen.main ?? NSScreen.screens[0])
        p.onClose = { [weak self] in
            self?.preview = nil
            DispatchQueue.main.async { if self?.window.isVisible == false { NSApp.setActivationPolicy(.accessory) } }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        preview = p
        p.makeKeyAndOrderFront(nil)
    }

    // Server not up yet (e.g. right after login or first launch): show a short note and keep retrying.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        webView.loadHTMLString("""
            <body style="font:15px -apple-system;color:#888;display:grid;place-items:center;height:90vh;text-align:center">
            <div><b style="color:#d97757">Connecting to the lock screen server…</b><br>
            If this doesn't go away, quit and reopen Agent Aquarium.</div></body>
            """, baseURL: nil)
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.webView.load(URLRequest(url: settingsURL))
        }
    }

    // MARK: Server

    /// The server runs from a launch agent in ~/Library/LaunchAgents that points into this app. (SMAppService would be
    /// tidier, but it pins an ad hoc signed binary to its exact build, so after an update launchd refuses to start it.
    /// Worth revisiting once the app is Developer ID signed, where the pin is the team instead.)
    private var agentPlist: URL { home.appendingPathComponent("Library/LaunchAgents/\(serverLabel).plist") }
    private var agentTarget: String { "gui/\(getuid())/\(serverLabel)" }

    private func agentPlistData() -> Data {
        let plist: [String: Any] = [
            "Label": serverLabel,
            "ProgramArguments": [nodeBinary.path, "serve"],
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? "com.danamsalem.agentaquarium"],
            "RunAtLoad": true,
            "KeepAlive": true,
        ]
        return try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Set once this copy of the app has started the server, so quitting a copy that never did (one macOS opened
    /// from Downloads) doesn't stop the installed one's.
    private var serverStarted = false

    private func startServer() {
        serverStarted = true
        let defaults = UserDefaults.standard
        let wanted = agentPlistData()
        let loaded = isServerLoaded()
        let current = (try? Data(contentsOf: agentPlist)) == wanted
        if !loaded || !current || defaults.string(forKey: Pref.serverBuild) != buildNumber {
            // New install, moved app, or new build: (re)load the agent so it runs this copy's server.
            if loaded {
                run("/bin/launchctl", ["bootout", agentTarget])
                for _ in 0..<30 where isServerLoaded() { usleep(100_000) } // bootout finishes asynchronously
            }
            try? fm.createDirectory(at: agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? wanted.write(to: agentPlist)
            var result = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", agentPlist.path])
            for _ in 0..<5 where result.status != 0 && !isServerLoaded() {
                usleep(300_000)
                result = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", agentPlist.path])
            }
            if !isServerLoaded() { NSLog("Agent Aquarium: server bootstrap failed: \(result.output)") }
        } else {
            // Opening the app always restarts the server, so it serves what's installed now.
            run("/bin/launchctl", ["kickstart", "-k", agentTarget])
        }
        defaults.set(buildNumber, forKey: Pref.serverBuild)
        // If the user switched Agent Aquarium off under Login Items, macOS won't load the agent: openSettings asks.
    }

    private func isServerLoaded() -> Bool { run("/bin/launchctl", ["print", agentTarget]).status == 0 }

    private func stopServer() {
        run("/bin/launchctl", ["bootout", agentTarget])
        try? fm.removeItem(at: agentPlist)
        try? SMAppService.agent(plistName: "\(serverLabel).plist").unregister()
    }

    private func askForLoginItemApproval() {
        let alert = NSAlert()
        alert.messageText = "Allow Agent Aquarium in the background"
        alert.informativeText = "The lock screen needs a small server that runs while you're logged in. Turn on Agent Aquarium under Login Items & Extensions → Allow in the Background."
        alert.addButton(withTitle: "Open Login Items")
        alert.addButton(withTitle: "Later")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { SMAppService.openSystemSettingsLoginItems() }
        }
    }

    // MARK: Screensaver

    private var bundledSaver: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Screen Savers/\(saverName)") }
    private var installedSaver: URL { userSavers.appendingPathComponent(saverName) }

    private func installScreenSaver() {
        let version = { (url: URL) in Bundle(url: url).flatMap { NSDictionary(contentsOf: $0.bundleURL.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String } }
        guard fm.fileExists(atPath: bundledSaver.path),
              version(installedSaver) != version(bundledSaver) || !fm.fileExists(atPath: installedSaver.path) else { return }
        do {
            try fm.createDirectory(at: userSavers, withIntermediateDirectories: true)
            if fm.fileExists(atPath: installedSaver.path) { try fm.removeItem(at: installedSaver) }
            try fm.copyItem(at: bundledSaver, to: installedSaver)
            run("/usr/bin/killall", ["legacyScreenSaver"]) // drop any copy of the old build macOS kept loaded
        } catch {
            NSLog("Agent Aquarium: screensaver install failed: \(error)")
        }
    }

    private func promptForScreenSaverOnce() {
        guard !UserDefaults.standard.bool(forKey: Pref.saverPrompted), window.attachedSheet == nil else { return }
        UserDefaults.standard.set(true, forKey: Pref.saverPrompted)
        let alert = NSAlert()
        alert.messageText = "Choose Agent Aquarium as your screen saver"
        alert.informativeText = "macOS doesn't let apps do this step: in Screen Saver settings, pick “Agent Aquarium” (under Other).\n\nTo keep your Mac locked while it shows, set Lock Screen → “Require password after screen saver begins” to Immediately."
        alert.addButton(withTitle: "Open Screen Saver Settings")
        alert.addButton(withTitle: "Later")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { self.openScreenSaverSettings() }
        }
    }

    @objc private func openScreenSaverSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension")!)
    }

    // MARK: Claude Code hooks

    private enum HookState { case none, legacy, moved, current }

    private func hookState() -> HookState {
        guard let data = try? Data(contentsOf: claudeSettings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else { return .none }
        var commands: [String] = []
        for case let groups as [[String: Any]] in hooks.values {
            for group in groups {
                for case let hook as [String: Any] in group["hooks"] as? [Any] ?? [] {
                    if let c = hook["command"] as? String { commands.append(c) }
                }
            }
        }
        if commands.contains(where: { $0.contains("\"\(nodeBinary.path)\" \"\(hookMode)\"") }) { return .current }
        if commands.contains(where: { $0.contains(hookMode) }) { return .moved }
        if commands.contains(where: { c in oldInstalls.contains { c.contains($0.hookMarker) } }) { return .legacy }
        return .none
    }

    private enum UsageState { case none, moved, current }

    /// Whether Claude Code's status line is our wrapper (which saves the plan usage), and from this copy of the app.
    private func usageState() -> UsageState {
        guard let data = try? Data(contentsOf: claudeSettings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = (json["statusLine"] as? [String: Any])?["command"] as? String else { return .none }
        if command.contains("\"\(nodeBinary.path)\" \"\(statusLineMode)\"") { return .current }
        return command.contains(statusLineMode) ? .moved : .none
    }

    @discardableResult
    private func setHooks(_ on: Bool) -> Bool {
        let usage = UserDefaults.standard.bool(forKey: Pref.usageDeclined) ? ["--no-usage"] : []
        let args = on ? ["setup-hooks", nodeBinary.path, hookMode] + usage : ["setup-hooks", "--uninstall"]
        let result = run(nodeBinary.path, args)
        if result.status != 0 {
            let alert = NSAlert()
            alert.messageText = on ? "Couldn't add the Claude Code hooks" : "Couldn't remove the Claude Code hooks"
            alert.informativeText = result.output
            alert.runModal()
        }
        updateHooksMenu()
        return result.status == 0
    }

    private func checkHooks() {
        switch hookState() {
        case .current:
            if usageState() == .moved { setHooks(true) } // the app was moved; point the status line at its new place
            else if usageState() == .none, !UserDefaults.standard.bool(forKey: Pref.usageAsked) { askToShowUsage() }
        case .moved: setHooks(true) // the app was moved; point the hooks at its new place
        case .legacy: askToConnectClaudeCode(fromScript: true)
        case .none: if !UserDefaults.standard.bool(forKey: Pref.hooksDeclined) { askToConnectClaudeCode(fromScript: false) }
        }
        updateHooksMenu()
    }

    private func askToConnectClaudeCode(fromScript: Bool) {
        let alert = NSAlert()
        alert.messageText = fromScript ? "Move your Claude Code hooks to the app?" : "Connect Claude Code?"
        alert.informativeText = (fromScript
            ? "Your Claude Code hooks still point at an older install (Agent Fishtank or the script install). Agent Aquarium can switch them to the hook built into this app.\n\n"
            : "To show what your sessions are doing, Agent Aquarium adds a hook to Claude Code's settings (~/.claude/settings.json). ")
            + "On events such as a prompt, a tool call or a finished turn, the hook saves that session's state in ~/.claude/agent-aquarium on this Mac. "
            + "To show your Claude plan usage, it also sets a status line command that saves those numbers and then runs your own status line, so yours looks the same. "
            + "Nothing is sent anywhere. Your settings file is backed up first (settings.json.bak-lockscreen).\n\nRestart running Claude Code sessions afterwards. You can remove all of it any time from the Agent Aquarium menu."
        alert.addButton(withTitle: fromScript ? "Switch Hooks" : "Connect Claude Code")
        alert.addButton(withTitle: "Not Now")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                UserDefaults.standard.set(false, forKey: Pref.hooksDeclined)
                UserDefaults.standard.set(true, forKey: Pref.usageAsked)
                self.setHooks(true)
            } else {
                UserDefaults.standard.set(true, forKey: Pref.hooksDeclined)
            }
            self.promptForScreenSaverOnce()
        }
    }

    @objc private func toggleHooks() {
        let on = hookState() == .current
        if on {
            let alert = NSAlert()
            alert.messageText = "Disconnect Claude Code?"
            alert.informativeText = "This removes Agent Aquarium's hooks from ~/.claude/settings.json and puts your own status line back. The lock screen will stop showing your sessions."
            alert.addButton(withTitle: "Disconnect")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if setHooks(false) { UserDefaults.standard.set(true, forKey: Pref.hooksDeclined) }
        } else {
            askToConnectClaudeCode(fromScript: hookState() == .legacy)
        }
    }

    private func updateHooksMenu() {
        hooksItem?.title = hookState() == .current ? "Disconnect Claude Code…" : "Connect Claude Code…"
        usageItem?.state = hookState() == .current && usageState() == .current ? .on : .off
    }

    // MARK: Plan usage (the status line wrapper)

    /// For people who connected Claude Code before plan usage existed: asked once.
    private func askToShowUsage() {
        UserDefaults.standard.set(true, forKey: Pref.usageAsked)
        let alert = NSAlert()
        alert.messageText = "Show your Claude plan usage on the lock screen?"
        alert.informativeText = "Agent Aquarium can show how much of your 5-hour and weekly limits you've used (updated when you use claude in a terminal). "
            + "Claude Code only shares those numbers with its status line, so Agent Aquarium sets a status line command in ~/.claude/settings.json that saves them on this Mac and then runs your own status line, so yours looks the same. Nothing is sent anywhere.\n\n"
            + "Restart running Claude Code sessions afterwards. You can turn it off any time from the Agent Aquarium menu."
        alert.addButton(withTitle: "Show Plan Usage")
        alert.addButton(withTitle: "Not Now")
        alert.beginSheetModal(for: window) { response in
            UserDefaults.standard.set(response != .alertFirstButtonReturn, forKey: Pref.usageDeclined)
            if response == .alertFirstButtonReturn { self.setHooks(true); self.setShowUsage(true) }
        }
    }

    /// The lock screen's "Show plan usage" setting (off by default): turned on when you say yes here, off when you
    /// turn plan usage off from the menu.
    private func setShowUsage(_ on: Bool) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:4777/config")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = Data("{\"showUsage\":\(on)}".utf8)
        URLSession.shared.dataTask(with: req).resume()
    }

    @objc private func toggleUsage() {
        guard hookState() == .current else { return askToConnectClaudeCode(fromScript: hookState() == .legacy) }
        if usageState() == .current {
            UserDefaults.standard.set(true, forKey: Pref.usageDeclined)
            setHooks(true) // with --no-usage: puts the user's own status line back
            setShowUsage(false)
        } else {
            askToShowUsage()
        }
    }

    // MARK: Moving from older installs

    /// Moves older installs (see `oldInstalls`) over to this app: stops their server, moves the settings,
    /// presets, Google sign-in and sessions into the app's folder, and removes their screensaver (and the
    /// Agent Fishtank app, or the script install's Desktop app). Each old folder keeps a `sessions` link to
    /// the new one, so Claude Code sessions started before the move that still run an old hook keep showing
    /// up, as long as that hook still exists (the script install's hook.js does; the Agent Fishtank app's
    /// goes to the Trash with it, so restart those sessions).
    private func migrateLegacyInstall() {
        let newSessions = dataDir.appendingPathComponent("sessions")
        for old in oldInstalls {
            if fm.fileExists(atPath: old.plist.path) {
                run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(old.label)"])
                try? fm.removeItem(at: old.plist)
            }
            if fm.fileExists(atPath: old.saver.path) {
                try? fm.trashItem(at: old.saver, resultingItemURL: nil)
                run("/usr/bin/killall", ["legacyScreenSaver"])
            }
            guard fm.fileExists(atPath: old.dataDir.path) else { continue }
            try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for name in ["config.json", "google.json"] {
                let from = old.dataDir.appendingPathComponent(name), to = dataDir.appendingPathComponent(name)
                if fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) { try? fm.moveItem(at: from, to: to) }
            }
            let oldSessions = old.dataDir.appendingPathComponent("sessions")
            if (try? fm.destinationOfSymbolicLink(atPath: oldSessions.path)) == nil, fm.fileExists(atPath: oldSessions.path) {
                try? fm.createDirectory(at: newSessions, withIntermediateDirectories: true)
                for name in (try? fm.contentsOfDirectory(atPath: oldSessions.path)) ?? [] {
                    try? fm.moveItem(at: oldSessions.appendingPathComponent(name), to: newSessions.appendingPathComponent(name))
                }
                if (try? fm.removeItem(at: oldSessions)) != nil {
                    try? fm.createSymbolicLink(at: oldSessions, withDestinationURL: newSessions)
                }
            }
        }

        if Legacy.fishtankApp.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL,
           Bundle(url: Legacy.fishtankApp)?.bundleIdentifier == Legacy.fishtankBundleID {
            NSRunningApplication.runningApplications(withBundleIdentifier: Legacy.fishtankBundleID).forEach { $0.terminate() }
            try? fm.trashItem(at: Legacy.fishtankApp, resultingItemURL: nil)
        }

        // Looking in ~/Desktop makes macOS ask for Desktop access, so only do it once, and only after a script install.
        guard fm.fileExists(atPath: Legacy.scriptDataDir.path), !UserDefaults.standard.bool(forKey: Pref.desktopChecked) else { return }
        UserDefaults.standard.set(true, forKey: Pref.desktopChecked)
        let desktop = home.appendingPathComponent("Desktop")
        for name in Legacy.desktopApps {
            let url = desktop.appendingPathComponent(name)
            guard url.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL,
                  let id = Bundle(url: url)?.bundleIdentifier, id.hasPrefix("com.claude.lockscreen") else { continue }
            try? fm.trashItem(at: url, resultingItemURL: nil)
        }
    }

    // MARK: Moving out of Downloads, uninstalling

    private func askToMoveToApplications() {
        let alert = NSAlert()
        alert.messageText = "Move Agent Aquarium to Applications"
        alert.informativeText = "macOS opened Agent Aquarium from a temporary location, where it can't set itself up. Drag Agent Aquarium into your Applications folder, then open it from there."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    @objc private func uninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Agent Aquarium?"
        alert.informativeText = "This removes the Claude Code hooks, stops the background server and removes the screensaver. Afterwards, drag Agent Aquarium from Applications to the Trash."
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Also delete my settings, presets and Google sign-in"
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let deleteData = alert.suppressionButton?.state == .on

        if hookState() != .none || usageState() != .none { run(nodeBinary.path, ["setup-hooks", "--uninstall"]) }
        if deleteData { signOutOfGoogle() }
        stopServer()
        if fm.fileExists(atPath: installedSaver.path) { try? fm.trashItem(at: installedSaver, resultingItemURL: nil) }
        if deleteData, fm.fileExists(atPath: dataDir.path) { try? fm.trashItem(at: dataDir, resultingItemURL: nil) }
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "")

        let done = NSAlert()
        done.messageText = "Agent Aquarium is uninstalled"
        done.informativeText = "Drag Agent Aquarium from Applications to the Trash to finish."
        done.runModal()
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        NSApp.terminate(nil)
    }

    /// Revokes the Google token through the running server, so uninstalling doesn't leave access behind.
    private func signOutOfGoogle() {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:4777/google/disconnect")!, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Data("{}".utf8)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 12)
    }

    // MARK: Menu

    // Standard app and Edit menus, so Quit and Cmd+C/V/A/Z work in the text field.
    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r").target = self
        appMenu.addItem(.separator())
        hooksItem = appMenu.addItem(withTitle: "Connect Claude Code…", action: #selector(toggleHooks), keyEquivalent: "")
        hooksItem.target = self
        usageItem = appMenu.addItem(withTitle: "Show Plan Usage", action: #selector(toggleUsage), keyEquivalent: "")
        usageItem.target = self
        appMenu.addItem(withTitle: "Screen Saver Settings…", action: #selector(openScreenSaverSettings), keyEquivalent: "").target = self
        let displayItem = appMenu.addItem(withTitle: "Always-On Display", action: nil, keyEquivalent: "")
        displayMenu = NSMenu(title: "Always-On Display")
        displayMenu.delegate = self
        displayItem.submenu = displayMenu
        appMenu.addItem(withTitle: "Uninstall Agent Aquarium…", action: #selector(uninstall), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Agent Aquarium", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Agent Aquarium", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    @objc private func reload() { webView?.load(URLRequest(url: settingsURL)) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
