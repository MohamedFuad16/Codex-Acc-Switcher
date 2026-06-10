import AppKit
import Foundation
import QuartzCore

// MARK: - Data Models

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

// MARK: - Menu Bar Icon Generator

/// Draws a crisp, template-mode menu bar icon programmatically so we never
/// depend on Codex.app shipping a specific asset.  The icon is a stylised
/// switch / arrows-in-circle glyph that reads well at 18×18 pt.
enum MenuBarIcon {

    /// Try SF Symbols first (available on macOS 11+), fall back to a
    /// hand-drawn glyph if the symbol isn't present.
    static func create() -> NSImage {
        // Primary choice: SF Symbol "arrow.triangle.2.circlepath"
        if let sf = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                            accessibilityDescription: "Account Switcher") {
            let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                sf.draw(in: rect.insetBy(dx: 1, dy: 1))
                return true
            }
            img.isTemplate = true
            return img
        }

        // Fallback: draw two curved arrows inside a circle
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let ctx = NSGraphicsContext.current!.cgContext
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let r: CGFloat = 7
            NSColor.black.setStroke()

            // Circle outline
            ctx.setLineWidth(1.3)
            ctx.addEllipse(in: CGRect(x: center.x - r, y: center.y - r,
                                      width: r * 2, height: r * 2))
            ctx.strokePath()

            // Upper arrow arc
            let arrowR: CGFloat = 4.2
            ctx.setLineWidth(1.4)
            ctx.addArc(center: center, radius: arrowR,
                       startAngle: -.pi * 0.15, endAngle: .pi * 0.65,
                       clockwise: true)
            ctx.strokePath()

            // Arrowhead on upper arc
            let tipAngle: CGFloat = -.pi * 0.15
            let tipX = center.x + arrowR * cos(tipAngle)
            let tipY = center.y + arrowR * sin(tipAngle)
            ctx.move(to: CGPoint(x: tipX, y: tipY))
            ctx.addLine(to: CGPoint(x: tipX + 2.5, y: tipY + 1.5))
            ctx.move(to: CGPoint(x: tipX, y: tipY))
            ctx.addLine(to: CGPoint(x: tipX + 0.5, y: tipY + 3))
            ctx.strokePath()

            // Lower arrow arc
            ctx.addArc(center: center, radius: arrowR,
                       startAngle: .pi * 0.85, endAngle: -.pi * 0.35,
                       clockwise: true)
            ctx.strokePath()

            let tipAngle2: CGFloat = .pi * 0.85
            let tipX2 = center.x + arrowR * cos(tipAngle2)
            let tipY2 = center.y + arrowR * sin(tipAngle2)
            ctx.move(to: CGPoint(x: tipX2, y: tipY2))
            ctx.addLine(to: CGPoint(x: tipX2 - 2.5, y: tipY2 - 1.5))
            ctx.move(to: CGPoint(x: tipX2, y: tipY2))
            ctx.addLine(to: CGPoint(x: tipX2 - 0.5, y: tipY2 - 3))
            ctx.strokePath()

            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - Account Card View (Custom Menu Item)

/// Rich account row with coloured avatar circle, email, plan badge, and
/// active-state indicator.  Drawn entirely in `draw(_:)` for snappy rendering.
final class AccountCardView: NSView {

    private let account: CodexAccount
    private let label: String
    private let enabled: Bool
    var onSelect: (() -> Void)?

    private var isHighlighted = false
    private var trackingArea: NSTrackingArea?

    init(account: CodexAccount, label: String, enabled: Bool, action: (() -> Void)?) {
        self.account = account
        self.label = label
        self.enabled = enabled
        self.onSelect = action
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 48))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 300, height: 48) }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseEnteredAndExited, .activeInActiveApp],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        guard enabled else { return }
        isHighlighted = true; needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false; needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard enabled else { return }
        onSelect?()
        enclosingMenuItem?.menu?.cancelTracking()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let hPad: CGFloat = 16

        // Hover highlight
        if isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2),
                         xRadius: 6, yRadius: 6).fill()
        }

        // ── Avatar circle ──
        let avatarSize: CGFloat = 30
        let avatarY = (bounds.height - avatarSize) / 2
        let avatarRect = NSRect(x: hPad, y: avatarY, width: avatarSize, height: avatarSize)

        let avatarColor = avatarHue(for: account.email)
        avatarColor.setFill()
        NSBezierPath(ovalIn: avatarRect).fill()

        // Initials inside avatar
        let initials = avatarInitials(account.email)
        let initialAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let initialStr = NSAttributedString(string: initials, attributes: initialAttrs)
        let initialSize = initialStr.size()
        initialStr.draw(at: NSPoint(
            x: avatarRect.midX - initialSize.width / 2,
            y: avatarRect.midY - initialSize.height / 2
        ))

        // ── Text column ──
        let textX = hPad + avatarSize + 10
        let textW = bounds.width - textX - hPad - 50

        // Email (primary line)
        let emailAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: account.isActive ? .semibold : .regular),
            .foregroundColor: enabled ? NSColor.labelColor : NSColor.tertiaryLabelColor
        ]
        let emailStr = NSAttributedString(string: account.email, attributes: emailAttrs)
        emailStr.draw(in: NSRect(x: textX, y: bounds.height - 20, width: textW, height: 16))

        // Selector + Plan (secondary line)
        let detailAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let planStr = displayPlan(account.plan)
        let detailStr = NSAttributedString(string: "#\(account.selector) · \(planStr)", attributes: detailAttrs)
        detailStr.draw(at: NSPoint(x: textX, y: bounds.height - 34))

        // ── Right side: active badge or label ──
        if account.isActive {
            // Green "Active" pill
            let pillText = "Active"
            let pillFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
            let pillAttrs: [NSAttributedString.Key: Any] = [
                .font: pillFont,
                .foregroundColor: NSColor.white
            ]
            let pillStr = NSAttributedString(string: pillText, attributes: pillAttrs)
            let pillSize = pillStr.size()
            let pillW = pillSize.width + 12
            let pillH: CGFloat = 18
            let pillRect = NSRect(x: bounds.width - hPad - pillW,
                                  y: (bounds.height - pillH) / 2,
                                  width: pillW, height: pillH)
            NSColor.systemGreen.setFill()
            NSBezierPath(roundedRect: pillRect, xRadius: pillH / 2, yRadius: pillH / 2).fill()
            pillStr.draw(at: NSPoint(x: pillRect.midX - pillSize.width / 2,
                                     y: pillRect.midY - pillSize.height / 2))
        } else {
            // Show label text
            let lblAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            let lblStr = NSAttributedString(string: label, attributes: lblAttrs)
            let lblSize = lblStr.size()
            lblStr.draw(at: NSPoint(x: bounds.width - hPad - lblSize.width,
                                    y: (bounds.height - lblSize.height) / 2))
        }
    }

    // MARK: Helpers

    private func avatarHue(for email: String) -> NSColor {
        // Deterministic colour from email hash, adapts for dark / light mode
        let hash = abs(email.hashValue)
        let hue = CGFloat(hash % 360) / 360.0
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hue: hue,
                           saturation: isDark ? 0.45 : 0.58,
                           brightness: isDark ? 0.80 : 0.62,
                           alpha: 1.0)
        }
    }

    private func avatarInitials(_ email: String) -> String {
        let local = email.split(separator: "@").first.map(String.init) ?? email
        let parts = local.split(separator: ".")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(local.prefix(2)).uppercased()
    }

    private func displayPlan(_ plan: String) -> String {
        guard let first = plan.first else { return plan }
        return first.uppercased() + plan.dropFirst().lowercased()
    }
}

// MARK: - Glass Usage Bar View

/// Custom menu-item view with animated progress bar and liquid-glass highlight.
final class GlassUsageBarView: NSView {

    // Content
    private let title: String
    private let percent: String
    private let resetText: String
    private let progress: CGFloat          // target (0…1)
    private let isSelectedMode: Bool
    private let hasData: Bool              // false when usage data unavailable
    var onSelect: (() -> Void)?

    // State
    private var displayProgress: CGFloat = 0   // animated value
    private var isHighlighted = false
    private var trackingArea: NSTrackingArea?
    private var animationTimer: Timer?
    private var animationStart: CFTimeInterval = 0
    private let animationDuration: CFTimeInterval = 0.45

    init(title: String, percent: String, resetText: String,
         progress: CGFloat, isSelected: Bool, hasData: Bool, action: (() -> Void)?) {
        self.title = title
        self.percent = percent
        self.resetText = resetText
        self.progress = max(0, min(1, progress))
        self.isSelectedMode = isSelected
        self.hasData = hasData
        self.onSelect = action
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 46))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 300, height: 46) }

    // MARK: Mouse tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseEnteredAndExited, .activeInActiveApp],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        onSelect?()
        enclosingMenuItem?.menu?.cancelTracking()
    }

    // MARK: Fill animation — ease-out cubic on appear

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, hasData {
            displayProgress = 0
            needsDisplay = true
            animationStart = CACurrentMediaTime()
            animationTimer?.invalidate()
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                let elapsed = CACurrentMediaTime() - self.animationStart
                let normalized = min(1.0, elapsed / self.animationDuration)
                let eased = 1.0 - pow(1.0 - normalized, 3.0)
                self.displayProgress = self.progress * CGFloat(eased)
                self.needsDisplay = true
                if normalized >= 1.0 { self.animationTimer?.invalidate(); self.animationTimer = nil }
            }
            RunLoop.current.add(timer, forMode: .common)
            animationTimer = timer
        } else if window != nil {
            displayProgress = 0
            needsDisplay = true
        } else {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let hPad: CGFloat = 20
        let textY: CGFloat = 26
        let barY: CGFloat = 8
        let barH: CGFloat = 5
        let innerWidth = bounds.width - hPad * 2

        // Hover highlight
        if isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1),
                         xRadius: 6, yRadius: 6).fill()
        }

        // Checkmark indicator
        var textX = hPad
        if isSelectedMode {
            let checkAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                .foregroundColor: NSColor.controlAccentColor
            ]
            NSAttributedString(string: "✓ ", attributes: checkAttrs)
                .draw(at: NSPoint(x: textX, y: textY))
            textX += 18
        }

        // Title
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        NSAttributedString(string: title, attributes: titleAttrs)
            .draw(at: NSPoint(x: textX, y: textY))

        // Reset text (right-aligned)
        if !resetText.isEmpty {
            let resetAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            let resetStr = NSAttributedString(string: resetText, attributes: resetAttrs)
            let resetSize = resetStr.size()
            let resetX = bounds.width - hPad - resetSize.width
            resetStr.draw(at: NSPoint(x: resetX, y: textY + 2))
        }

        // Percentage (colour-coded)
        let pColor = hasData ? progressColor(for: displayProgress) : NSColor.tertiaryLabelColor
        let percentAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: pColor
        ]
        let percentStr = NSAttributedString(string: percent, attributes: percentAttrs)
        let percentSize = percentStr.size()
        // Position percent between title and reset text
        let percentRightEdge = resetText.isEmpty
            ? bounds.width - hPad
            : bounds.width - hPad - NSAttributedString(string: resetText, attributes: [
                .font: NSFont.systemFont(ofSize: 10)
              ]).size().width - 12
        percentStr.draw(at: NSPoint(x: percentRightEdge - percentSize.width, y: textY))

        // ── Progress bar ──

        // Track
        let trackRect = NSRect(x: hPad, y: barY, width: innerWidth, height: barH)
        NSColor.separatorColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: trackRect,
                     xRadius: barH / 2, yRadius: barH / 2).fill()

        // Fill with gradient + liquid-glass highlight
        if hasData, displayProgress > 0 {
            let fillW = max(barH, trackRect.width * displayProgress)
            let fillRect = NSRect(x: trackRect.minX, y: trackRect.minY,
                                  width: fillW, height: barH)
            let fillPath = NSBezierPath(roundedRect: fillRect,
                                        xRadius: barH / 2, yRadius: barH / 2)

            if let gradient = NSGradient(colors: [pColor.withAlphaComponent(0.55), pColor]) {
                gradient.draw(in: fillPath, angle: 0)
            }

            // Liquid-glass specular highlight stripe (adapts for dark / light)
            if fillW > 10 {
                let hlRect = NSRect(x: fillRect.minX + 2,
                                    y: fillRect.midY + 0.5,
                                    width: fillRect.width - 4,
                                    height: barH * 0.35)
                let hlColor = NSColor(name: nil) { appearance in
                    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    return NSColor.white.withAlphaComponent(isDark ? 0.22 : 0.35)
                }
                hlColor.setFill()
                NSBezierPath(roundedRect: hlRect, xRadius: 1.5, yRadius: 1.5).fill()
            }
        } else if !hasData {
            // Dashed placeholder track when no data
            let dashPattern: [CGFloat] = [3, 3]
            NSColor.tertiaryLabelColor.withAlphaComponent(0.25).setStroke()
            let dashed = NSBezierPath(roundedRect: trackRect.insetBy(dx: 0.5, dy: 0.5),
                                      xRadius: barH / 2, yRadius: barH / 2)
            dashed.lineWidth = 1
            dashed.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
            dashed.stroke()
        }
    }

    private func progressColor(for value: CGFloat) -> NSColor {
        if value > 0.5  { return .systemGreen }
        if value > 0.25 { return .systemOrange }
        return .systemRed
    }
}

// MARK: - Section Header View

/// Styled section header with optional SF Symbol icon.
final class SectionHeaderView: NSView {

    private let title: String
    private let symbolName: String?

    init(title: String, symbolName: String? = nil) {
        self.title = title
        self.symbolName = symbolName
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 300, height: 28) }

    override func draw(_ dirtyRect: NSRect) {
        let hPad: CGFloat = 16
        var textX = hPad

        // Optional SF Symbol icon
        if let name = symbolName,
           let symbol = NSImage(systemSymbolName: name, accessibilityDescription: title) {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            let configured = symbol.withSymbolConfiguration(config) ?? symbol
            let iconSize: CGFloat = 14
            let iconY = (bounds.height - iconSize) / 2
            configured.draw(in: NSRect(x: textX, y: iconY, width: iconSize, height: iconSize))
            textX += iconSize + 6
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        NSAttributedString(string: title.uppercased(), attributes: attrs)
            .draw(at: NSPoint(x: textX, y: 7))
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let refreshInterval: TimeInterval = 5
    private let labelsDefaultsKey = "accountDisplayLabels"
    private var refreshTimer: Timer?
    private var accounts: [CodexAccount] = []
    private var lastError: String?
    private var isSwitching = false
    private var switchAnimationTimer: Timer?
    private var switchAnimationFrame = 0
    private var switchingTitle = "Switching"
    private let switchAnimationFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private var usageMode: UsageDisplayMode {
        get {
            UsageDisplayMode(rawValue: UserDefaults.standard.string(forKey: "usageDisplayMode") ?? "") ?? .weekly
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "usageDisplayMode")
        }
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusButton()
        refreshAccounts()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshAccounts()
        }
        RunLoop.current.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.toolTip = "Codex Account Switcher"
        button.image = MenuBarIcon.create()
        button.imagePosition = .imageLeft
        button.wantsLayer = true
    }

    // MARK: Data refresh

    private func refreshAccounts() {
        guard !isSwitching else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // codex-auth 0.2.x does not support `list --active`; use `--skip-api`
            // as the primary flag (fast, suitable for the 5s poll). The active row
            // is still marked with `*`, which parseAccounts relies on.
            var result = self.runCodexAuth(["list", "--skip-api"])
            if result.status != 0 {
                result = self.runCodexAuth(["list"])
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
                self.rebuildMenu()
            }
        }
    }

    // MARK: Menu construction

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.minimumWidth = 300

        // ── Active account header ──
        if let active = accounts.first(where: { $0.isActive }) {
            if !isSwitching {
                setStatusTitleAnimated(statusTitle(for: active))
            }
        } else {
            if !isSwitching {
                setStatusTitleAnimated("")
            }
        }

        // ── Usage section ──
        if let active = accounts.first(where: { $0.isActive }) {
            let usageHeaderItem = NSMenuItem()
            usageHeaderItem.view = SectionHeaderView(title: "Usage Remaining",
                                                      symbolName: "chart.bar.fill")
            menu.addItem(usageHeaderItem)

            let fiveHourHasData = active.fiveHourUsedPercent != nil
            menu.addItem(usageMenuItem(
                title: "5-Hour",
                percent: remainingPercentText(fromUsed: active.fiveHourUsedPercent),
                reset: resetTimeText(from: active.fiveHourUsage),
                progress: remainingProgress(fromUsed: active.fiveHourUsedPercent),
                hasData: fiveHourHasData,
                mode: .fiveHour
            ))

            let weeklyHasData = active.weeklyUsedPercent != nil
            menu.addItem(usageMenuItem(
                title: "Weekly",
                percent: remainingPercentText(fromUsed: active.weeklyUsedPercent),
                reset: resetDateText(from: active.weeklyUsage),
                progress: remainingProgress(fromUsed: active.weeklyUsedPercent),
                hasData: weeklyHasData,
                mode: .weekly
            ))
            menu.addItem(.separator())
        }

        // ── Accounts section ──
        if accounts.isEmpty {
            let item = NSMenuItem(title: lastError ?? "No accounts available", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let accountsHeaderItem = NSMenuItem()
            accountsHeaderItem.view = SectionHeaderView(title: "Accounts",
                                                         symbolName: "person.2.fill")
            menu.addItem(accountsHeaderItem)

            for account in accounts {
                let cardItem = NSMenuItem()
                let view = AccountCardView(
                    account: account,
                    label: displayLabel(for: account),
                    enabled: !isSwitching,
                    action: { [weak self] in
                        self?.switchTo(selector: account.selector)
                    }
                )
                cardItem.view = view
                menu.addItem(cardItem)
            }
        }

        menu.addItem(.separator())

        // ── Quick actions ──
        if accounts.count == 2 {
            let toggle = NSMenuItem(title: "⇄  Toggle Account", action: #selector(toggleAccount), keyEquivalent: "t")
            toggle.target = self
            toggle.isEnabled = !isSwitching
            menu.addItem(toggle)
            menu.addItem(.separator())
        }

        let addAccount = NSMenuItem(title: "Add Account…", action: #selector(addAccountBrowser), keyEquivalent: "")
        addAccount.target = self
        addAccount.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Add")
        addAccount.isEnabled = !isSwitching
        menu.addItem(addAccount)

        let addDevice = NSMenuItem(title: "Add via Device Code…", action: #selector(addAccountDeviceCode), keyEquivalent: "")
        addDevice.target = self
        addDevice.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Terminal")
        addDevice.isEnabled = !isSwitching
        addDevice.toolTip = "Opens Terminal so the device code remains visible while login waits."
        menu.addItem(addDevice)

        if !accounts.isEmpty {
            menu.addItem(.separator())

            let labelsItem = NSMenuItem(title: "Display Labels", action: nil, keyEquivalent: "")
            labelsItem.image = NSImage(systemSymbolName: "tag", accessibilityDescription: "Labels")
            let labelsMenu = NSMenu()
            for account in accounts {
                let setItem = NSMenuItem(title: "Set \(account.selector) (\(account.email))…",
                                         action: #selector(setAccountLabel(_:)), keyEquivalent: "")
                setItem.target = self
                setItem.representedObject = account.email
                labelsMenu.addItem(setItem)

                let clearItem = NSMenuItem(title: "Clear \(account.selector)",
                                           action: #selector(clearAccountLabel(_:)), keyEquivalent: "")
                clearItem.target = self
                clearItem.representedObject = account.email
                clearItem.isEnabled = customLabel(forEmail: account.email) != nil
                labelsMenu.addItem(clearItem)
            }
            labelsItem.submenu = labelsMenu
            menu.addItem(labelsItem)

            let removeItem = NSMenuItem(title: "Remove Account", action: nil, keyEquivalent: "")
            removeItem.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove")
            let removeMenu = NSMenu()
            for account in accounts {
                let item = NSMenuItem(title: "\(displayLabel(for: account))  \(account.email)",
                                      action: #selector(removeAccount(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = account.selector
                item.isEnabled = !isSwitching
                removeMenu.addItem(item)
            }
            removeItem.submenu = removeMenu
            menu.addItem(removeItem)
        }

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refresh.isEnabled = !isSwitching
        menu.addItem(refresh)

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - Smooth status-bar title transition

    private func setStatusTitleAnimated(_ newTitle: String) {
        guard let button = statusItem.button else { return }
        guard button.title != newTitle else { return }
        button.layer?.removeAnimation(forKey: "completionFlash")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            button.animator().alphaValue = 0.0
        }) {
            button.title = newTitle
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                button.animator().alphaValue = 1.0
            })
        }
    }

    // MARK: Status title helpers

    private func statusTitle(for account: CodexAccount) -> String {
        let label = displayLabel(for: account)
        switch usageMode {
        case .fiveHour:
            return "\(label) · 5hr \(remainingPercentText(fromUsed: account.fiveHourUsedPercent))"
        case .weekly:
            return "\(label) · W \(remainingPercentText(fromUsed: account.weeklyUsedPercent))"
        }
    }

    private func remainingPercentText(fromUsed used: Int?) -> String {
        guard let used else { return "NIL" }
        return "\(max(0, min(100, 100 - used)))%"
    }

    private func remainingProgress(fromUsed used: Int?) -> CGFloat {
        guard let used else { return 0 }
        return CGFloat(max(0, min(100, 100 - used))) / 100.0
    }

    // MARK: - Usage menu items

    private func usageMenuItem(title: String, percent: String, reset: String,
                               progress: CGFloat, hasData: Bool,
                               mode: UsageDisplayMode) -> NSMenuItem {
        let item = NSMenuItem()
        let view = GlassUsageBarView(
            title: title,
            percent: percent,
            resetText: reset,
            progress: progress,
            isSelected: usageMode == mode,
            hasData: hasData,
            action: { [weak self] in
                self?.usageMode = mode
                self?.rebuildMenu()
            }
        )
        item.view = view
        return item
    }

    // MARK: Reset-time formatting

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

    // MARK: - Actions

    @objc private func refreshNow() {
        refreshAccounts()
    }

    @objc private func addAccountBrowser() {
        runAccountMaintenance(title: "Adding account", args: ["login"], restartAfterSuccess: true)
    }

    @objc private func addAccountDeviceCode() {
        let path = codexAuthPath() ?? "codex-auth"
        let home = NSHomeDirectory()
        let restartPath = "\(home)/.codex/skills/codex-account-switcher/scripts/codex_account_switch.sh"
        let script = """
        tell application "Terminal"
          activate
          do script "\(shellEscaped(path)) login --device-auth && \(shellEscaped(restartPath)) restart-app; echo; echo 'Codex account login finished and Codex App was relaunched. You can close this window.'"
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
            // codex-auth 0.2.x matches by email/alias, not row-number selector
            runAccountMaintenance(title: "Removing account", args: ["remove", account.email])
        }
    }

    @objc private func toggleAccount() {
        guard accounts.count == 2, let inactive = accounts.first(where: { !$0.isActive }) else {
            showAlert(title: "Cannot toggle",
                      message: "Toggle requires exactly two saved accounts and one active account.")
            return
        }
        switchTo(selector: inactive.selector)
    }

    @objc private func switchAccount(_ sender: NSMenuItem) {
        guard let selector = sender.representedObject as? String else { return }
        switchTo(selector: selector)
    }

    // MARK: - Account switching

    private func switchTo(selector: String) {
        guard !isSwitching else { return }
        let target = accounts.first(where: { $0.selector == selector })
        isSwitching = true
        beginSwitchAnimation(label: target.map(displayLabel(for:)) ?? selector)
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            if let syncError = self.syncActiveAuthSnapshot() {
                DispatchQueue.main.async {
                    self.isSwitching = false
                    self.endSwitchAnimation()
                    self.showAlert(title: "Could not save active token", message: syncError)
                    self.refreshAccounts()
                }
                return
            }

            // codex-auth 0.2.x matches by email/alias, not row-number selector
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

    // MARK: - Switch animation (spinner + pulse)

    private func beginSwitchAnimation(label: String) {
        switchAnimationTimer?.invalidate()
        switchAnimationFrame = 0
        switchingTitle = "\(limitedLabel(label)) · switching"
        updateSwitchAnimationTitle()

        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.switchAnimationFrame += 1
            self.updateSwitchAnimationTitle()
        }
        RunLoop.current.add(timer, forMode: .common)
        switchAnimationTimer = timer

        beginPulseAnimation()
    }

    private func updateSwitchAnimationTitle() {
        let frame = switchAnimationFrames[switchAnimationFrame % switchAnimationFrames.count]
        statusItem.button?.title = "\(switchingTitle) \(frame)"
    }

    private func beginPulseAnimation() {
        guard let layer = statusItem.button?.layer else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "switchPulse")
    }

    private func endSwitchAnimation() {
        switchAnimationTimer?.invalidate()
        switchAnimationTimer = nil
        endPulseAnimation()
    }

    private func endPulseAnimation() {
        guard let button = statusItem.button, let layer = button.layer else { return }
        layer.removeAnimation(forKey: "switchPulse")
        button.alphaValue = 1.0

        let flash = CABasicAnimation(keyPath: "opacity")
        flash.fromValue = 0.4
        flash.toValue = 1.0
        flash.duration = 0.3
        flash.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(flash, forKey: "completionFlash")
    }

    // MARK: - Auth snapshot sync

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

    // MARK: - Account maintenance

    private func runAccountMaintenance(title: String, args: [String], restartAfterSuccess: Bool = false) {
        guard !isSwitching else { return }
        isSwitching = true
        statusItem.button?.title = title
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
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

    // MARK: - App restart

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
                return CommandResult(status: openResult.status,
                                    output: transcript.joined(separator: "\n") + "\n" + openResult.output)
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
        let myPID = String(ProcessInfo.processInfo.processIdentifier)
        let result = run("/usr/bin/pgrep", ["-f", "/Applications/Codex\\.app/Contents/"])
        guard result.status == 0 else { return [] }
        return result.output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty && $0 != myPID }
    }

    // MARK: - Parsing

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

    // MARK: - External process helpers

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
            for versionDir in versions.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
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
        var environment = ProcessInfo.processInfo.environment
        let bundledNode = "/Applications/Codex.app/Contents/Resources/node"
        if FileManager.default.isExecutableFile(atPath: bundledNode) {
            environment["CODEX_AUTH_NODE_EXECUTABLE"] = bundledNode
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

    // MARK: - UI helpers

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

    // MARK: - Custom labels (UserDefaults)

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

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
