import AppKit
import Darwin
import Foundation
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
    private var instanceManagerWindowController: InstanceManagerWindowController?
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
            menu.addItem(headerItem("Active: \(active.email) (\(displayPlan(active.plan)))"))
        } else {
            if !isSwitching {
                statusItem.button?.title = ""
            }
            menu.addItem(headerItem(lastError ?? "No active account"))
        }

        menu.addItem(.separator())

        if let active = accounts.first(where: { $0.isActive }) {
            let usageHeader = headerItem("Usage remaining")
            usageHeader.image = NSImage(systemSymbolName: "gauge.with.dots.needle.bottom.50percent", accessibilityDescription: "Usage remaining")
            menu.addItem(usageHeader)
            menu.addItem(usageModeItem(
                title: "5hr",
                percent: remainingPercentText(fromUsed: active.fiveHourUsedPercent),
                reset: resetTimeText(from: active.fiveHourUsage),
                mode: .fiveHour
            ))
            menu.addItem(usageModeItem(
                title: "Weekly",
                percent: remainingPercentText(fromUsed: active.weeklyUsedPercent),
                reset: resetDateText(from: active.weeklyUsage),
                mode: .weekly
            ))
            menu.addItem(.separator())
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

        let instanceManager = NSMenuItem(title: "Open Instance Manager", action: #selector(openInstanceManager), keyEquivalent: "i")
        instanceManager.target = self
        menu.addItem(instanceManager)

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

    @objc private func openInstanceManager() {
        if instanceManagerWindowController == nil {
            instanceManagerWindowController = InstanceManagerWindowController()
        }
        instanceManagerWindowController?.showWindow(self)
        NSApp.activate(ignoringOtherApps: true)
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

        transcript.append("Opening Codex App through codex-auth...")
        let appResult = runCodexAuth(["app", "--platform", "mac"])
        if appResult.status != 0 {
            transcript.append("codex-auth app failed; falling back to open -a Codex.")
            let openResult = run("/usr/bin/open", ["-a", "Codex"])
            if openResult.status != 0 {
                return CommandResult(status: openResult.status, output: transcript.joined(separator: "\n") + "\n" + openResult.output)
            }
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
}

final class InstanceManagerStore {
    static let shared = InstanceManagerStore()

    private let clonesKey = "managedAppClones"
    private let selectedSourceKey = "instanceManagerSelectedSource"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    var cloneRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Applications")
            .appendingPathComponent("Codex Account Switcher Clones")
    }

    var dataRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Codex Account Switcher/Instances")
    }

    var defaultCodexAppURL: URL {
        URL(fileURLWithPath: "/Applications/Codex.app")
    }

    var selectedSourceURL: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: selectedSourceKey), !path.isEmpty else {
                return FileManager.default.fileExists(atPath: defaultCodexAppURL.path) ? defaultCodexAppURL : nil
            }
            return URL(fileURLWithPath: path)
        }
        set {
            UserDefaults.standard.set(newValue?.path, forKey: selectedSourceKey)
        }
    }

    func loadClones() -> [ManagedAppClone] {
        guard let data = UserDefaults.standard.data(forKey: clonesKey),
              let clones = try? decoder.decode([ManagedAppClone].self, from: data) else {
            return []
        }
        return clones.sorted { $0.index < $1.index }
    }

    func saveClones(_ clones: [ManagedAppClone]) {
        guard let data = try? encoder.encode(clones.sorted(by: { $0.index < $1.index })) else { return }
        UserDefaults.standard.set(data, forKey: clonesKey)
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

    func createClones(sourceAppURL: URL, count: Int) throws -> [ManagedAppClone] {
        let sourceURL = sourceAppURL.standardizedFileURL
        guard sourceURL.pathExtension == "app",
              fileManager.fileExists(atPath: sourceURL.path) else {
            throw AppCloneError.invalidApp(sourceURL)
        }

        try fileManager.createDirectory(at: store.cloneRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: store.dataRoot, withIntermediateDirectories: true)

        let info = try readInfoPlist(in: sourceURL)
        let sourceName = sourceURL.deletingPathExtension().lastPathComponent
        let baseBundleID = sanitizedBundleID(info["CFBundleIdentifier"] as? String ?? "local.\(sourceName)")
        let existing = store.loadClones()
        let retained = existing.filter { $0.sourceAppPath != sourceURL.path }
        let oldForSource = existing.filter { $0.sourceAppPath == sourceURL.path }

        for clone in oldForSource where clone.cloneAppPath.hasPrefix(store.cloneRoot.path) {
            try? fileManager.removeItem(atPath: clone.cloneAppPath)
        }

        var clones: [ManagedAppClone] = []
        for index in 1...max(1, min(12, count)) {
            let number = String(format: "%02d", index)
            let displayName = "\(sourceName) \(number)"
            let cloneURL = store.cloneRoot.appendingPathComponent("\(displayName).app")
            let dataURL = store.dataRoot.appendingPathComponent("\(safeFolderName(sourceName))-\(number)")
            let bundleID = "\(baseBundleID).managedclone.\(number)"

            if fileManager.fileExists(atPath: cloneURL.path) {
                try fileManager.removeItem(at: cloneURL)
            }
            try fileManager.copyItem(at: sourceURL, to: cloneURL)
            try prepareDataFolders(at: dataURL)
            try rewriteInfoPlist(in: cloneURL, displayName: displayName, bundleIdentifier: bundleID)
            try signAppIfPossible(cloneURL)
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
                lastPID: nil
            ))
        }

        store.saveClones(retained + clones)
        store.selectedSourceURL = sourceURL
        return clones
    }

    func launch(_ clone: ManagedAppClone) throws -> ManagedAppClone {
        let cloneURL = URL(fileURLWithPath: clone.cloneAppPath)
        let executableURL = try executableURL(for: cloneURL)
        try prepareDataFolders(at: URL(fileURLWithPath: clone.dataPath))

        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = cloneURL.deletingLastPathComponent()
        process.arguments = launchArguments(for: clone)
        process.environment = launchEnvironment(for: clone)
        try process.run()

        var updated = clone
        updated.lastLaunchAt = Date()
        updated.lastPID = process.processIdentifier
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

    private func launchArguments(for clone: ManagedAppClone) -> [String] {
        let dataURL = URL(fileURLWithPath: clone.dataPath)
        let userDataURL = dataURL.appendingPathComponent("electron-user-data")
        return [
            "--user-data-dir=\(userDataURL.path)",
            "--no-first-run"
        ]
    }

    private func launchEnvironment(for clone: ManagedAppClone) -> [String: String] {
        let dataURL = URL(fileURLWithPath: clone.dataPath)
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_SWITCHER_INSTANCE_ID"] = clone.id.uuidString
        environment["CODEX_SWITCHER_INSTANCE_NAME"] = clone.displayName
        environment["CODEX_SWITCHER_REAL_HOME"] = NSHomeDirectory()
        environment["HOME"] = dataURL.appendingPathComponent("home").path
        environment["CODEX_HOME"] = dataURL.appendingPathComponent("codex-home").path
        environment["XDG_CONFIG_HOME"] = dataURL.appendingPathComponent("config").path
        environment["XDG_CACHE_HOME"] = dataURL.appendingPathComponent("cache").path
        environment["TMPDIR"] = dataURL.appendingPathComponent("tmp").path
        environment["PATH"] = augmentedPath(from: environment["PATH"])

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
            ["home", "Library", "Caches"],
            ["home", "Library", "Preferences"],
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

    private func rewriteInfoPlist(in appURL: URL, displayName: String, bundleIdentifier: String) throws {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        var plist = try readInfoPlist(in: appURL)
        plist["CFBundleIdentifier"] = bundleIdentifier
        plist["CFBundleName"] = displayName
        plist["CFBundleDisplayName"] = displayName
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

    private func signAppIfPossible(_ appURL: URL) throws {
        guard fileManager.isExecutableFile(atPath: "/usr/bin/codesign") else { return }
        let result = runSync("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", appURL.path])
        if result.status != 0 {
            throw AppCloneError.commandFailed("Signing \(appURL.lastPathComponent) failed:\n\(result.output)")
        }
    }

    private func registerWithLaunchServices(_ appURL: URL) {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
        guard fileManager.isExecutableFile(atPath: lsregister) else { return }
        _ = runSync(lsregister, ["-f", appURL.path])
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
}

final class InstanceManagerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store = InstanceManagerStore.shared
    private lazy var manager = AppCloneManager(store: store)
    private var clones: [ManagedAppClone] = []
    private var sourceURL: URL? {
        didSet {
            store.selectedSourceURL = sourceURL
            sourcePathField.stringValue = sourceURL?.path ?? "Choose an app bundle"
        }
    }

    private let sourcePathField = NSTextField(labelWithString: "")
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
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let sourceRow = NSStackView()
        sourceRow.orientation = .horizontal
        sourceRow.alignment = .centerY
        sourceRow.spacing = 10
        sourceRow.addArrangedSubview(label("Source app"))
        sourcePathField.lineBreakMode = .byTruncatingMiddle
        sourcePathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sourceRow.addArrangedSubview(sourcePathField)
        sourceRow.addArrangedSubview(button("Choose...", #selector(chooseSourceApp)))
        sourceRow.addArrangedSubview(button("Use Codex", #selector(useCodexApp)))
        root.addArrangedSubview(sourceRow)

        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 10
        actionRow.addArrangedSubview(label("Clones"))
        cloneCountField.alignment = .center
        cloneCountField.maximumNumberOfLines = 1
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
        actionRow.addArrangedSubview(button("Reveal", #selector(revealSelected)))
        actionRow.addArrangedSubview(button("Open Data", #selector(openSelectedData)))
        actionRow.addArrangedSubview(button("Remove", #selector(removeSelected)))
        actionRow.addArrangedSubview(button("Refresh", #selector(refreshClicked)))
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        actionRow.addArrangedSubview(progress)
        root.addArrangedSubview(actionRow)

        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = tableView
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.delegate = self
        tableView.dataSource = self
        addColumn("index", "#", 54)
        addColumn("name", "App Clone", 180)
        addColumn("bundle", "Bundle ID", 270)
        addColumn("data", "Data Folder", 300)
        addColumn("status", "Status", 120)
        root.addArrangedSubview(scrollView)
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        let logScroll = NSScrollView()
        logScroll.borderType = .bezelBorder
        logScroll.hasVerticalScroller = true
        logScroll.documentView = logTextView
        logTextView.isEditable = false
        logTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        logTextView.string = "Ready."
        root.addArrangedSubview(logScroll)
        logScroll.heightAnchor.constraint(equalToConstant: 96).isActive = true
    }

    private func addColumn(_ identifier: String, _ title: String, _ width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        tableView.addTableColumn(column)
    }

    private func label(_ value: String) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        return field
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        return button
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

    @objc private func createClones() {
        guard let sourceURL else {
            showError("Choose an app bundle first.")
            return
        }
        let count = max(1, min(12, Int(cloneCountField.stringValue) ?? cloneCountStepper.integerValue))
        setBusy(true)
        appendLog("Creating \(count) clone(s) from \(sourceURL.lastPathComponent)...")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let newClones = try self.manager.createClones(sourceAppURL: sourceURL, count: count)
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
