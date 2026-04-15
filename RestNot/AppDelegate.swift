import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var processWatcher: ProcessWatcher!
    private var sleepManager: SleepManager!
    private var pollTimer: Timer?
    private var graceTimer: Timer?
    private var activeProcesses: [WatchedProcess] = []
    private var processStartTimes: [String: Date] = [:]
    private var isPaused = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        sleepManager = SleepManager()
        processWatcher = ProcessWatcher()
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

        let matches = processWatcher.scan()

        let currentKeys = Set(matches.map { $0.displayName })
        let previousKeys = Set(processStartTimes.keys)

        for key in currentKeys.subtracting(previousKeys) {
            processStartTimes[key] = Date()
        }
        for key in previousKeys.subtracting(currentKeys) {
            processStartTimes.removeValue(forKey: key)
        }

        // Deduplicate by display name for the menu
        var seenNames = Set<String>()
        activeProcesses = matches.filter { seenNames.insert($0.displayName).inserted }

        if !matches.isEmpty {
            graceTimer?.invalidate()
            graceTimer = nil

            // Deduplicate by display name for the assertion reason
            let uniqueNames = Array(Set(matches.map { $0.displayName })).sorted()
            let reason = uniqueNames.prefix(5).joined(separator: ", ")
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
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "RestNot")
    }

    private func updateMenu() {
        let menu = NSMenu()

        if isPaused {
            let item = NSMenuItem(title: "Paused", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else if !activeProcesses.isEmpty {
            let header = NSMenuItem(title: "Preventing Sleep", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(NSMenuItem.separator())

            for process in activeProcesses {
                let duration = formatDuration(since: processStartTimes[process.displayName])
                let title = "  \(process.displayName) — \(duration)"
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        } else {
            let item = NSMenuItem(title: "No active processes", action: nil, keyEquivalent: "")
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
