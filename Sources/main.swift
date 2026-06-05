import AppKit
import Darwin
import Foundation
import QuartzCore
import UniformTypeIdentifiers
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
    private let refreshInterval: TimeInterval = 5
    private let labelsDefaultsKey = "accountDisplayLabels"
    private let remindersEnabledDefaultsKey = "usageReminderEnabled"
    private let reminderThresholdDefaultsKey = "usageReminderThreshold"
    private var refreshTimer: Timer?
    private var statusAnimationTimer: Timer?
    private var statusAnimationFrame = 0
    private var accounts: [CodexAccount] = []
    private var lastError: String?
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureNotifications()
        configureStatusButton()
        refreshAccounts()
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

    private func refreshAccounts() {
        guard !isSwitching else { return }
        DispatchQueue.global(qos: .utility).async {
            var result = self.runCodexAuth(["list", "--active"])
            if result.status != 0 {
                result = self.runCodexAuth(["list", "--skip-api"])
            }
            let parsed = result.status == 0 ? self.parseAccounts(result.output) : []
            DispatchQueue.main.async {
                if result.status == 0 {
                    self.accounts = parsed
                    self.lastError = parsed.isEmpty ? "No codex-auth accounts found." : nil
                } else {
                    self.accounts = []
                    self.lastError = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                self.checkUsageReminder()
                self.rebuildMenu()
            }
        }
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

        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = !isSwitching
        menu.addItem(refresh)

        let quit = NSMenuItem(title: "Quit Account Switcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
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

    private func remainingSummary(for account: CodexAccount) -> String {
        switch usageMode {
        case .fiveHour:
            return "5h \(remainingPercentText(fromUsed: account.fiveHourUsedPercent)) left"
        case .weekly:
            return "W \(remainingPercentText(fromUsed: account.weeklyUsedPercent)) left"
        }
    }

    private func remainingPercentText(fromUsed used: Int?) -> String {
        guard let used else { return "--%" }
        return "\(max(0, min(100, used)))%"
    }

    private func usageModeItem(title: String, percent: String, reset: String, mode: UsageDisplayMode) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(setUsageMode(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = mode.rawValue
        item.state = usageMode == mode ? .on : .off
        item.attributedTitle = usageAttributedTitle(title: title, percent: percent, reset: reset)
        return item
    }

    private func usageAttributedTitle(title: String, percent: String, reset: String) -> NSAttributedString {
        attributedColumns(
            "\(title)\t\(percent)\t\(reset)",
            tabs: [112, 162],
            font: NSFont.menuFont(ofSize: 0),
            color: .labelColor
        )
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

    private func resetTimeText(from usage: String) -> String {
        let inner = parenthesizedValue(from: usage)
        guard let inner else { return "" }
        let parts = inner.split(separator: ":")
        guard parts.count >= 2, let hour = Int(parts[0]) else { return inner }
        let minute = String(parts[1].prefix(2))
        let suffix = hour >= 12 ? "PM" : "AM"
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        return "\(hour12):\(minute) \(suffix)"
    }

    private func resetDateText(from usage: String) -> String {
        guard let inner = parenthesizedValue(from: usage) else { return "" }
        if let range = inner.range(of: " on ") {
            return monthFirstDate(String(inner[range.upperBound...]))
        }
        let parts = inner.split(separator: " ")
        if parts.count >= 3, let onIndex = parts.firstIndex(of: "on"), onIndex + 2 < parts.endIndex {
            return monthFirstDate("\(parts[onIndex + 1]) \(parts[onIndex + 2])")
        }
        if parts.count >= 2 {
            return monthFirstDate("\(parts[parts.count - 2]) \(parts[parts.count - 1])")
        }
        return inner
    }

    private func monthFirstDate(_ text: String) -> String {
        let parts = text.split(separator: " ")
        guard parts.count == 2 else { return text }

        let day: String
        let month: String
        if parts[0].allSatisfy(\.isNumber) {
            day = String(parts[0])
            month = String(parts[1])
        } else {
            month = String(parts[0])
            day = String(parts[1])
        }

        let months = [
            "Jan": "January", "Feb": "February", "Mar": "March", "Apr": "April",
            "May": "May", "Jun": "June", "Jul": "July", "Aug": "August",
            "Sep": "September", "Oct": "October", "Nov": "November", "Dec": "December"
        ]
        return "\(months[month] ?? month) \(day)"
    }

    private func parenthesizedValue(from usage: String) -> String? {
        guard let open = usage.firstIndex(of: "("),
              let close = usage.firstIndex(of: ")"),
              open < close else { return nil }
        return String(usage[usage.index(after: open)..<close])
    }

    private func headerItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func refreshNow() {
        refreshAccounts()
    }

    @objc private func setFiveHourMode() {
        usageMode = .fiveHour
        rebuildMenu()
    }

    @objc private func setUsageMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = UsageDisplayMode(rawValue: rawValue) else { return }
        usageMode = mode
        rebuildMenu()
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

    @objc private func setWeeklyMode() {
        usageMode = .weekly
        rebuildMenu()
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
            runAccountMaintenance(title: "Removing account", args: ["remove", selector])
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

            let switchResult = self.runCodexAuth(["switch", selector])
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

    private func syncActiveAuthSnapshot() -> String? {
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

    private func displayPlan(_ plan: String) -> String {
        guard let first = plan.first else { return plan }
        return first.uppercased() + plan.dropFirst().lowercased()
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

struct ToolbarDashboardModel {
    let title: String
    let status: String
    let email: String
    let fiveHourPercent: String
    let fiveHourReset: String
    let weeklyPercent: String
    let weeklyReset: String
    let accountCount: String
    let icon: NSImage?
}

class GradientPanelView: NSView {
    private let gradientLayer = CAGradientLayer()
    private let overlayLayer = CALayer()

    init(cornerRadius: CGFloat = 26, borderAlpha: CGFloat = 0.22) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.withAlphaComponent(borderAlpha).cgColor
        gradientLayer.colors = [
            NSColor(calibratedWhite: 0.99, alpha: 1).cgColor,
            NSColor(calibratedWhite: 0.95, alpha: 1).cgColor
        ]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 1, y: 1)
        overlayLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(gradientLayer)
        layer?.addSublayer(overlayLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        gradientLayer.frame = bounds
        overlayLayer.frame = bounds.insetBy(dx: 1, dy: 1)
        overlayLayer.cornerRadius = max(0, (layer?.cornerRadius ?? 0) - 1)
    }
}

final class GlassCardView: NSView {
    init(cornerRadius: CGFloat = 16) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.78).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }
}

enum StudioUI {
    static let white = NSColor.labelColor
    static let ink = NSColor.labelColor
    static let muted = NSColor.secondaryLabelColor
    static let cyan = NSColor.systemGreen
    static let lime = NSColor.systemGreen
    static let warning = NSColor.systemOrange
    static let coral = NSColor.systemRed

    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = white) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    static func symbol(_ name: String, size: CGFloat = 24, color: NSColor = white) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: name)
        image?.isTemplate = true
        let imageView = NSImageView(image: image ?? NSImage())
        imageView.contentTintColor = color
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        imageView.widthAnchor.constraint(equalToConstant: size + 4).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: size + 4).isActive = true
        return imageView
    }

    static func primaryButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        button.contentTintColor = NSColor.controlAccentColor
        return button
    }
}

final class ToolbarDashboardView: GradientPanelView {
    init(model: ToolbarDashboardModel) {
        super.init(cornerRadius: 18, borderAlpha: 0.10)
        frame = NSRect(x: 0, y: 0, width: 392, height: 184)

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView(image: model.icon ?? NSImage())
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(iconView)

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        titleStack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = StudioUI.label(model.title, size: 19, weight: .semibold)
        titleLabel.alignment = .left
        let emailLabel = StudioUI.label(model.email, size: 12, color: StudioUI.muted)
        emailLabel.alignment = .left
        titleStack.addArrangedSubview(titleLabel)
        titleStack.addArrangedSubview(emailLabel)
        header.addSubview(titleStack)

        let planLabel = StudioUI.label(model.status, size: 12, weight: .medium, color: StudioUI.muted)
        planLabel.alignment = .right
        planLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(planLabel)

        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 44),
            iconView.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),
            titleStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 14),
            titleStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: planLabel.leadingAnchor, constant: -14),
            planLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            planLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            planLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 86)
        ])
        root.addArrangedSubview(header)

        let divider = NSBox()
        divider.boxType = .separator
        root.addArrangedSubview(divider)

        let metrics = NSStackView()
        metrics.orientation = .horizontal
        metrics.alignment = .height
        metrics.distribution = .fillEqually
        metrics.spacing = 10
        metrics.addArrangedSubview(metricCard(title: "5hr", value: model.fiveHourPercent, detail: model.fiveHourReset))
        metrics.addArrangedSubview(metricCard(title: "Weekly", value: model.weeklyPercent, detail: model.weeklyReset))
        metrics.addArrangedSubview(metricCard(title: "Accounts", value: model.accountCount, detail: "saved"))
        root.addArrangedSubview(metrics)
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func metricCard(title: String, value: String, detail: String) -> NSView {
        let card = GlassCardView(cornerRadius: 10)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        let titleLabel = StudioUI.label(title, size: 11, weight: .medium, color: StudioUI.muted)
        let valueLabel = StudioUI.label(value, size: 18, weight: .semibold)
        let detailLabel = StudioUI.label(detail.isEmpty ? " " : detail, size: 12, color: StudioUI.muted)
        [titleLabel, valueLabel, detailLabel].forEach { label in
            label.alignment = .center
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(valueLabel)
        stack.addArrangedSubview(detailLabel)
        card.setContentHuggingPriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            card.heightAnchor.constraint(equalToConstant: 74)
        ])
        return card
    }
}

struct ManagedAppClone: Codable, Equatable {
    let id: UUID
    var index: Int
    var displayName: String
    var sourceAppPath: String
    var cloneAppPath: String
    var dataPath: String
    var bundleIdentifier: String
    var createdAt: Date
    var lastLaunchAt: Date?
    var lastPID: Int32?
    var lastHealthStatus: String?
    var lastHealthDetails: String?
    var lastHealthCheckedAt: Date?
}

struct CloneIdentityPlan {
    let bundleIdentifier: String
    let replacements: [(String, String)]
    let shouldPreserveEntitlements: Bool
    let executableName: String?
}

final class InstanceManagerStore {
    static let shared = InstanceManagerStore()

    private let clonesKey = "managedAppClones"
    private let selectedSourceKey = "instanceManagerSelectedSource"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let defaults: UserDefaults
    private let cloneRootOverride: URL?
    private let dataRootOverride: URL?

    init(defaults: UserDefaults = .standard, cloneRoot: URL? = nil, dataRoot: URL? = nil) {
        self.defaults = defaults
        self.cloneRootOverride = cloneRoot
        self.dataRootOverride = dataRoot
    }

    var cloneRoot: URL {
        if let cloneRootOverride {
            return cloneRootOverride
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Applications")
            .appendingPathComponent("Codex Account Switcher Clones")
    }

    var dataRoot: URL {
        if let dataRootOverride {
            return dataRootOverride
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Codex Account Switcher/Instances")
    }

    var defaultCodexAppURL: URL {
        URL(fileURLWithPath: "/Applications/Codex.app")
    }

    var selectedSourceURL: URL? {
        get {
            guard let path = defaults.string(forKey: selectedSourceKey), !path.isEmpty else {
                return FileManager.default.fileExists(atPath: defaultCodexAppURL.path) ? defaultCodexAppURL : nil
            }
            return URL(fileURLWithPath: path)
        }
        set {
            defaults.set(newValue?.path, forKey: selectedSourceKey)
        }
    }

    func loadClones() -> [ManagedAppClone] {
        guard let data = defaults.data(forKey: clonesKey),
              let clones = try? decoder.decode([ManagedAppClone].self, from: data) else {
            return []
        }
        return clones.sorted { $0.index < $1.index }
    }

    func saveClones(_ clones: [ManagedAppClone]) {
        guard let data = try? encoder.encode(clones.sorted(by: { $0.index < $1.index })) else { return }
        defaults.set(data, forKey: clonesKey)
    }
}

enum AppCloneError: LocalizedError {
    case invalidApp(URL)
    case missingInfoPlist(URL)
    case missingExecutable(URL)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidApp(let url):
            return "\(url.path) is not a readable .app bundle."
        case .missingInfoPlist(let url):
            return "Could not read Info.plist for \(url.lastPathComponent)."
        case .missingExecutable(let url):
            return "Could not find the executable for \(url.lastPathComponent)."
        case .commandFailed(let message):
            return message
        }
    }
}

final class AppCloneManager {
    private let store: InstanceManagerStore
    private let fileManager = FileManager.default

    init(store: InstanceManagerStore) {
        self.store = store
    }

    func createClones(
        sourceAppURL: URL,
        count: Int,
        customNamePrefix: String? = nil,
        iconURL: URL? = nil
    ) throws -> [ManagedAppClone] {
        let sourceURL = sourceAppURL.standardizedFileURL
        guard sourceURL.pathExtension == "app",
              fileManager.fileExists(atPath: sourceURL.path) else {
            throw AppCloneError.invalidApp(sourceURL)
        }

        try fileManager.createDirectory(at: store.cloneRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: store.dataRoot, withIntermediateDirectories: true)

        let info = try readInfoPlist(in: sourceURL)
        let sourceName = sourceURL.deletingPathExtension().lastPathComponent
        let sourceBundleID = info["CFBundleIdentifier"] as? String
        let baseBundleID = sanitizedBundleID(sourceBundleID ?? "local.\(sourceName)")
        let existing = store.loadClones()
        let retained = existing.filter { $0.sourceAppPath != sourceURL.path }
        let oldForSource = existing.filter { $0.sourceAppPath == sourceURL.path }
        let runningOldClones = oldForSource.filter(isCloneProcessRunning)
        if !runningOldClones.isEmpty {
            let names = runningOldClones.map(\.displayName).joined(separator: ", ")
            throw AppCloneError.commandFailed("Quit running clone(s) before rebuilding: \(names)")
        }

        for clone in oldForSource where clone.cloneAppPath.hasPrefix(store.cloneRoot.path) {
            try? fileManager.removeItem(atPath: clone.cloneAppPath)
        }

        var clones: [ManagedAppClone] = []
        for index in 1...max(1, min(12, count)) {
            let number = String(format: "%02d", index)
            let baseDisplayName = customNamePrefix?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = "\(safeDisplayName(baseDisplayName?.isEmpty == false ? baseDisplayName! : sourceName)) \(number)"
            let cloneURL = store.cloneRoot.appendingPathComponent("\(displayName).app")
            let dataURL = store.dataRoot.appendingPathComponent("\(safeFolderName(displayName))")
            let identityPlan = cloneIdentityPlan(
                sourceBundleIdentifier: sourceBundleID,
                fallbackBundleIdentifier: "\(baseBundleID).managedclone.\(number)",
                cloneIndex: index
            )
            let bundleID = identityPlan.bundleIdentifier

            if fileManager.fileExists(atPath: cloneURL.path) {
                try fileManager.removeItem(at: cloneURL)
            }
            try fileManager.copyItem(at: sourceURL, to: cloneURL)
            try prepareDataFolders(at: dataURL)
            let iconFileName = try installCustomIcon(iconURL, in: cloneURL)
            let executableName = try renameMainExecutableIfNeeded(in: cloneURL, to: identityPlan.executableName)
            try rewriteInfoPlist(
                in: cloneURL,
                displayName: displayName,
                bundleIdentifier: bundleID,
                iconFileName: iconFileName,
                executableName: executableName
            )
            try patchKnownSharedContainerIdentifiers(in: cloneURL, replacements: identityPlan.replacements)
            let entitlementsURL = identityPlan.shouldPreserveEntitlements
                ? try patchedEntitlementsURL(for: sourceURL, replacements: identityPlan.replacements, bundleIdentifier: bundleID)
                : nil
            try signAppIfPossible(cloneURL, entitlementsURL: entitlementsURL)
            removeExtendedAttributes(from: cloneURL)
            registerWithLaunchServices(cloneURL)

            clones.append(ManagedAppClone(
                id: UUID(),
                index: index,
                displayName: displayName,
                sourceAppPath: sourceURL.path,
                cloneAppPath: cloneURL.path,
                dataPath: dataURL.path,
                bundleIdentifier: bundleID,
                createdAt: Date(),
                lastLaunchAt: nil,
                lastPID: nil,
                lastHealthStatus: nil,
                lastHealthDetails: nil,
                lastHealthCheckedAt: nil
            ))
        }

        store.saveClones(retained + clones)
        store.selectedSourceURL = sourceURL
        return clones
    }

    func launch(_ clone: ManagedAppClone) throws -> ManagedAppClone {
        let cloneURL = URL(fileURLWithPath: clone.cloneAppPath)
        try prepareDataFolders(at: URL(fileURLWithPath: clone.dataPath))

        let pid: Int32
        if shouldUseElectronUserDataArgument(for: cloneURL) {
            let executableURL = try executableURL(for: cloneURL)
            let process = Process()
            process.executableURL = executableURL
            process.currentDirectoryURL = cloneURL.deletingLastPathComponent()
            process.arguments = launchArguments(for: clone, appURL: cloneURL)
            process.environment = launchEnvironment(for: clone, appURL: cloneURL)
            try process.run()
            pid = process.processIdentifier
        } else {
            do {
                pid = try launchNativeBundle(clone)
            } catch {
                pid = try launchDirectNativeExecutable(clone, appURL: cloneURL, launchServicesError: error)
            }
        }

        var updated = clone
        updated.lastLaunchAt = Date()
        updated.lastPID = pid
        replaceStoredClone(updated)
        return updated
    }

    func healthCheck(_ clone: ManagedAppClone) -> ManagedAppClone {
        var updated = clone
        let running = isCloneProcessRunning(clone)
        let issues = recentIssueLog(for: clone)
        if !issues.isEmpty {
            if issues.localizedCaseInsensitiveContains("another instance") {
                updated.lastHealthStatus = "Instance blocked"
            } else if issues.localizedCaseInsensitiveContains("restart before linking") {
                updated.lastHealthStatus = "Pairing blocked"
            } else if clone.bundleIdentifier.hasPrefix("net.whatsapp.WhatsA")
                && (issues.localizedCaseInsensitiveContains("wa_exit")
                    || issues.localizedCaseInsensitiveContains("WACurrentProcessType")
                    || issues.localizedCaseInsensitiveContains("BUG IN CLIENT OF LIBDISPATCH")) {
                updated.lastHealthStatus = "WhatsApp blocked"
            } else if issues.localizedCaseInsensitiveContains("shared container URL is nil") {
                updated.lastHealthStatus = "App-group issue"
            } else if issues.localizedCaseInsensitiveContains("database is locked") {
                updated.lastHealthStatus = "Data lock issue"
            } else if issues.localizedCaseInsensitiveContains("Code has restricted entitlements")
                || issues.localizedCaseInsensitiveContains("code signature validation failed")
                || issues.localizedCaseInsensitiveContains("AMFI") {
                updated.lastHealthStatus = "Signing blocked"
            } else {
                updated.lastHealthStatus = running ? "Issues found" : "Exited with issues"
            }
            updated.lastHealthDetails = issues
        } else if running {
            updated.lastHealthStatus = "Running clean"
            updated.lastHealthDetails = "No restart, app-group, signing, dyld, or data-lock messages found in recent logs."
        } else if clone.lastLaunchAt != nil {
            updated.lastHealthStatus = "Not running"
            updated.lastHealthDetails = "The clone is not currently running. Launch it again to collect fresh live diagnostics."
        } else {
            updated.lastHealthStatus = "Ready"
            updated.lastHealthDetails = "Launch the clone to start health monitoring."
        }
        updated.lastHealthCheckedAt = Date()
        replaceStoredClone(updated)
        return updated
    }

    func remove(_ clones: [ManagedAppClone], deleteData: Bool) {
        var stored = store.loadClones()
        let ids = Set(clones.map(\.id))
        for clone in clones {
            if clone.cloneAppPath.hasPrefix(store.cloneRoot.path) {
                try? fileManager.removeItem(atPath: clone.cloneAppPath)
            }
            if deleteData, clone.dataPath.hasPrefix(store.dataRoot.path) {
                try? fileManager.removeItem(atPath: clone.dataPath)
            }
        }
        stored.removeAll { ids.contains($0.id) }
        store.saveClones(stored)
    }

    func reveal(_ clone: ManagedAppClone) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: clone.cloneAppPath)])
    }

    func openDataFolder(_ clone: ManagedAppClone) {
        NSWorkspace.shared.open(URL(fileURLWithPath: clone.dataPath))
    }

    private func replaceStoredClone(_ clone: ManagedAppClone) {
        var stored = store.loadClones()
        if let index = stored.firstIndex(where: { $0.id == clone.id }) {
            stored[index] = clone
        }
        store.saveClones(stored)
    }

    private func isCloneProcessRunning(_ clone: ManagedAppClone) -> Bool {
        let escapedPath = NSRegularExpression.escapedPattern(for: clone.cloneAppPath)
        let result = runSync("/usr/bin/pgrep", ["-f", escapedPath])
        return result.status == 0
    }

    private func launchNativeBundle(_ clone: ManagedAppClone) throws -> Int32 {
        let result = runSync("/usr/bin/open", ["-n", clone.cloneAppPath])
        if result.status != 0 {
            throw AppCloneError.commandFailed(result.output)
        }

        for _ in 0..<30 {
            if let pid = runningPID(for: clone) {
                return pid
            }
            Thread.sleep(forTimeInterval: 0.15)
        }

        throw AppCloneError.commandFailed("\(clone.displayName) did not stay running after LaunchServices opened it.")
    }

    private func launchDirectNativeExecutable(_ clone: ManagedAppClone, appURL: URL, launchServicesError: Error) throws -> Int32 {
        let executableURL = try executableURL(for: appURL)
        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = appURL.deletingLastPathComponent()
        process.environment = launchEnvironment(for: clone, appURL: appURL)
        do {
            try process.run()
            Thread.sleep(forTimeInterval: 0.6)
            if kill(process.processIdentifier, 0) == 0 {
                return process.processIdentifier
            }
        } catch {
            throw AppCloneError.commandFailed("LaunchServices failed: \(launchServicesError.localizedDescription)\nDirect executable launch failed: \(error.localizedDescription)")
        }

        throw AppCloneError.commandFailed("LaunchServices failed: \(launchServicesError.localizedDescription)\nDirect executable launch exited immediately.")
    }

    private func runningPID(for clone: ManagedAppClone) -> Int32? {
        let escapedPath = NSRegularExpression.escapedPattern(for: clone.cloneAppPath)
        let result = runSync("/usr/bin/pgrep", ["-f", escapedPath])
        guard result.status == 0 else { return nil }
        return result.output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .first
    }

    private func launchArguments(for clone: ManagedAppClone, appURL: URL) -> [String] {
        guard shouldUseElectronUserDataArgument(for: appURL) else {
            return []
        }

        let dataURL = URL(fileURLWithPath: clone.dataPath)
        let userDataURL = dataURL.appendingPathComponent("electron-user-data")
        return [
            "--user-data-dir=\(userDataURL.path)",
            "--no-first-run"
        ]
    }

    private func launchEnvironment(for clone: ManagedAppClone, appURL: URL) -> [String: String] {
        let dataURL = URL(fileURLWithPath: clone.dataPath)
        let homeURL = dataURL.appendingPathComponent("home")
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_SWITCHER_INSTANCE_ID"] = clone.id.uuidString
        environment["CODEX_SWITCHER_INSTANCE_NAME"] = clone.displayName
        environment["CODEX_SWITCHER_REAL_HOME"] = NSHomeDirectory()
        environment["HOME"] = homeURL.path
        environment["CFFIXED_USER_HOME"] = homeURL.path
        environment["CODEX_HOME"] = dataURL.appendingPathComponent("codex-home").path
        environment["XDG_CONFIG_HOME"] = dataURL.appendingPathComponent("config").path
        environment["XDG_CACHE_HOME"] = dataURL.appendingPathComponent("cache").path
        environment["TMPDIR"] = dataURL.appendingPathComponent("tmp").path
        environment["PATH"] = augmentedPath(from: environment["PATH"])
        environment["NSUserDefaultsSuiteName"] = clone.bundleIdentifier
        environment["CFNETWORK_CACHE_PATH"] = homeURL.appendingPathComponent("Library/Caches/\(clone.bundleIdentifier)").path
        environment["WEBKIT_STORAGE_DIR"] = homeURL.appendingPathComponent("Library/WebKit/\(clone.bundleIdentifier)").path

        if shouldUseElectronUserDataArgument(for: appURL) {
            environment["CHROME_USER_DATA_DIR"] = dataURL.appendingPathComponent("electron-user-data").path
        }

        let bundledNode = "/Applications/Codex.app/Contents/Resources/node"
        if fileManager.isExecutableFile(atPath: bundledNode) {
            environment["CODEX_AUTH_NODE_EXECUTABLE"] = bundledNode
        }
        let bundledCodex = "/Applications/Codex.app/Contents/Resources/codex"
        if fileManager.isExecutableFile(atPath: bundledCodex) {
            environment["CODEX_CLI_PATH"] = bundledCodex
        }
        return environment
    }

    private func shouldUseElectronUserDataArgument(for appURL: URL) -> Bool {
        let frameworkURL = appURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        let asarURL = appURL.appendingPathComponent("Contents/Resources/app.asar")
        if fileManager.fileExists(atPath: frameworkURL.path) || fileManager.fileExists(atPath: asarURL.path) {
            return true
        }

        let lowerName = appURL.deletingPathExtension().lastPathComponent.lowercased()
        return lowerName.contains("codex") || lowerName.contains("electron")
    }

    private func cloneIdentityPlan(sourceBundleIdentifier: String?, fallbackBundleIdentifier: String, cloneIndex: Int) -> CloneIdentityPlan {
        let suffix = String(format: "%02d", cloneIndex)

        switch sourceBundleIdentifier {
        case "ru.keepcoder.Telegram":
            return CloneIdentityPlan(
                bundleIdentifier: "ru.keepcoder.Telegr\(suffix)",
                replacements: [
                    ("6N38VWS5BX.ru.keepcoder.Telegram.TelegramShare", "6N38VWS5BX.ru.keepcoder.Telegr\(suffix).TelegramShare"),
                    ("6N38VWS5BX.ru.keepcoder.Telegram.FocusIntents", "6N38VWS5BX.ru.keepcoder.Telegr\(suffix).FocusIntents"),
                    ("6N38VWS5BX.ru.keepcoder.Telegram", "6N38VWS5BX.ru.keepcoder.Telegr\(suffix)"),
                    ("ru.keepcoder.Telegram.TelegramShare", "ru.keepcoder.Telegr\(suffix).TelegramShare"),
                    ("ru.keepcoder.Telegram", "ru.keepcoder.Telegr\(suffix)")
                ],
                shouldPreserveEntitlements: true,
                executableName: nil
            )
        case "net.whatsapp.WhatsApp":
            return CloneIdentityPlan(
                bundleIdentifier: "net.whatsapp.WhatsA\(suffix)",
                replacements: [
                    ("group.net.whatsapp.WhatsAppSMB.shared", "group.net.whatsapp.WhatsA\(suffix)SMB.shared"),
                    ("group.net.whatsapp.WhatsApp.private", "group.net.whatsapp.WhatsA\(suffix).private"),
                    ("group.net.whatsapp.WhatsApp.shared", "group.net.whatsapp.WhatsA\(suffix).shared"),
                    ("group.net.whatsapp.family", "group.net.whatsapp.fami\(suffix)"),
                    ("group.com.facebook.family", "group.com.facebook.fami\(suffix)"),
                    ("UKFA9XBX6K.net.whatsapp.WhatsApp", "UKFA9XBX6K.net.whatsapp.WhatsA\(suffix)"),
                    ("57T9237FN3.net.whatsapp.WhatsApp", "57T9237FN3.net.whatsapp.WhatsA\(suffix)"),
                    ("iCloud.net.whatsapp.WhatsApp", "iCloud.net.whatsapp.WhatsA\(suffix)"),
                    ("net.whatsapp.WhatsApp", "net.whatsapp.WhatsA\(suffix)")
                ],
                shouldPreserveEntitlements: false,
                executableName: "WhatsApp\(suffix)"
            )
        default:
            return CloneIdentityPlan(
                bundleIdentifier: fallbackBundleIdentifier,
                replacements: [],
                shouldPreserveEntitlements: true,
                executableName: nil
            )
        }
    }

    private func patchKnownSharedContainerIdentifiers(in appURL: URL, replacements: [(String, String)]) throws {
        guard !replacements.isEmpty else { return }
        let sortedReplacements = replacements.sorted { $0.0.count > $1.0.count }
        for (original, replacement) in sortedReplacements {
            guard original.utf8.count == replacement.utf8.count else {
                throw AppCloneError.commandFailed("Internal replacement length mismatch for \(original).")
            }
        }

        guard let enumerator = fileManager.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= 512 * 1024 * 1024 else { continue }
            var data = try Data(contentsOf: fileURL)
            var changed = false
            for (original, replacement) in sortedReplacements {
                changed = replaceAll(original: Array(original.utf8), replacement: Array(replacement.utf8), in: &data) || changed
            }
            if changed {
                try data.write(to: fileURL, options: .atomic)
            }
        }
    }

    private func patchedEntitlementsURL(for sourceURL: URL, replacements: [(String, String)], bundleIdentifier: String) throws -> URL? {
        guard let entitlementData = extractEntitlementsData(from: sourceURL),
              let object = try? PropertyListSerialization.propertyList(from: entitlementData, options: [], format: nil) else {
            return nil
        }

        var normalizedReplacements = replacements
        if let sourceBundleIdentifier = try? readInfoPlist(in: sourceURL)["CFBundleIdentifier"] as? String,
           sourceBundleIdentifier != bundleIdentifier {
            normalizedReplacements.append((sourceBundleIdentifier, bundleIdentifier))
        }

        let patched = patchPropertyListStrings(object, replacements: normalizedReplacements)
        let data = try PropertyListSerialization.data(fromPropertyList: patched, format: .xml, options: 0)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-switcher-\(UUID().uuidString).entitlements")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func extractEntitlementsData(from appURL: URL) -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "--entitlements", ":-", appURL.path]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, !data.isEmpty else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private func patchPropertyListStrings(_ value: Any, replacements: [(String, String)]) -> Any {
        if let string = value as? String {
            return replacements.reduce(string) { result, pair in
                result.replacingOccurrences(of: pair.0, with: pair.1)
            }
        }
        if let array = value as? [Any] {
            return array.map { patchPropertyListStrings($0, replacements: replacements) }
        }
        if let dictionary = value as? [String: Any] {
            var patched: [String: Any] = [:]
            for (key, item) in dictionary {
                patched[key] = patchPropertyListStrings(item, replacements: replacements)
            }
            return patched
        }
        return value
    }

    private func replaceAll(original: [UInt8], replacement: [UInt8], in data: inout Data) -> Bool {
        guard original.count == replacement.count, !original.isEmpty else { return false }
        let originalData = Data(original)
        let replacementData = Data(replacement)
        var changed = false
        var searchRange = data.startIndex..<data.endIndex
        while let range = data.range(of: originalData, options: [], in: searchRange) {
            data.replaceSubrange(range, with: replacementData)
            changed = true
            searchRange = range.upperBound..<data.endIndex
        }
        return changed
    }

    private func augmentedPath(from currentPath: String?) -> String {
        let realHome = NSHomeDirectory()
        let candidates = [
            "/Applications/Codex.app/Contents/Resources",
            "\(realHome)/.nvm/versions/node/v20.11.0/bin",
            "\(realHome)/.local/bin",
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

    private func prepareDataFolders(at dataURL: URL) throws {
        let folders = [
            ["home"],
            ["home", "Library"],
            ["home", "Library", "Application Support"],
            ["home", "Library", "Application Scripts"],
            ["home", "Library", "Caches"],
            ["home", "Library", "Containers"],
            ["home", "Library", "Group Containers"],
            ["home", "Library", "HTTPStorages"],
            ["home", "Library", "Preferences"],
            ["home", "Library", "Saved Application State"],
            ["home", "Library", "WebKit"],
            ["home", "Desktop"],
            ["home", "Documents"],
            ["home", "Downloads"],
            ["codex-home"],
            ["config"],
            ["cache"],
            ["tmp"],
            ["electron-user-data"]
        ]

        for components in folders {
            let folderURL = components.reduce(dataURL) { partial, component in
                partial.appendingPathComponent(component)
            }
            try fileManager.createDirectory(
                at: folderURL,
                withIntermediateDirectories: true
            )
        }
    }

    private func readInfoPlist(in appURL: URL) throws -> [String: Any] {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = object as? [String: Any] else {
            throw AppCloneError.missingInfoPlist(appURL)
        }
        return plist
    }

    private func installCustomIcon(_ iconURL: URL?, in appURL: URL) throws -> String? {
        guard let iconURL else { return nil }
        let ext = iconURL.pathExtension.lowercased()
        guard ["png", "icns"].contains(ext) else {
            throw AppCloneError.commandFailed("Choose a .png or .icns icon file.")
        }
        let resourcesURL = appURL.appendingPathComponent("Contents/Resources")
        try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        let fileName = "CloneIcon.\(ext)"
        let targetURL = resourcesURL.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
        try fileManager.copyItem(at: iconURL, to: targetURL)
        return fileName
    }

    private func renameMainExecutableIfNeeded(in appURL: URL, to executableName: String?) throws -> String? {
        guard let executableName, !executableName.isEmpty else { return nil }
        let currentURL = try executableURL(for: appURL)
        guard currentURL.lastPathComponent != executableName else { return executableName }
        let renamedURL = currentURL.deletingLastPathComponent().appendingPathComponent(executableName)
        if fileManager.fileExists(atPath: renamedURL.path) {
            try fileManager.removeItem(at: renamedURL)
        }
        try fileManager.moveItem(at: currentURL, to: renamedURL)
        return executableName
    }

    private func rewriteInfoPlist(
        in appURL: URL,
        displayName: String,
        bundleIdentifier: String,
        iconFileName: String?,
        executableName: String?
    ) throws {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        var plist = try readInfoPlist(in: appURL)
        plist["CFBundleIdentifier"] = bundleIdentifier
        plist["CFBundleName"] = displayName
        plist["CFBundleDisplayName"] = displayName
        if let executableName {
            plist["CFBundleExecutable"] = executableName
        }
        if let iconFileName {
            plist["CFBundleIconFile"] = iconFileName
            plist["CFBundleIconName"] = nil
            plist["CFBundleIcons"] = nil
        }
        plist["LSMultipleInstancesProhibited"] = false
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    private func executableURL(for appURL: URL) throws -> URL {
        let info = try readInfoPlist(in: appURL)
        guard let executableName = info["CFBundleExecutable"] as? String, !executableName.isEmpty else {
            throw AppCloneError.missingExecutable(appURL)
        }
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/\(executableName)")
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw AppCloneError.missingExecutable(appURL)
        }
        return executableURL
    }

    private func signAppIfPossible(_ appURL: URL, entitlementsURL: URL?) throws {
        guard fileManager.isExecutableFile(atPath: "/usr/bin/codesign") else { return }
        let deepArguments = entitlementsURL == nil
            ? ["--force", "--deep", "--sign", "-", appURL.path]
            : ["--force", "--deep", "--sign", "-", "--options", "runtime", appURL.path]
        let deepResult = runSync("/usr/bin/codesign", deepArguments)
        if deepResult.status != 0 {
            throw AppCloneError.commandFailed("Signing \(appURL.lastPathComponent) failed:\n\(deepResult.output)")
        }

        guard let entitlementsURL else { return }
        var arguments = ["--force", "--sign", "-", "--options", "runtime"]
        arguments += ["--entitlements", entitlementsURL.path]
        arguments.append(appURL.path)
        let result = runSync("/usr/bin/codesign", arguments)
        try? fileManager.removeItem(at: entitlementsURL)
        if result.status != 0 {
            throw AppCloneError.commandFailed("Signing \(appURL.lastPathComponent) failed:\n\(result.output)")
        }
    }

    private func recentIssueLog(for clone: ManagedAppClone) -> String {
        let appURL = URL(fileURLWithPath: clone.cloneAppPath)
        let executableName = (try? readInfoPlist(in: appURL)["CFBundleExecutable"] as? String) ?? appURL.deletingPathExtension().lastPathComponent
        let processPredicate = clone.lastPID.map { "processID == \($0)" } ?? "process == \"\(executableName)\""
        let predicate = """
        process != "log" AND (\(processPredicate) OR eventMessage CONTAINS[c] "\(clone.bundleIdentifier)" OR eventMessage CONTAINS[c] "\(appURL.lastPathComponent)") AND (eventMessage CONTAINS[c] "another instance" OR eventMessage CONTAINS[c] "restart before linking" OR eventMessage CONTAINS[c] "shared container URL is nil" OR eventMessage CONTAINS[c] "database is locked" OR eventMessage CONTAINS[c] "Library not loaded" OR eventMessage CONTAINS[c] "Code has restricted entitlements" OR eventMessage CONTAINS[c] "code signature validation failed" OR eventMessage CONTAINS[c] "Launch failed" OR eventMessage CONTAINS[c] "Unsatisfied Entitlements" OR eventMessage CONTAINS[c] "AMFI" OR eventMessage CONTAINS[c] "dyld")
        """
        let result = runSync("/usr/bin/log", ["show", "--last", "3m", "--style", "compact", "--predicate", predicate])
        guard result.status == 0 else {
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let lines = result.output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.contains(" log[") && !$0.contains("log show") }
            .filter { !$0.localizedCaseInsensitiveContains(" is adhoc signed") }
            .suffix(16)
        let logIssues = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let crashIssues = recentDiagnosticReport(for: executableName)
        return [logIssues, crashIssues]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func recentDiagnosticReport(for executableName: String) -> String {
        let reportsURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let reports = try? fileManager.contentsOfDirectory(
            at: reportsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ""
        }

        let cutoff = Date().addingTimeInterval(-5 * 60)
        let newestReport = reports
            .filter { $0.lastPathComponent.hasPrefix("\(executableName)-") && $0.pathExtension == "ips" }
            .compactMap { url -> (URL, Date)? in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return date >= cutoff ? (url, date) : nil
            }
            .sorted { $0.1 > $1.1 }
            .first?.0

        guard let newestReport,
              let text = try? String(contentsOf: newestReport, encoding: .utf8) else {
            return ""
        }

        let interesting = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter {
                $0.contains("\"exception\"")
                    || $0.contains("\"termination\"")
                    || $0.contains("\"asi\"")
                    || $0.contains("\"procName\"")
                    || $0.contains("WACurrentProcessType")
                    || $0.contains("wa_exit")
                    || $0.contains("BUG IN CLIENT OF LIBDISPATCH")
            }
            .prefix(12)
        guard !interesting.isEmpty else { return "" }
        return "Crash report: \(newestReport.lastPathComponent)\n\(interesting.joined(separator: "\n"))"
    }

    private func registerWithLaunchServices(_ appURL: URL) {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
        guard fileManager.isExecutableFile(atPath: lsregister) else { return }
        _ = runSync(lsregister, ["-f", appURL.path])
    }

    private func removeExtendedAttributes(from appURL: URL) {
        guard fileManager.isExecutableFile(atPath: "/usr/bin/xattr") else { return }
        _ = runSync("/usr/bin/xattr", ["-cr", appURL.path])
    }

    private func runSync(_ executable: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(
                status: process.terminationStatus,
                output: String(data: data, encoding: .utf8) ?? ""
            )
        } catch {
            return CommandResult(status: 127, output: error.localizedDescription)
        }
    }

    private func sanitizedBundleID(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        let cleaned = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let result = String(cleaned)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
            .lowercased()
        return result.contains(".") ? result : "local.\(result.isEmpty ? "app" : result)"
    }

    private func safeFolderName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func safeDisplayName(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:")
        let cleaned = value.unicodeScalars.map { forbidden.contains($0) ? Character("-") : Character($0) }
        return String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class InstanceManagerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store = InstanceManagerStore.shared
    private lazy var manager = AppCloneManager(store: store)
    private var clones: [ManagedAppClone] = []
    private var healthTimer: Timer?
    private var selectedIconURL: URL? {
        didSet {
            iconPathField.stringValue = selectedIconURL?.path ?? "Default source app icon"
        }
    }
    private var sourceURL: URL? {
        didSet {
            store.selectedSourceURL = sourceURL
            sourcePathField.stringValue = sourceURL?.path ?? "Choose an app bundle"
        }
    }

    private let sourcePathField = NSTextField(labelWithString: "")
    private let cloneNameField = NSTextField(string: "")
    private let iconPathField = NSTextField(labelWithString: "Default source app icon")
    private let cloneCountField = NSTextField(string: "6")
    private let cloneCountStepper = NSStepper()
    private let tableView = NSTableView()
    private let logTextView = NSTextView()
    private let progress = NSProgressIndicator()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Account Switcher"
        window.minSize = NSSize(width: 780, height: 520)
        super.init(window: window)
        window.center()
        buildInterface()
        sourceURL = store.selectedSourceURL
        reloadClones()
        startHealthMonitoring()
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        healthTimer?.invalidate()
    }

    private func buildInterface() {
        guard let window else { return }
        let background = GradientPanelView(cornerRadius: 0, borderAlpha: 0)
        window.contentView = background
        let contentView = background

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 26, left: 26, bottom: 24, right: 26)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 16
        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.spacing = 5
        titleStack.addArrangedSubview(StudioUI.label("Instance Manager", size: 28, weight: .semibold))
        titleStack.addArrangedSubview(StudioUI.label("Create and inspect isolated app clones.", size: 13, color: StudioUI.muted))
        header.addArrangedSubview(titleStack)
        let headerSpacer = NSView()
        header.addArrangedSubview(headerSpacer)
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let healthBadge = GlassCardView(cornerRadius: 18)
        let badgeStack = NSStackView()
        badgeStack.orientation = .horizontal
        badgeStack.alignment = .centerY
        badgeStack.spacing = 8
        badgeStack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        badgeStack.translatesAutoresizingMaskIntoConstraints = false
        healthBadge.addSubview(badgeStack)
        badgeStack.addArrangedSubview(StudioUI.symbol("waveform.path.ecg", size: 20, color: StudioUI.lime))
        badgeStack.addArrangedSubview(StudioUI.label("Health: Live", size: 13, weight: .medium, color: StudioUI.lime))
        NSLayoutConstraint.activate([
            badgeStack.leadingAnchor.constraint(equalTo: healthBadge.leadingAnchor),
            badgeStack.trailingAnchor.constraint(equalTo: healthBadge.trailingAnchor),
            badgeStack.topAnchor.constraint(equalTo: healthBadge.topAnchor),
            badgeStack.bottomAnchor.constraint(equalTo: healthBadge.bottomAnchor)
        ])
        header.addArrangedSubview(healthBadge)
        root.addArrangedSubview(header)

        let controlsCard = GlassCardView(cornerRadius: 22)
        let controlsStack = NSStackView()
        controlsStack.orientation = .vertical
        controlsStack.spacing = 12
        controlsStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        controlsCard.addSubview(controlsStack)
        NSLayoutConstraint.activate([
            controlsStack.leadingAnchor.constraint(equalTo: controlsCard.leadingAnchor),
            controlsStack.trailingAnchor.constraint(equalTo: controlsCard.trailingAnchor),
            controlsStack.topAnchor.constraint(equalTo: controlsCard.topAnchor),
            controlsStack.bottomAnchor.constraint(equalTo: controlsCard.bottomAnchor)
        ])
        root.addArrangedSubview(controlsCard)

        let sourceRow = NSStackView()
        sourceRow.orientation = .horizontal
        sourceRow.alignment = .centerY
        sourceRow.spacing = 10
        sourceRow.addArrangedSubview(label("Source"))
        sourcePathField.lineBreakMode = .byTruncatingMiddle
        sourcePathField.textColor = StudioUI.muted
        sourcePathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sourceRow.addArrangedSubview(sourcePathField)
        sourceRow.addArrangedSubview(button("Choose", #selector(chooseSourceApp)))
        sourceRow.addArrangedSubview(button("Use Codex", #selector(useCodexApp)))
        controlsStack.addArrangedSubview(sourceRow)

        let customizeRow = NSStackView()
        customizeRow.orientation = .horizontal
        customizeRow.alignment = .centerY
        customizeRow.spacing = 10
        customizeRow.addArrangedSubview(label("Name"))
        cloneNameField.placeholderString = "Use source app name"
        styleInput(cloneNameField)
        cloneNameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        customizeRow.addArrangedSubview(cloneNameField)
        customizeRow.addArrangedSubview(label("Icon"))
        iconPathField.lineBreakMode = .byTruncatingMiddle
        iconPathField.textColor = StudioUI.muted
        iconPathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        customizeRow.addArrangedSubview(iconPathField)
        customizeRow.addArrangedSubview(button("Icon", #selector(chooseIcon)))
        customizeRow.addArrangedSubview(button("Clear Icon", #selector(clearIcon)))
        controlsStack.addArrangedSubview(customizeRow)

        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 10
        actionRow.addArrangedSubview(label("Clones"))
        cloneCountField.alignment = .center
        cloneCountField.maximumNumberOfLines = 1
        styleInput(cloneCountField)
        cloneCountField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        actionRow.addArrangedSubview(cloneCountField)
        cloneCountStepper.minValue = 1
        cloneCountStepper.maxValue = 12
        cloneCountStepper.integerValue = 6
        cloneCountStepper.target = self
        cloneCountStepper.action = #selector(stepperChanged)
        actionRow.addArrangedSubview(cloneCountStepper)
        actionRow.addArrangedSubview(button("Create/Rebuild", #selector(createClones)))
        actionRow.addArrangedSubview(button("Run Selected", #selector(runSelected)))
        actionRow.addArrangedSubview(button("Run All", #selector(runAll)))
        actionRow.addArrangedSubview(button("Health Check", #selector(healthCheckSelected)))
        actionRow.addArrangedSubview(button("Reveal", #selector(revealSelected)))
        actionRow.addArrangedSubview(button("Open Data", #selector(openSelectedData)))
        actionRow.addArrangedSubview(button("Remove", #selector(removeSelected)))
        actionRow.addArrangedSubview(button("Refresh", #selector(refreshClicked)))
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        actionRow.addArrangedSubview(progress)
        controlsStack.addArrangedSubview(actionRow)

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = tableView
        tableView.backgroundColor = .clear
        tableView.gridColor = NSColor.black.withAlphaComponent(0.08)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = true
        tableView.delegate = self
        tableView.dataSource = self
        addColumn("index", "#", 48)
        addColumn("name", "Clone", 170)
        addColumn("bundle", "Identity", 230)
        addColumn("data", "Data", 270)
        addColumn("status", "Status", 135)
        addColumn("health", "Health", 180)
        let tableCard = GlassCardView(cornerRadius: 22)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        tableCard.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: tableCard.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: tableCard.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: tableCard.topAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: tableCard.bottomAnchor, constant: -12)
        ])
        root.addArrangedSubview(tableCard)
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 286).isActive = true

        let logScroll = NSScrollView()
        logScroll.borderType = .noBorder
        logScroll.drawsBackground = false
        logScroll.hasVerticalScroller = true
        logScroll.documentView = logTextView
        logTextView.isEditable = false
        logTextView.backgroundColor = NSColor.white.withAlphaComponent(0.78)
        logTextView.textColor = StudioUI.ink
        logTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        logTextView.string = "Live health log ready."
        root.addArrangedSubview(logScroll)
        logScroll.heightAnchor.constraint(equalToConstant: 128).isActive = true
    }

    private func addColumn(_ identifier: String, _ title: String, _ width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        tableView.addTableColumn(column)
    }

    private func label(_ value: String) -> NSTextField {
        StudioUI.label(value, size: 13, weight: .semibold)
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        StudioUI.primaryButton(title, target: self, action: action)
    }

    private func styleInput(_ field: NSTextField) {
        field.isBezeled = true
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.white.withAlphaComponent(0.86)
        field.textColor = StudioUI.ink
        field.font = NSFont.systemFont(ofSize: 13, weight: .medium)
    }

    private func reloadClones() {
        clones = store.loadClones()
        tableView.reloadData()
    }

    @objc private func stepperChanged() {
        cloneCountField.stringValue = "\(cloneCountStepper.integerValue)"
    }

    @objc private func chooseSourceApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose app bundle"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            sourceURL = panel.url
        }
    }

    @objc private func useCodexApp() {
        sourceURL = store.defaultCodexAppURL
    }

    @objc private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.title = "Choose clone icon"
        var types: [UTType] = [.png]
        if let icns = UTType(filenameExtension: "icns") {
            types.append(icns)
        }
        panel.allowedContentTypes = types
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            selectedIconURL = panel.url
        }
    }

    @objc private func clearIcon() {
        selectedIconURL = nil
    }

    @objc private func createClones() {
        guard let sourceURL else {
            showError("Choose an app bundle first.")
            return
        }
        let count = max(1, min(12, Int(cloneCountField.stringValue) ?? cloneCountStepper.integerValue))
        let customNamePrefix = cloneNameField.stringValue
        let iconURL = selectedIconURL
        setBusy(true)
        appendLog("Creating \(count) clone(s) from \(sourceURL.lastPathComponent)...")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let newClones = try self.manager.createClones(
                    sourceAppURL: sourceURL,
                    count: count,
                    customNamePrefix: customNamePrefix,
                    iconURL: iconURL
                )
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.reloadClones()
                    self.appendLog("Created \(newClones.count) isolated clone(s).")
                }
            } catch {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    @objc private func runSelected() {
        let selected = selectedClones()
        guard !selected.isEmpty else {
            showError("Select at least one clone to run.")
            return
        }
        launch(selected)
    }

    @objc private func runAll() {
        guard !clones.isEmpty else {
            showError("Create clones first.")
            return
        }
        launch(clones)
    }

    @objc private func healthCheckSelected() {
        let selected = selectedClones()
        guard !selected.isEmpty else {
            showError("Select at least one clone to inspect.")
            return
        }
        runHealthChecks(for: selected, reason: "Manual health check")
    }

    @objc private func revealSelected() {
        guard let clone = selectedClones().first else { return }
        manager.reveal(clone)
    }

    @objc private func openSelectedData() {
        guard let clone = selectedClones().first else { return }
        manager.openDataFolder(clone)
    }

    @objc private func removeSelected() {
        let selected = selectedClones()
        guard !selected.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Remove selected clone(s)?"
        alert.informativeText = "The app bundle clone will be removed. Choose whether to also delete the isolated data folder."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove App Only")
        alert.addButton(withTitle: "Remove App + Data")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
        manager.remove(selected, deleteData: response == .alertSecondButtonReturn)
        reloadClones()
        appendLog("Removed \(selected.count) clone(s).")
    }

    @objc private func refreshClicked() {
        reloadClones()
        appendLog("Refreshed clone list.")
    }

    private func launch(_ launchClones: [ManagedAppClone]) {
        setBusy(true)
        appendLog("Launching \(launchClones.count) clone(s)...")
        DispatchQueue.global(qos: .userInitiated).async {
            var launched = 0
            var failures: [String] = []
            for clone in launchClones {
                do {
                    _ = try self.manager.launch(clone)
                    launched += 1
                } catch {
                    failures.append("\(clone.displayName): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                self.setBusy(false)
                self.reloadClones()
                if failures.isEmpty {
                    self.appendLog("Launched \(launched) clone(s).")
                } else {
                    self.appendLog("Launched \(launched), failed \(failures.count).\n\(failures.joined(separator: "\n"))")
                }
                self.runHealthChecks(for: launchClones, reason: "Post-launch health check")
            }
        }
    }

    private func startHealthMonitoring() {
        healthTimer?.invalidate()
        let timer = Timer(timeInterval: 6, repeats: true) { [weak self] _ in
            guard let self else { return }
            let running = self.clones.filter { clone in
                if let pid = clone.lastPID, kill(pid, 0) == 0 {
                    return true
                }
                return false
            }
            if !running.isEmpty {
                self.runHealthChecks(for: running, reason: "Live health monitor", silentWhenClean: true)
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        healthTimer = timer
    }

    private func runHealthChecks(for checkClones: [ManagedAppClone], reason: String, silentWhenClean: Bool = false) {
        DispatchQueue.global(qos: .utility).async {
            let checked = checkClones.map { self.manager.healthCheck($0) }
            DispatchQueue.main.async {
                self.reloadClones()
                for clone in checked {
                    let status = clone.lastHealthStatus ?? "Unknown"
                    let details = clone.lastHealthDetails ?? ""
                    if silentWhenClean && status == "Running clean" { continue }
                    let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.appendLog("\(reason): \(clone.displayName) · \(status)\(trimmed.isEmpty ? "" : "\n\(trimmed)")")
                }
            }
        }
    }

    private func selectedClones() -> [ManagedAppClone] {
        tableView.selectedRowIndexes.compactMap { index in
            guard index >= 0 && index < clones.count else { return nil }
            return clones[index]
        }
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        let line = "[\(formatter.string(from: Date()))] \(message)"
        logTextView.string = logTextView.string.isEmpty ? line : "\(logTextView.string)\n\(line)"
        logTextView.scrollToEndOfDocument(nil)
    }

    private func setBusy(_ busy: Bool) {
        busy ? progress.startAnimation(nil) : progress.stopAnimation(nil)
    }

    private func showError(_ message: String) {
        appendLog("Error: \(message)")
        let alert = NSAlert()
        alert.messageText = "Instance Manager"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        clones.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < clones.count, let tableColumn else { return nil }
        let clone = clones[row]
        let value: String
        switch tableColumn.identifier.rawValue {
        case "index":
            value = String(format: "%02d", clone.index)
        case "name":
            value = clone.displayName
        case "bundle":
            value = clone.bundleIdentifier
        case "data":
            value = clone.dataPath
        case "status":
            value = statusText(for: clone)
        case "health":
            value = clone.lastHealthStatus ?? "Not checked"
        default:
            value = ""
        }

        let identifier = NSUserInterfaceItemIdentifier("cell-\(tableColumn.identifier.rawValue)")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        let textField = cell.textField ?? NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingMiddle
        textField.translatesAutoresizingMaskIntoConstraints = false
        if textField.superview == nil {
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        if tableColumn.identifier.rawValue == "health" {
            let health = clone.lastHealthStatus ?? ""
            textField.textColor = health.contains("Issue") || health.contains("Exited") ? StudioUI.coral : StudioUI.lime
        } else {
            textField.textColor = tableColumn.identifier.rawValue == "status" ? StudioUI.muted : StudioUI.ink
        }
        textField.font = NSFont.systemFont(ofSize: 12.5, weight: tableColumn.identifier.rawValue == "name" ? .semibold : .regular)
        textField.stringValue = value
        return cell
    }

    private func statusText(for clone: ManagedAppClone) -> String {
        if let pid = clone.lastPID, kill(pid, 0) == 0 {
            return "Running \(pid)"
        }
        if clone.lastLaunchAt != nil {
            return "Last launched"
        }
        return "Ready"
    }
}

private func runCloneSmokeTest(arguments: [String]) -> Int32 {
    guard let sourceFlagIndex = arguments.firstIndex(of: "--source"),
          sourceFlagIndex + 1 < arguments.count else {
        fputs("usage: CodexAccountSwitcher --clone-smoke-test --source /Applications/App.app [--count 2] [--launch]\n", stderr)
        return 64
    }

    let sourceURL = URL(fileURLWithPath: arguments[sourceFlagIndex + 1])
    let count: Int
    if let countFlagIndex = arguments.firstIndex(of: "--count"),
       countFlagIndex + 1 < arguments.count,
       let parsed = Int(arguments[countFlagIndex + 1]) {
        count = parsed
    } else {
        count = 2
    }

    let launch = arguments.contains("--launch")
    let keepRunning = arguments.contains("--keep-running")
    let persistent = arguments.contains("--persistent")
    let testID = UUID().uuidString
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("CodexAccountSwitcherSmokeTests")
        .appendingPathComponent(testID)
    let defaults = UserDefaults(suiteName: "com.mohamedfuad.codexaccountswitcher.smoketest.\(testID)") ?? .standard
    let store = persistent
        ? InstanceManagerStore.shared
        : InstanceManagerStore(
            defaults: defaults,
            cloneRoot: rootURL.appendingPathComponent("Clones"),
            dataRoot: rootURL.appendingPathComponent("Data")
        )
    let manager = AppCloneManager(store: store)

    do {
        let clones = try manager.createClones(sourceAppURL: sourceURL, count: count)
        print("created=\(clones.count)")
        for clone in clones {
            print("clone=\(clone.displayName)")
            print("bundle=\(clone.bundleIdentifier)")
            print("app=\(clone.cloneAppPath)")
            print("data=\(clone.dataPath)")
        }

        if launch {
            for clone in clones {
                let launched = try manager.launch(clone)
                print("launched=\(launched.displayName) pid=\(launched.lastPID ?? 0)")
                if !keepRunning {
                    Thread.sleep(forTimeInterval: 4)
                    if let pid = launched.lastPID {
                        kill(pid, SIGTERM)
                        Thread.sleep(forTimeInterval: 1)
                        if kill(pid, 0) == 0 {
                            kill(pid, SIGKILL)
                        }
                    }
                }
            }
        }

        print("root=\(persistent ? store.cloneRoot.path : rootURL.path)")
        return 0
    } catch {
        fputs("error: \(error.localizedDescription)\n", stderr)
        return 1
    }
}

if CommandLine.arguments.contains("--clone-smoke-test") {
    exit(runCloneSmokeTest(arguments: CommandLine.arguments))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
