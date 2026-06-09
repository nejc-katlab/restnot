import AppKit

struct ActiveItem {
    let key: String
    let display: String
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var processWatcher: ProcessWatcher!
    private var leaseWatcher: LeaseWatcher!
    private var sleepManager: SleepManager!
    private var pollTimer: Timer?
    private var graceTimer: Timer?
    private var activeItems: [ActiveItem] = []
    private var startTimes: [String: Date] = [:]
    private var isPaused = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        sleepManager = SleepManager()
        processWatcher = ProcessWatcher()
        leaseWatcher = LeaseWatcher()
        setupStatusItem()
        startPolling()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "RestNot")
        }
        updateMenu()
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: Config.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    private func poll() {
        guard !isPaused else { return }

        var items: [ActiveItem] = []

        for lease in leaseWatcher.activeLeases() {
            let short = String(lease.sessionId.prefix(8))
            items.append(ActiveItem(key: "claude:\(lease.sessionId)", display: "Claude Code (\(short))"))
        }

        var seen = Set<String>()
        for proc in processWatcher.scan() where seen.insert(proc.displayName).inserted {
            items.append(ActiveItem(key: "proc:\(proc.displayName)", display: proc.displayName))
        }

        items.sort { $0.display < $1.display }

        let currentKeys = Set(items.map { $0.key })
        let previousKeys = Set(startTimes.keys)
        for key in currentKeys.subtracting(previousKeys) {
            startTimes[key] = Date()
        }
        for key in previousKeys.subtracting(currentKeys) {
            startTimes.removeValue(forKey: key)
        }

        activeItems = items

        if !items.isEmpty {
            graceTimer?.invalidate()
            graceTimer = nil

            let reason = items.prefix(5).map { $0.display }.joined(separator: ", ")
            sleepManager.assertIfNeeded(reason: reason)
            updateIcon(active: true)
        } else if sleepManager.isHolding {
            if graceTimer == nil {
                graceTimer = Timer.scheduledTimer(withTimeInterval: Config.gracePeriod, repeats: false) { [weak self] _ in
                    self?.sleepManager.releaseAssertion()
                    self?.updateIcon(active: false)
                    self?.updateMenu()
                }
            }
        }

        updateMenu()
    }

    // MARK: - UI Updates

    private func updateIcon(active: Bool) {
        guard let button = statusItem.button else { return }
        let symbolName = active ? "moon.zzz.fill" : "moon.zzz"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "RestNot")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = active ? .systemGreen : nil
    }

    private func updateMenu() {
        let menu = NSMenu()

        if isPaused {
            let item = NSMenuItem(title: "Paused", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else if !activeItems.isEmpty {
            let header = NSMenuItem(title: "Preventing Sleep", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(NSMenuItem.separator())

            for item in activeItems {
                let duration = formatDuration(since: startTimes[item.key])
                let title = "  \(item.display) — \(duration)"
                let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                menuItem.isEnabled = false
                menu.addItem(menuItem)
            }
        } else {
            let item = NSMenuItem(title: "Idle — sleep allowed", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let pauseTitle = isPaused ? "Resume RestNot" : "Pause RestNot"
        let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit RestNot", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.addItem(NSMenuItem.separator())

        let versionItem = NSMenuItem(title: "v0.1.0", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        statusItem.menu = menu
    }

    private func formatDuration(since date: Date?) -> String {
        guard let date = date else { return "just now" }
        let interval = Int(Date().timeIntervalSince(date))
        let minutes = interval / 60
        let hours = minutes / 60
        if hours > 0 {
            return "\(hours)h \(minutes % 60)m"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else {
            return "<1m"
        }
    }

    // MARK: - Actions

    @objc private func togglePause() {
        isPaused.toggle()
        if isPaused {
            graceTimer?.invalidate()
            graceTimer = nil
            sleepManager.releaseAssertion()
            updateIcon(active: false)
        } else {
            poll()
        }
        updateMenu()
    }

    @objc private func quit() {
        sleepManager.releaseAssertion()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        sleepManager.releaseAssertion()
    }
}
