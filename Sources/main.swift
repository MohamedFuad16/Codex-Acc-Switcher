import AppKit
import Foundation
import UserNotifications

struct CodexAccount {
    let selector: String
    let email: String
    let plan: String
    let fiveHourUsage: String
    let weeklyUsage: String
    let fiveHourUsedPercent: Int?
    let weeklyUsedPercent: Int?
    let lastActivity: String
    let isActive: Bool
}

enum UsageDisplayMode: String {
    case fiveHour
    case weekly
}

struct CommandResult {
    let status: Int32
    let output: String
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let refreshInterval: TimeInterval = 3
    private let labelsDefaultsKey = "accountDisplayLabels"
    private let liveUsageEnabledDefaultsKey = "liveUsageRefreshEnabled"
    private let liveUsageIntervalDefaultsKey = "liveUsageRefreshInterval"
    private let remindersEnabledDefaultsKey = "usageReminderEnabled"
    private let reminderThresholdDefaultsKey = "usageReminderThreshold"
    private var refreshTimer: Timer?
    private var statusAnimationTimer: Timer?
    private var statusAnimationFrame = 0
    private var accounts: [CodexAccount] = []
    private var isRefreshingAccounts = false
    private var lastError: String?
    private var lastLiveUsageRefreshAt: Date?
    private var lastLiveUsageRefreshError: String?
    private var lastMenuFingerprint = ""
    private var isSwitching = false
    private var switchAnimationTimer: Timer?
    private var switchAnimationFrame = 0
    private var switchingTitle = "Switching"
    private let switchAnimationFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private let statusPulseFrames = ["·", "•", "·", " "]
    private var notifiedLowUsageKeys = Set<String>()
    private var remindersEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: remindersEnabledDefaultsKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: remindersEnabledDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: remindersEnabledDefaultsKey)
        }
    }
    private var reminderThreshold: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: reminderThresholdDefaultsKey)
            return stored == 0 ? 10 : max(1, min(99, stored))
        }
        set {
            UserDefaults.standard.set(max(1, min(99, newValue)), forKey: reminderThresholdDefaultsKey)
        }
    }
    private var usageMode: UsageDisplayMode {
        get {
            UsageDisplayMode(rawValue: UserDefaults.standard.string(forKey: "usageDisplayMode") ?? "") ?? .weekly
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "usageDisplayMode")
        }
    }
    private var liveUsageRefreshEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: liveUsageEnabledDefaultsKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: liveUsageEnabledDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: liveUsageEnabledDefaultsKey)
        }
    }
    private var liveUsageRefreshInterval: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: liveUsageIntervalDefaultsKey)
            return stored == 0 ? 300 : max(60, min(3600, stored))
        }
        set {
            UserDefaults.standard.set(max(60, min(3600, newValue)), forKey: liveUsageIntervalDefaultsKey)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureNotifications()
        configureStatusButton()
        refreshAccounts(forceLive: true)
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshAccounts()
        }
        RunLoop.current.add(timer, forMode: .common)
        refreshTimer = timer

        let animationTimer = Timer(timeInterval: 0.65, repeats: true) { [weak self] _ in
            self?.advanceStatusAnimation()
        }
        RunLoop.current.add(animationTimer, forMode: .common)
        statusAnimationTimer = animationTimer
    }

    private func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.toolTip = "Codex Account Switcher"
        button.image = loadCodexIcon()
        button.imagePosition = .imageLeft
    }

    private func loadCodexIcon() -> NSImage? {
        let bundledCandidates = [
            Bundle.main.path(forResource: "ToolbarIcon", ofType: "png"),
            Bundle.main.path(forResource: "AccountSwitcherIcon", ofType: "png"),
            Bundle.main.path(forResource: "AccountSwitcherIcon", ofType: "icns")
        ].compactMap { $0 }
        let candidates = bundledCandidates + [
            "/Applications/Codex.app/Contents/Resources/icon.icns",
            "/Applications/Codex.app/Contents/Resources/codexTemplate@2x.png",
            "/Applications/Codex.app/Contents/Resources/codexTemplate.png"
        ]

        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let image = NSImage(contentsOfFile: path) else {
            return nil
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        return image
    }

    private func refreshAccounts(forceLive: Bool = false) {
        guard !isSwitching, !isRefreshingAccounts else { return }
        isRefreshingAccounts = true
        let useLive = forceLive || shouldRefreshLiveUsage()
        DispatchQueue.global(qos: .utility).async {
            _ = self.syncActiveAuthSnapshot(onlyIfSourceIsNewer: true)
            let refresh = self.accountListResult(useLive: useLive)
            let result = refresh.result
            let parsed = result.status == 0 ? self.parseAccounts(result.output) : []
            DispatchQueue.main.async {
                self.isRefreshingAccounts = false
                if useLive {
                    self.lastLiveUsageRefreshAt = Date()
                    if refresh.usedLive && result.status == 0 {
                        self.lastLiveUsageRefreshError = nil
                    } else if let liveError = refresh.liveError {
                        self.lastLiveUsageRefreshError = liveError
                    }
                }

                if result.status == 0 {
                    self.accounts = parsed
                    self.lastError = parsed.isEmpty ? "No codex-auth accounts found." : nil
                } else {
                    self.accounts = []
                    self.lastError = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                self.checkUsageReminder()
                let fingerprint = self.menuFingerprint()
                if fingerprint != self.lastMenuFingerprint {
                    self.rebuildMenu()
                } else if let active = self.accounts.first(where: { $0.isActive }), !self.isSwitching {
                    self.updateStatusTitle(for: active)
                }
            }
        }
    }

    private func shouldRefreshLiveUsage() -> Bool {
        guard liveUsageRefreshEnabled else { return false }
        guard let lastLiveUsageRefreshAt else { return true }
        return Date().timeIntervalSince(lastLiveUsageRefreshAt) >= liveUsageRefreshInterval
    }

    private func accountListResult(useLive: Bool) -> (result: CommandResult, usedLive: Bool, liveError: String?) {
        if useLive {
            var liveResult = runCodexAuth(["list", "--active", "--api"])
            if liveResult.status != 0 {
                liveResult = runCodexAuth(["list", "--api"])
            }
            if liveResult.status == 0 {
                return (liveResult, true, nil)
            }

            let cached = cachedAccountListResult()
            if cached.status == 0 {
                return (cached, false, liveResult.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return (liveResult, true, liveResult.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return (cachedAccountListResult(), false, nil)
    }

    private func cachedAccountListResult() -> CommandResult {
        var result = runCodexAuth(["list", "--skip-api"])
        if result.status != 0 {
            result = runCodexAuth(["list"])
        }
        return result
    }

    private func menuFingerprint() -> String {
        let accountPart = accounts.map {
            [
                $0.selector,
                $0.email,
                $0.plan,
                $0.fiveHourUsage,
                $0.weeklyUsage,
                $0.lastActivity,
                $0.isActive ? "active" : "inactive",
                displayLabel(for: $0)
            ].joined(separator: "|")
        }.joined(separator: "\n")
        return [
            accountPart,
            lastError ?? "",
            lastLiveUsageRefreshAt.map { "\($0.timeIntervalSince1970)" } ?? "",
            lastLiveUsageRefreshError ?? "",
            usageMode.rawValue,
            liveUsageRefreshEnabled ? "live-on" : "live-off",
            "\(Int(liveUsageRefreshInterval))",
            remindersEnabled ? "reminders-on" : "reminders-off",
            "\(reminderThreshold)"
        ].joined(separator: "\n---\n")
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        if let active = accounts.first(where: { $0.isActive }) {
            if !isSwitching {
                updateStatusTitle(for: active)
            }
        } else {
            if !isSwitching {
                statusItem.button?.title = ""
            }
        }

        if accounts.isEmpty {
            let item = NSMenuItem(title: lastError ?? "No accounts available", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            menu.addItem(headerItem("Accounts:"))
            for account in accounts {
                let item = NSMenuItem(title: "", action: #selector(switchAccount(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = account.selector
                item.attributedTitle = accountAttributedTitle(label: displayLabel(for: account), email: account.email)
                item.state = account.isActive ? .on : .off
                item.toolTip = "Plan \(account.plan), 5h \(account.fiveHourUsage), weekly \(account.weeklyUsage)"
                item.isEnabled = !isSwitching
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Toggle Account", action: #selector(toggleAccount), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = accounts.count == 2 && !isSwitching
        menu.addItem(toggle)

        menu.addItem(.separator())

        let addAccount = NSMenuItem(title: "Add Account...", action: #selector(addAccountBrowser), keyEquivalent: "")
        addAccount.target = self
        addAccount.isEnabled = !isSwitching
        menu.addItem(addAccount)

        let addDevice = NSMenuItem(title: "Add Account with Device Code...", action: #selector(addAccountDeviceCode), keyEquivalent: "")
        addDevice.target = self
        addDevice.isEnabled = !isSwitching
        addDevice.toolTip = "Opens Terminal so the device code remains visible while login waits."
        menu.addItem(addDevice)

        if !accounts.isEmpty {
            let labelsItem = NSMenuItem(title: "Account Display Labels", action: nil, keyEquivalent: "")
            let labelsMenu = NSMenu()
            for account in accounts {
                let setItem = NSMenuItem(title: "Set \(account.selector) (\(account.email))...", action: #selector(setAccountLabel(_:)), keyEquivalent: "")
                setItem.target = self
                setItem.representedObject = account.email
                labelsMenu.addItem(setItem)

                let clearItem = NSMenuItem(title: "Clear \(account.selector)", action: #selector(clearAccountLabel(_:)), keyEquivalent: "")
                clearItem.target = self
                clearItem.representedObject = account.email
                clearItem.isEnabled = customLabel(forEmail: account.email) != nil
                labelsMenu.addItem(clearItem)
            }
            labelsItem.submenu = labelsMenu
            menu.addItem(labelsItem)

            let removeItem = NSMenuItem(title: "Remove Account", action: nil, keyEquivalent: "")
            let removeMenu = NSMenu()
            for account in accounts {
                let item = NSMenuItem(title: "\(displayLabel(for: account))  \(account.email)", action: #selector(removeAccount(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = account.selector
                item.isEnabled = !isSwitching
                removeMenu.addItem(item)
            }
            removeItem.submenu = removeMenu
            menu.addItem(removeItem)
        }

        let reminderItem = NSMenuItem(title: "Usage Reminder", action: nil, keyEquivalent: "")
        let reminderMenu = NSMenu()
        let enableReminder = NSMenuItem(title: "Notify below \(reminderThreshold)%", action: #selector(toggleUsageReminder), keyEquivalent: "")
        enableReminder.target = self
        enableReminder.state = remindersEnabled ? .on : .off
        reminderMenu.addItem(enableReminder)

        let setThreshold = NSMenuItem(title: "Set Reminder Percentage...", action: #selector(setReminderThreshold), keyEquivalent: "")
        setThreshold.target = self
        reminderMenu.addItem(setThreshold)

        let testNotification = NSMenuItem(title: "Test Notification", action: #selector(testUsageReminder), keyEquivalent: "")
        testNotification.target = self
        testNotification.isEnabled = remindersEnabled
        reminderMenu.addItem(testNotification)
        reminderItem.submenu = reminderMenu
        menu.addItem(reminderItem)

        let displayItem = NSMenuItem(title: "Menu Bar Display", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        let fiveHourDisplay = NSMenuItem(title: "5-hour usage", action: #selector(setUsageMode(_:)), keyEquivalent: "")
        fiveHourDisplay.target = self
        fiveHourDisplay.representedObject = UsageDisplayMode.fiveHour.rawValue
        fiveHourDisplay.state = usageMode == .fiveHour ? .on : .off
        displayMenu.addItem(fiveHourDisplay)
        let weeklyDisplay = NSMenuItem(title: "Weekly usage", action: #selector(setUsageMode(_:)), keyEquivalent: "")
        weeklyDisplay.target = self
        weeklyDisplay.representedObject = UsageDisplayMode.weekly.rawValue
        weeklyDisplay.state = usageMode == .weekly ? .on : .off
        displayMenu.addItem(weeklyDisplay)
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

        let liveRefreshItem = NSMenuItem(title: "Live Usage Refresh", action: nil, keyEquivalent: "")
        let liveRefreshMenu = NSMenu()
        let toggleLiveRefresh = NSMenuItem(title: "Enabled", action: #selector(toggleLiveUsageRefresh), keyEquivalent: "")
        toggleLiveRefresh.target = self
        toggleLiveRefresh.state = liveUsageRefreshEnabled ? .on : .off
        liveRefreshMenu.addItem(toggleLiveRefresh)
        liveRefreshMenu.addItem(.separator())
        for interval in [300, 900, 1800] {
            let item = NSMenuItem(title: liveUsageIntervalTitle(TimeInterval(interval)), action: #selector(setLiveUsageRefreshInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = interval
            item.state = Int(liveUsageRefreshInterval) == interval ? .on : .off
            liveRefreshMenu.addItem(item)
        }
        if let lastLiveUsageRefreshAt {
            liveRefreshMenu.addItem(.separator())
            let item = NSMenuItem(title: "Last live update: \(shortTime(lastLiveUsageRefreshAt))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            liveRefreshMenu.addItem(item)
        }
        if let lastLiveUsageRefreshError, !lastLiveUsageRefreshError.isEmpty {
            let item = NSMenuItem(title: "Last live refresh used cache", action: nil, keyEquivalent: "")
            item.toolTip = lastLiveUsageRefreshError
            item.isEnabled = false
            liveRefreshMenu.addItem(item)
        }
        liveRefreshItem.submenu = liveRefreshMenu
        menu.addItem(liveRefreshItem)

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh Usage Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = !isSwitching
        menu.addItem(refresh)

        let syncSession = NSMenuItem(title: "Sync Active Session", action: #selector(syncActiveSessionNow), keyEquivalent: "")
        syncSession.target = self
        syncSession.isEnabled = !isSwitching
        syncSession.toolTip = "Copies the current Codex auth snapshot back to the saved active account when it is newer."
        menu.addItem(syncSession)

        if let active = accounts.first(where: { $0.isActive }) {
            let copyEmail = NSMenuItem(title: "Copy Active Email", action: #selector(copyActiveEmail), keyEquivalent: "")
            copyEmail.target = self
            copyEmail.representedObject = active.email
            menu.addItem(copyEmail)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Account Switcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        lastMenuFingerprint = menuFingerprint()
    }

    private func advanceStatusAnimation() {
        guard !isSwitching, let active = accounts.first(where: { $0.isActive }) else { return }
        statusAnimationFrame += 1
        updateStatusTitle(for: active)
    }

    private func updateStatusTitle(for account: CodexAccount) {
        statusItem.button?.title = statusTitle(for: account)
    }

    private func statusTitle(for account: CodexAccount) -> String {
        let pulse = statusPulseFrames[statusAnimationFrame % statusPulseFrames.count]
        switch usageMode {
        case .fiveHour:
            return "\(displayLabel(for: account)) \(pulse) 5hr \(remainingPercentText(fromUsed: account.fiveHourUsedPercent))"
        case .weekly:
            return "\(displayLabel(for: account)) \(pulse) W \(remainingPercentText(fromUsed: account.weeklyUsedPercent))"
        }
    }

    private func remainingPercentText(fromUsed used: Int?) -> String {
        guard let used else { return "--%" }
        return "\(max(0, min(100, used)))%"
    }

    private func accountAttributedTitle(label: String, email: String) -> NSAttributedString {
        attributedColumns(
            "\(limitedLabel(label))\t\(email)",
            tabs: [86],
            font: NSFont.menuFont(ofSize: 0),
            color: .labelColor
        )
    }

    private func attributedColumns(_ text: String, tabs: [CGFloat], font: NSFont, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = tabs.map { NSTextTab(textAlignment: .left, location: $0) }
        paragraph.defaultTabInterval = 48
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }

    private func headerItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    private func liveUsageIntervalTitle(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        return minutes == 1 ? "Every minute" : "Every \(minutes) minutes"
    }

    @objc private func refreshNow() {
        refreshAccounts(forceLive: true)
    }

    @objc private func setUsageMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = UsageDisplayMode(rawValue: rawValue) else { return }
        usageMode = mode
        lastMenuFingerprint = ""
        rebuildMenu()
    }

    @objc private func toggleLiveUsageRefresh() {
        liveUsageRefreshEnabled.toggle()
        lastMenuFingerprint = ""
        rebuildMenu()
        if liveUsageRefreshEnabled {
            refreshAccounts(forceLive: true)
        }
    }

    @objc private func setLiveUsageRefreshInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? Int else { return }
        liveUsageRefreshInterval = TimeInterval(interval)
        lastMenuFingerprint = ""
        rebuildMenu()
    }

    @objc private func syncActiveSessionNow() {
        if let error = syncActiveAuthSnapshot(onlyIfSourceIsNewer: false) {
            showAlert(title: "Session sync failed", message: error)
            return
        }
        refreshAccounts()
    }

    @objc private func copyActiveEmail(_ sender: NSMenuItem) {
        guard let email = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(email, forType: .string)
    }

    @objc private func addAccountBrowser() {
        runAccountMaintenance(title: "Adding account", args: ["login"], restartAfterSuccess: true)
    }

    @objc private func addAccountDeviceCode() {
        let path = codexAuthPath() ?? "codex-auth"
        let home = NSHomeDirectory()
        let restartPath = "\(home)/.codex/skills/codex-account-switcher/scripts/codex_account_switch.sh"
        let setupCommand = shellEnvironmentSetupCommand()
        let script = """
        tell application "Terminal"
          activate
          do script "\(setupCommand); \(shellEscaped(path)) login --device-auth && \(shellEscaped(restartPath)) restart-app; echo; echo 'Codex account login finished and Codex App was relaunched. You can close this window.'"
        end tell
        """
        let result = run("/usr/bin/osascript", ["-e", script])
        if result.status != 0 {
            showAlert(title: "Device-code login failed", message: result.output)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refreshAccounts()
        }
    }

    @objc private func toggleUsageReminder() {
        remindersEnabled.toggle()
        if remindersEnabled {
            configureNotifications()
            checkUsageReminder()
        } else {
            notifiedLowUsageKeys.removeAll()
        }
        rebuildMenu()
    }

    @objc private func setReminderThreshold() {
        let alert = NSAlert()
        alert.messageText = "Usage reminder"
        alert.informativeText = "Notify when the active account usage display is at or below this percentage."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = "\(reminderThreshold)"
        field.placeholderString = "10"
        alert.accessoryView = field

        if alert.runModal() == .alertFirstButtonReturn {
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Int(trimmed), (1...99).contains(value) else {
                showAlert(title: "Invalid percentage", message: "Enter a number from 1 to 99.")
                return
            }
            reminderThreshold = value
            notifiedLowUsageKeys.removeAll()
            checkUsageReminder()
            rebuildMenu()
        }
    }

    @objc private func testUsageReminder() {
        if let active = accounts.first(where: { $0.isActive }) {
            sendUsageReminder(account: active, metric: "5hr", percent: active.fiveHourUsedPercent ?? reminderThreshold, reportResult: true)
        } else {
            sendNotification(
                title: "Codex usage reminder",
                subtitle: "No active account",
                body: "Open the switcher after adding a Codex account.",
                reportResult: true
            )
        }
    }

    @objc private func setAccountLabel(_ sender: NSMenuItem) {
        guard let email = sender.representedObject as? String,
              let account = accounts.first(where: { $0.email == email }) else { return }

        let alert = NSAlert()
        alert.messageText = "Set display label"
        alert.informativeText = "Choose the label shown in the menu bar for \(account.email). Use 01, 02, text, or an emoji."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = displayLabel(for: account)
        alert.accessoryView = field

        if alert.runModal() == .alertFirstButtonReturn {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                clearCustomLabel(forEmail: email)
            } else {
                setCustomLabel(limitedLabel(value), forEmail: email)
            }
            rebuildMenu()
        }
    }

    @objc private func clearAccountLabel(_ sender: NSMenuItem) {
        guard let email = sender.representedObject as? String else { return }
        clearCustomLabel(forEmail: email)
        rebuildMenu()
    }

    @objc private func removeAccount(_ sender: NSMenuItem) {
        guard let selector = sender.representedObject as? String,
              let account = accounts.first(where: { $0.selector == selector }) else { return }

        let alert = NSAlert()
        alert.messageText = "Remove account?"
        alert.informativeText = "Remove \(account.email) from codex-auth switching?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            // `remove <query>` matches by email/alias, not the row-number selector.
            runAccountMaintenance(title: "Removing account", args: ["remove", account.email])
        }
    }

    @objc private func toggleAccount() {
        guard accounts.count == 2, let inactive = accounts.first(where: { !$0.isActive }) else {
            showAlert(title: "Cannot toggle", message: "Toggle requires exactly two saved accounts and one active account.")
            return
        }
        switchTo(selector: inactive.selector)
    }

    @objc private func switchAccount(_ sender: NSMenuItem) {
        guard let selector = sender.representedObject as? String else { return }
        switchTo(selector: selector)
    }

    private func switchTo(selector: String) {
        guard !isSwitching else { return }
        let target = accounts.first(where: { $0.selector == selector })
        isSwitching = true
        beginSwitchAnimation(label: target.map(displayLabel(for:)) ?? selector)
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async {
            if let syncError = self.syncActiveAuthSnapshot() {
                DispatchQueue.main.async {
                    self.isSwitching = false
                    self.endSwitchAnimation()
                    self.showAlert(title: "Could not save active token", message: syncError)
                    self.refreshAccounts()
                }
                return
            }

            // `switch <query>` matches by email/alias, not the row-number selector,
            // so pass the account email (falling back to the selector if unknown).
            let switchResult = self.runCodexAuth(["switch", target?.email ?? selector])
            if switchResult.status != 0 {
                DispatchQueue.main.async {
                    self.isSwitching = false
                    self.endSwitchAnimation()
                    self.showAlert(title: "Switch failed", message: switchResult.output)
                    self.refreshAccounts()
                }
                return
            }

            let restartResult = self.restartCodexApp()
            DispatchQueue.main.async {
                self.isSwitching = false
                self.endSwitchAnimation()
                if restartResult.status != 0 {
                    self.showAlert(title: "Codex relaunch failed", message: restartResult.output)
                }
                self.refreshAccounts()
            }
        }
    }

    private func beginSwitchAnimation(label: String) {
        switchAnimationTimer?.invalidate()
        switchAnimationFrame = 0
        switchingTitle = "\(limitedLabel(label)) · switching"
        updateSwitchAnimationTitle()
        switchAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.switchAnimationFrame += 1
            self.updateSwitchAnimationTitle()
        }
    }

    private func updateSwitchAnimationTitle() {
        let frame = switchAnimationFrames[switchAnimationFrame % switchAnimationFrames.count]
        statusItem.button?.title = "\(switchingTitle) \(frame)"
    }

    private func endSwitchAnimation() {
        switchAnimationTimer?.invalidate()
        switchAnimationTimer = nil
    }

    private func checkUsageReminder() {
        guard remindersEnabled, let active = accounts.first(where: { $0.isActive }) else { return }
        checkUsageReminder(account: active, metric: "5hr", percent: active.fiveHourUsedPercent)
        checkUsageReminder(account: active, metric: "Weekly", percent: active.weeklyUsedPercent)
    }

    private func checkUsageReminder(account: CodexAccount, metric: String, percent: Int?) {
        guard let percent else { return }
        let threshold = reminderThreshold
        let key = "\(account.email)|\(metric)|\(threshold)"
        if percent <= threshold {
            guard !notifiedLowUsageKeys.contains(key) else { return }
            notifiedLowUsageKeys.insert(key)
            sendUsageReminder(account: account, metric: metric, percent: percent)
        } else {
            notifiedLowUsageKeys.remove(key)
        }
    }

    private func sendUsageReminder(account: CodexAccount, metric: String, percent: Int, reportResult: Bool = false) {
        let label = displayLabel(for: account)
        sendNotification(
            title: "Codex usage is low",
            subtitle: "\(label) · \(metric) \(percent)%",
            body: "\(account.email) is at or below \(reminderThreshold)%. Switch to another saved account from the menu bar when you are ready.",
            reportResult: reportResult
        )
    }

    private func sendNotification(title: String, subtitle: String, body: String, reportResult: Bool = false) {
        ensureNotificationAuthorization { [weak self] isAuthorized, message in
            guard let self else { return }
            guard isAuthorized else {
                if reportResult {
                    DispatchQueue.main.async {
                        self.showNotificationSettingsAlert(message: message ?? self.notificationSettingsMessage())
                    }
                }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.subtitle = subtitle
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "codex-usage-\(UUID().uuidString)",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    NSLog("Codex Account Switcher notification failed: \(error.localizedDescription)")
                    if reportResult {
                        DispatchQueue.main.async {
                            self.showNotificationSettingsAlert(message: self.notificationSettingsMessage())
                        }
                    }
                } else if reportResult {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.showAlert(title: "Test notification sent", message: "If no banner appeared, check System Settings > Notifications > Codex Account Switcher and make sure alerts are enabled.")
                    }
                }
            }
        }
    }

    private func ensureNotificationAuthorization(_ completion: @escaping (Bool, String?) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                completion(true, nil)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if error != nil {
                        completion(false, self.notificationSettingsMessage())
                    } else if granted {
                        completion(true, nil)
                    } else {
                        completion(false, self.notificationSettingsMessage())
                    }
                }
            case .denied:
                completion(false, self.notificationSettingsMessage())
            @unknown default:
                completion(false, self.notificationSettingsMessage())
            }
        }
    }

    private func notificationSettingsMessage() -> String {
        "Enable notifications for Codex Account Switcher in System Settings > Notifications, then run Test Notification again. If it is not listed yet, quit and reopen the switcher once after this update."
    }

    private func showNotificationSettingsAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Enable notifications"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn {
            openNotificationSettings()
        }
    }

    private func openNotificationSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.mohamedfuad.codexaccountswitcher",
            "x-apple.systempreferences:com.apple.preference.notifications?id=com.mohamedfuad.codexaccountswitcher",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications"
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }

        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/System Settings.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    private func syncActiveAuthSnapshot(onlyIfSourceIsNewer: Bool = false) -> String? {
        let home = NSHomeDirectory()
        let registryURL = URL(fileURLWithPath: "\(home)/.codex/accounts/registry.json")
        let activeAuthURL = URL(fileURLWithPath: "\(home)/.codex/auth.json")

        do {
            let data = try Data(contentsOf: registryURL)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let activeKey = json["active_account_key"] as? String else {
                return "Could not read active_account_key from registry.json."
            }

            let encoded = Data(activeKey.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
            let accountAuthURL = URL(fileURLWithPath: "\(home)/.codex/accounts/\(encoded).auth.json")
            guard FileManager.default.fileExists(atPath: activeAuthURL.path) else {
                return "Active auth file does not exist at \(activeAuthURL.path)."
            }

            if onlyIfSourceIsNewer,
               FileManager.default.fileExists(atPath: accountAuthURL.path),
               let activeDate = modificationDate(for: activeAuthURL),
               let accountDate = modificationDate(for: accountAuthURL),
               activeDate <= accountDate {
                return nil
            }

            let backupURL = accountAuthURL.deletingLastPathComponent().appendingPathComponent(
                accountAuthURL.lastPathComponent + ".bak.\(Int(Date().timeIntervalSince1970))"
            )
            if FileManager.default.fileExists(atPath: accountAuthURL.path) {
                try? FileManager.default.copyItem(at: accountAuthURL, to: backupURL)
                try FileManager.default.removeItem(at: accountAuthURL)
            }
            try FileManager.default.copyItem(at: activeAuthURL, to: accountAuthURL)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func modificationDate(for url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private func runAccountMaintenance(title: String, args: [String], restartAfterSuccess: Bool = false) {
        guard !isSwitching else { return }
        isSwitching = true
        statusItem.button?.title = title
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.runCodexAuth(args)
            var restartResult: CommandResult?
            if result.status == 0, restartAfterSuccess {
                restartResult = self.restartCodexApp()
            }
            DispatchQueue.main.async {
                self.isSwitching = false
                if result.status != 0 {
                    self.showAlert(title: "\(title) failed", message: result.output)
                } else if let restartResult, restartResult.status != 0 {
                    self.showAlert(title: "Codex relaunch failed", message: restartResult.output)
                }
                self.refreshAccounts()
            }
        }
    }

    private func restartCodexApp() -> CommandResult {
        var transcript: [String] = []
        transcript.append("Force-quitting Codex App process tree...")

        for attempt in 1...6 {
            let pids = codexAppPIDs()
            if pids.isEmpty { break }
            let signal = attempt == 1 ? "-TERM" : "-KILL"
            _ = run("/bin/kill", [signal] + pids)
            Thread.sleep(forTimeInterval: 1)
        }

        let remaining = codexAppPIDs()
        if !remaining.isEmpty {
            return CommandResult(status: 1, output: "Codex processes survived force quit: \(remaining.joined(separator: ", "))")
        }

        transcript.append("Opening Codex App...")
        let openResult = run("/usr/bin/open", ["-a", "Codex"])
        if openResult.status != 0 {
            return CommandResult(status: openResult.status, output: transcript.joined(separator: "\n") + "\n" + openResult.output)
        }

        Thread.sleep(forTimeInterval: 4)
        let runningResult = run("/usr/bin/osascript", ["-e", "application \"Codex\" is running"])
        if runningResult.output.trimmingCharacters(in: .whitespacesAndNewlines) != "true" {
            transcript.append("Codex App did not report as running after launch.")
            return CommandResult(status: 1, output: transcript.joined(separator: "\n"))
        }

        return CommandResult(status: 0, output: transcript.joined(separator: "\n"))
    }

    private func codexAppPIDs() -> [String] {
        let result = run("/usr/bin/pgrep", ["-f", "/Applications/Codex\\.app/Contents/"])
        guard result.status == 0 else { return [] }
        return result.output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func parseAccounts(_ output: String) -> [CodexAccount] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard !tokens.isEmpty else { return nil }

            let isActive = tokens.first == "*"
            let offset = isActive ? 1 : 0
            guard tokens.count >= offset + 3 else { return nil }
            guard tokens[offset].allSatisfy(\.isNumber) else { return nil }

            let selector = tokens[offset]
            let email = tokens[offset + 1]
            let plan = tokens[offset + 2]
            var cursor = offset + 3
            let fiveHour = Self.parseUsage(tokens, from: cursor)
            cursor = fiveHour.nextIndex
            let weekly = Self.parseUsage(tokens, from: cursor)
            cursor = weekly.nextIndex
            let lastActivity = tokens.dropFirst(cursor).joined(separator: " ")

            return CodexAccount(
                selector: selector,
                email: email,
                plan: plan,
                fiveHourUsage: fiveHour.text,
                weeklyUsage: weekly.text,
                fiveHourUsedPercent: fiveHour.usedPercent,
                weeklyUsedPercent: weekly.usedPercent,
                lastActivity: lastActivity.isEmpty ? "-" : lastActivity,
                isActive: isActive
            )
        }
    }

    private static func parseUsage(_ tokens: [String], from startIndex: Int) -> (text: String, usedPercent: Int?, nextIndex: Int) {
        guard startIndex < tokens.count else {
            return ("-", nil, startIndex)
        }

        let first = tokens[startIndex]
        if first == "-" {
            return ("-", nil, startIndex + 1)
        }

        var parts = [first]
        var cursor = startIndex + 1
        if cursor < tokens.count, tokens[cursor].hasPrefix("(") {
            while cursor < tokens.count {
                parts.append(tokens[cursor])
                if tokens[cursor].hasSuffix(")") {
                    cursor += 1
                    break
                }
                cursor += 1
            }
        }

        return (parts.joined(separator: " "), firstPercent(in: first), cursor)
    }

    private static func firstPercent(in token: String) -> Int? {
        let digits = token.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    private func runCodexAuth(_ args: [String]) -> CommandResult {
        guard let path = codexAuthPath() else {
            return CommandResult(status: 127, output: "codex-auth was not found in known locations.")
        }
        return run(path, args)
    }

    private func codexAuthPath() -> String? {
        let home = NSHomeDirectory()
        let nvmNodeDir = URL(fileURLWithPath: "\(home)/.nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(at: nvmNodeDir, includingPropertiesForKeys: nil) {
            for versionDir in versions {
                let path = versionDir.appendingPathComponent("bin/codex-auth").path
                if FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }

        let candidates = [
            "\(home)/.local/bin/codex-auth",
            "/opt/homebrew/bin/codex-auth",
            "/usr/local/bin/codex-auth"
        ]

        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }

        // Fallback using interactive zsh shell to check user's environment path
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "which codex-auth"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let path = path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        } catch {}

        return nil
    }

    private func run(_ executable: String, _ args: [String]) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        var environment = augmentedEnvironment()
        let bundledNode = "/Applications/Codex.app/Contents/Resources/node"
        if FileManager.default.isExecutableFile(atPath: bundledNode) {
            environment["CODEX_AUTH_NODE_EXECUTABLE"] = bundledNode
        }
        let bundledCodex = "/Applications/Codex.app/Contents/Resources/codex"
        if FileManager.default.isExecutableFile(atPath: bundledCodex) {
            environment["CODEX_CLI_PATH"] = bundledCodex
        }
        process.environment = environment

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            return CommandResult(status: process.terminationStatus, output: output)
        } catch {
            return CommandResult(status: 127, output: error.localizedDescription)
        }
    }

    private func augmentedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = augmentedPath(from: environment["PATH"])
        return environment
    }

    private func augmentedPath(from currentPath: String?) -> String {
        let home = NSHomeDirectory()
        let candidates = [
            "/Applications/Codex.app/Contents/Resources",
            "\(home)/.nvm/versions/node/v20.11.0/bin",
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        var seen = Set<String>()
        var parts: [String] = []
        for path in candidates + (currentPath?.split(separator: ":").map(String.init) ?? []) {
            guard !path.isEmpty, !seen.contains(path) else { continue }
            seen.insert(path)
            parts.append(path)
        }
        return parts.joined(separator: ":")
    }

    private func shellEnvironmentSetupCommand() -> String {
        let path = augmentedPath(from: nil)
        var commands = ["export PATH=\(shellEscaped(path))"]
        let bundledNode = "/Applications/Codex.app/Contents/Resources/node"
        if FileManager.default.isExecutableFile(atPath: bundledNode) {
            commands.append("export CODEX_AUTH_NODE_EXECUTABLE=\(shellEscaped(bundledNode))")
        }
        let bundledCodex = "/Applications/Codex.app/Contents/Resources/codex"
        if FileManager.default.isExecutableFile(atPath: bundledCodex) {
            commands.append("export CODEX_CLI_PATH=\(shellEscaped(bundledCodex))")
        }
        return commands.joined(separator: "; ")
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func displayLabel(for account: CodexAccount) -> String {
        limitedLabel(customLabel(forEmail: account.email) ?? account.selector)
    }

    private func limitedLabel(_ label: String) -> String {
        String(label.prefix(5))
    }

    private func customLabel(forEmail email: String) -> String? {
        accountLabels()[email]
    }

    private func setCustomLabel(_ label: String, forEmail email: String) {
        var labels = accountLabels()
        labels[email] = label
        UserDefaults.standard.set(labels, forKey: labelsDefaultsKey)
    }

    private func clearCustomLabel(forEmail email: String) {
        var labels = accountLabels()
        labels.removeValue(forKey: email)
        UserDefaults.standard.set(labels, forKey: labelsDefaultsKey)
    }

    private func accountLabels() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: labelsDefaultsKey) as? [String: String] ?? [:]
    }

    private func shellEscaped(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}


let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
