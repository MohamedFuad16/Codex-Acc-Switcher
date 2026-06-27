import AppKit
import Foundation
import QuartzCore
import UserNotifications

// MARK: - Data Models

struct CodexAccount {
    let selector: String
    let email: String
    let plan: String
    let fiveHourUsage: String
    let weeklyUsage: String
    let fiveHourRemainingPercent: Int?
    let weeklyRemainingPercent: Int?
    let lastActivity: String
    let isActive: Bool

    var isExpired: Bool {
        let planText = plan.lowercased()
        let usageText = "\(fiveHourUsage) \(weeklyUsage)".lowercased()
        let deadMarkers = ["token_invalidated", "unauthorized", "invalid", "expired", "401"]
        return planText == "unknown" || deadMarkers.contains { usageText.contains($0) }
    }

    var isAPIKeyAccount: Bool {
        let normalizedPlan = plan.uppercased().filter(\.isLetter)
        let normalizedEmail = email.lowercased()
        return normalizedPlan == "APIKEY" ||
        normalizedEmail.hasPrefix("sk-") ||
        normalizedEmail.contains("(api_key)")
    }

    var hasComparableUsageCaps: Bool {
        !isAPIKeyAccount &&
        fiveHourRemainingPercent != nil &&
        weeklyRemainingPercent != nil
    }

    var lowestRemainingPercent: Int? {
        guard let fiveHourRemainingPercent, let weeklyRemainingPercent else { return nil }
        return min(fiveHourRemainingPercent, weeklyRemainingPercent)
    }

    func withActive(_ active: Bool) -> CodexAccount {
        CodexAccount(
            selector: selector,
            email: email,
            plan: plan,
            fiveHourUsage: fiveHourUsage,
            weeklyUsage: weeklyUsage,
            fiveHourRemainingPercent: fiveHourRemainingPercent,
            weeklyRemainingPercent: weeklyRemainingPercent,
            lastActivity: lastActivity,
            isActive: active
        )
    }
}

enum UsageDisplayMode: String {
    case fiveHour
    case weekly
}

enum StatusAnimationStyle: String, CaseIterable {
    case spark
    case orbit
    case pulse
    case wave
    case bars
    case arrows

    var title: String {
        switch self {
        case .spark: return "Spark"
        case .orbit: return "Orbit"
        case .pulse: return "Pulse"
        case .wave: return "Wave"
        case .bars: return "Bars"
        case .arrows: return "Arrows"
        }
    }
}

struct CommandResult {
    let status: Int32
    let output: String
}

struct HandoffAccountState: Codable {
    let email: String
    let label: String
    let plan: String
    let fiveHourRemainingPercent: Int?
    let weeklyRemainingPercent: Int?
    let isActive: Bool
}

struct HandoffState: Codable {
    let updatedAt: Date
    let reason: String
    let sourceThreadID: String?
    let previousEmail: String?
    let targetEmail: String?
    let activeEmail: String?
    let activeLowestRemainingPercent: Int?
    let recommendedEmail: String?
    let recommendedLowestRemainingPercent: Int?
    let accounts: [HandoffAccountState]
    let continuationPrompt: String
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
    private let isExpired: Bool
    var onSelect: (() -> Void)?

    private var isHighlighted = false
    private var trackingArea: NSTrackingArea?

    init(account: CodexAccount, label: String, enabled: Bool, isExpired: Bool, action: (() -> Void)?) {
        self.account = account
        self.label = label
        self.enabled = enabled
        self.isExpired = isExpired
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
        if isExpired {
            // Red "⚠️ Re-login" pill
            let pillText = "⚠️ Re-login"
            let pillFont = NSFont.systemFont(ofSize: 9, weight: .bold)
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
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: pillRect, xRadius: pillH / 2, yRadius: pillH / 2).fill()
            pillStr.draw(at: NSPoint(x: pillRect.midX - pillSize.width / 2,
                                     y: pillRect.midY - pillSize.height / 2))
        } else if account.isActive {
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
    private let animationDuration: CFTimeInterval = 0.75

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
        let barH: CGFloat = 7
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

        // Percentage: keep this dark for readability over the glass menu material.
        let pColor = hasData ? NSColor(calibratedWhite: 0.07, alpha: 0.95) : NSColor.tertiaryLabelColor
        let percentAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13.5, weight: .bold),
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
        NSColor.black.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: trackRect,
                     xRadius: barH / 2, yRadius: barH / 2).fill()

        // Fill with gradient + liquid-glass highlight
        if hasData, displayProgress > 0 {
            let fillColor = progressColor(for: displayProgress)
            let fillW = max(barH, trackRect.width * displayProgress)
            let fillRect = NSRect(x: trackRect.minX, y: trackRect.minY,
                                  width: fillW, height: barH)
            let fillPath = NSBezierPath(roundedRect: fillRect,
                                        xRadius: barH / 2, yRadius: barH / 2)

            if let gradient = NSGradient(colors: [
                fillColor.withAlphaComponent(0.72),
                fillColor,
                NSColor.systemYellow.withAlphaComponent(0.92)
            ]) {
                gradient.draw(in: fillPath, angle: 0)
            }

            // Liquid-glass specular highlight stripe (adapts for dark / light)
            if fillW > 10 {
                let hlRect = NSRect(x: fillRect.minX + 2,
                                    y: fillRect.midY + 0.8,
                                    width: fillRect.width - 4,
                                    height: barH * 0.32)
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
        if value > 0.25 { return .systemYellow }
        if value > 0.10 { return .systemOrange }
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

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let refreshInterval: TimeInterval = 5
    private let liveValidationInterval: TimeInterval = 60
    private let labelsDefaultsKey = "accountDisplayLabels"
    private let statusAnimationStyleDefaultsKey = "statusAnimationStyle"
    private let autoSwitchEnabledDefaultsKey = "autoSwitchEnabled"
    private let autoSwitchThresholdDefaultsKey = "autoSwitchThresholdPercent"
    private let autoSwitchTargetFloorDefaultsKey = "autoSwitchTargetFloorPercent"
    private let recommendationThresholdDefaultsKey = "recommendationThresholdPercent"
    private var refreshTimer: Timer?
    private var statusFrameTimer: Timer?
    private var lastLiveValidationAt: Date?
    private var statusAnimationFrame = 0
    private var lastBaseStatusTitle = ""
    private var accounts: [CodexAccount] = []
    private var lastError: String?
    private var isSwitching = false
    private var switchAnimationTimer: Timer?
    private var switchAnimationFrame = 0
    private var previousAccounts: [String: CodexAccount] = [:]
    private var notifiedExpiredEmails: Set<String> = []
    private var removingDeadAccountEmails: Set<String> = []
    private var lastSuggestedEmail: String?
    private var lastAutoSwitchKey: String?
    private var authWarningTitle: String?
    private var vibeAnimationTimer: Timer?
    private var vibeAnimationFrame = 0
    private var switchingTitle = "Switching"
    private let switchAnimationFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private lazy var appSupportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Codex Account Switcher", isDirectory: true)
    }()
    private lazy var handoffStateURL: URL = appSupportDirectory.appendingPathComponent("handoff-state.json")
    private lazy var handoffPromptURL: URL = appSupportDirectory.appendingPathComponent("handoff-prompt.txt")
    private var usageMode: UsageDisplayMode {
        get {
            UsageDisplayMode(rawValue: UserDefaults.standard.string(forKey: "usageDisplayMode") ?? "") ?? .weekly
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "usageDisplayMode")
        }
    }
    private var statusAnimationStyle: StatusAnimationStyle {
        get {
            StatusAnimationStyle(rawValue: UserDefaults.standard.string(forKey: statusAnimationStyleDefaultsKey) ?? "") ?? .spark
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: statusAnimationStyleDefaultsKey)
        }
    }
    private var autoSwitchEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: autoSwitchEnabledDefaultsKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoSwitchEnabledDefaultsKey)
        }
    }
    private var autoSwitchThresholdPercent: Int {
        get {
            let stored = UserDefaults.standard.object(forKey: autoSwitchThresholdDefaultsKey) as? Int ?? 4
            return clampedPercent(stored)
        }
        set {
            UserDefaults.standard.set(clampedPercent(newValue), forKey: autoSwitchThresholdDefaultsKey)
        }
    }
    private var autoSwitchTargetFloorPercent: Int {
        get {
            let stored = UserDefaults.standard.object(forKey: autoSwitchTargetFloorDefaultsKey) as? Int ?? autoSwitchThresholdPercent
            return clampedPercent(stored)
        }
        set {
            UserDefaults.standard.set(clampedPercent(newValue), forKey: autoSwitchTargetFloorDefaultsKey)
        }
    }
    private var recommendationThresholdPercent: Int {
        get {
            let stored = UserDefaults.standard.object(forKey: recommendationThresholdDefaultsKey) as? Int ?? 10
            return clampedPercent(stored)
        }
        set {
            UserDefaults.standard.set(clampedPercent(newValue), forKey: recommendationThresholdDefaultsKey)
        }
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusButton()
        
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification authorization failed: \(error)")
            }
        }
        
        refreshAccounts(forceAPI: true)
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshAccounts()
        }
        RunLoop.current.add(timer, forMode: .common)
        refreshTimer = timer

        let frameTimer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.advanceStatusFrame()
        }
        RunLoop.current.add(frameTimer, forMode: .common)
        statusFrameTimer = frameTimer
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.toolTip = "Codex Account Switcher"
        button.image = nil
        button.imagePosition = .noImage
        button.wantsLayer = true
    }

    // MARK: Data refresh

    private func refreshAccounts(forceAPI: Bool = false) {
        guard !isSwitching else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // Use plain `list` for live validation because `list --active` can
            // leave stale per-account usage in place. Use `--skip-api` only for
            // the fast 5s status poll; both outputs still mark the active row
            // with `*`, which parseAccounts relies on.
            var result: CommandResult
            let now = Date()
            let shouldValidateLive = forceAPI ||
                self.lastLiveValidationAt.map { now.timeIntervalSince($0) >= self.liveValidationInterval } ?? true
            if shouldValidateLive {
                result = self.runCodexAuth(["list"])
            } else {
                result = self.runCodexAuth(["list", "--skip-api"])
                if result.status != 0 {
                    result = self.runCodexAuth(["list"])
                }
            }
            let parsed = result.status == 0 ? self.parseAccounts(result.output) : []
            let reconciled = result.status == 0 ? self.reconciledAccountsWithActiveAuth(parsed) : (accounts: [], warning: nil)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if result.status == 0 {
                    if shouldValidateLive {
                        self.lastLiveValidationAt = now
                    }
                    let oldAccounts = self.accounts
                    let deadAccounts = reconciled.accounts.filter(\.isExpired)
                    let visibleAccounts = reconciled.accounts.filter { !$0.isExpired }
                    self.accounts = visibleAccounts
                    self.authWarningTitle = reconciled.warning
                    self.lastError = visibleAccounts.isEmpty ? "No usable codex-auth accounts found." : nil
                    self.processAccountUpdates(old: oldAccounts, new: visibleAccounts, isLiveRefresh: shouldValidateLive)
                    self.removeDeadAccounts(deadAccounts, activeWasDead: deadAccounts.contains(where: \.isActive), candidates: visibleAccounts)
                } else {
                    self.accounts = []
                    self.lastError = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                self.rebuildMenu()
            }
        }
    }

    private struct ActiveAuthIdentity {
        let authMode: String?
        let accountID: String?
        let hasChatGPTTokens: Bool
        let hasTopLevelAPIKey: Bool

        var isAPIKeyMode: Bool {
            (authMode?.lowercased() == "apikey") || (!hasChatGPTTokens && hasTopLevelAPIKey)
        }
    }

    private struct RegistryEntry {
        let email: String
        let accountID: String?
        let authMode: String?
    }

    private func reconciledAccountsWithActiveAuth(_ parsed: [CodexAccount]) -> (accounts: [CodexAccount], warning: String?) {
        guard let identity = currentActiveAuthIdentity() else {
            return (parsed, nil)
        }

        if identity.isAPIKeyMode {
            return (
                parsed.map { $0.withActive($0.isAPIKeyAccount) },
                "API key active · manual"
            )
        }

        guard identity.hasChatGPTTokens else {
            return (
                parsed.map { $0.withActive(false) },
                "Codex logged out · sign in"
            )
        }

        let registry = registryEntriesByAccountID()
        if let accountID = identity.accountID,
           let registryEntry = registry[accountID],
           registryEntry.authMode?.lowercased() != "apikey" {
            return (
                parsed.map { $0.withActive($0.email == registryEntry.email) },
                nil
            )
        }

        return (
            parsed.map { $0.withActive(false) },
            "Signed in outside switcher · add account"
        )
    }

    private func currentActiveAuthIdentity() -> ActiveAuthIdentity? {
        let url = URL(fileURLWithPath: "\(NSHomeDirectory())/.codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let tokens = object["tokens"] as? [String: Any]
        return ActiveAuthIdentity(
            authMode: object["auth_mode"] as? String,
            accountID: tokens?["account_id"] as? String,
            hasChatGPTTokens: tokens?["access_token"] is String &&
                tokens?["refresh_token"] is String &&
                tokens?["id_token"] is String,
            hasTopLevelAPIKey: object["OPENAI_API_KEY"] is String
        )
    }

    private func registryEntriesByAccountID() -> [String: RegistryEntry] {
        let url = URL(fileURLWithPath: "\(NSHomeDirectory())/.codex/accounts/registry.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accountObjects = object["accounts"] as? [[String: Any]] else {
            return [:]
        }

        var entries: [String: RegistryEntry] = [:]
        for account in accountObjects {
            guard let accountID = account["chatgpt_account_id"] as? String,
                  !accountID.isEmpty,
                  let email = account["email"] as? String else {
                continue
            }
            entries[accountID] = RegistryEntry(
                email: email,
                accountID: accountID,
                authMode: account["auth_mode"] as? String
            )
        }
        return entries
    }

    private func activeAuthMismatchMessage(expectedEmail: String) -> String? {
        guard let identity = currentActiveAuthIdentity() else {
            return "codex-auth reported success, but ~/.codex/auth.json could not be read afterward."
        }
        if identity.isAPIKeyMode {
            return "codex-auth reported success, but ~/.codex/auth.json is still in API-key mode. The app will not relaunch Codex into the API-key account automatically."
        }
        guard identity.hasChatGPTTokens, let accountID = identity.accountID else {
            return "codex-auth reported success, but ~/.codex/auth.json does not contain a complete ChatGPT token set."
        }
        guard let activeEmail = registryEntriesByAccountID()[accountID]?.email else {
            return "codex-auth reported success, but the active ChatGPT account is not registered in codex-auth. Use Add Account to link it."
        }
        guard activeEmail == expectedEmail else {
            return "codex-auth reported success, but Codex auth is active for \(activeEmail), not \(expectedEmail)."
        }
        return nil
    }

    // MARK: Menu construction

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.minimumWidth = 300

        // ── Active account header ──
        if let authWarningTitle {
            if !isSwitching, vibeAnimationTimer == nil {
                setStatusTitleAnimated(authWarningTitle)
            }
        } else if let active = accounts.first(where: { $0.isActive }) {
            if !isSwitching, vibeAnimationTimer == nil {
                setStatusTitleAnimated(statusTitle(for: active))
            }
        } else {
            if !isSwitching, vibeAnimationTimer == nil {
                setStatusTitleAnimated("")
            }
        }

        // ── Usage section ──
        if let active = accounts.first(where: { $0.isActive }) {
            let usageHeaderItem = NSMenuItem()
            usageHeaderItem.view = SectionHeaderView(title: "Usage Remaining",
                                                      symbolName: "chart.bar.fill")
            menu.addItem(usageHeaderItem)

            let fiveHourHasData = active.fiveHourRemainingPercent != nil
            menu.addItem(usageMenuItem(
                title: "5-Hour",
                percent: remainingPercentText(fromRemaining: active.fiveHourRemainingPercent),
                reset: resetTimeText(from: active.fiveHourUsage),
                progress: remainingProgress(fromRemaining: active.fiveHourRemainingPercent),
                hasData: fiveHourHasData,
                mode: .fiveHour
            ))

            let weeklyHasData = active.weeklyRemainingPercent != nil
            menu.addItem(usageMenuItem(
                title: "Weekly",
                percent: remainingPercentText(fromRemaining: active.weeklyRemainingPercent),
                reset: resetDateText(from: active.weeklyUsage),
                progress: remainingProgress(fromRemaining: active.weeklyRemainingPercent),
                hasData: weeklyHasData,
                mode: .weekly
            ))
            menu.addItem(.separator())
            
            // Suggestion Banner
            if shouldRecommendSwitch(from: active),
               let best = bestRecommendation(excluding: active.email) {
                let bestLabel = displayLabel(for: best)
                let bestLowest = best.lowestRemainingPercent ?? 0
                let suggestHeaderItem = NSMenuItem()
                suggestHeaderItem.view = SectionHeaderView(title: "Smart Recommendation", symbolName: "sparkles")
                menu.addItem(suggestHeaderItem)

                let suggestItem = NSMenuItem()
                suggestItem.title = "✨ Switch to \(bestLabel) (\(bestLowest)% lowest cap)"
                suggestItem.toolTip = "5-hour \(remainingPercentText(fromRemaining: best.fiveHourRemainingPercent)), weekly \(remainingPercentText(fromRemaining: best.weeklyRemainingPercent))"
                suggestItem.representedObject = best.selector
                suggestItem.action = #selector(switchAccount(_:))
                suggestItem.target = self
                menu.addItem(suggestItem)
                menu.addItem(.separator())
            }
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
                let expired = account.isExpired
                let view = AccountCardView(
                    account: account,
                    label: displayLabel(for: account),
                    enabled: !isSwitching,
                    isExpired: expired,
                    action: { [weak self] in
                        if expired {
                            self?.promptRelogin(for: account)
                        } else {
                            self?.switchTo(selector: account.selector)
                        }
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

            let autoSwitchItem = NSMenuItem(title: "Auto Switch", action: nil, keyEquivalent: "")
            autoSwitchItem.image = NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: "Auto Switch")
            let autoSwitchMenu = NSMenu()
            let enabledItem = NSMenuItem(
                title: autoSwitchEnabled ? "Enabled" : "Disabled",
                action: #selector(toggleAutoSwitch(_:)),
                keyEquivalent: ""
            )
            enabledItem.target = self
            enabledItem.state = autoSwitchEnabled ? .on : .off
            autoSwitchMenu.addItem(enabledItem)

            let switchBelowItem = NSMenuItem(
                title: "Switch when active is below \(autoSwitchThresholdPercent)%…",
                action: #selector(setAutoSwitchThreshold(_:)),
                keyEquivalent: ""
            )
            switchBelowItem.target = self
            autoSwitchMenu.addItem(switchBelowItem)

            let targetFloorItem = NSMenuItem(
                title: "Prefer targets at/above \(autoSwitchTargetFloorPercent)%…",
                action: #selector(setAutoSwitchTargetFloor(_:)),
                keyEquivalent: ""
            )
            targetFloorItem.target = self
            autoSwitchMenu.addItem(targetFloorItem)

            let recommendBelowItem = NSMenuItem(
                title: "Recommend below \(recommendationThresholdPercent)%…",
                action: #selector(setRecommendationThreshold(_:)),
                keyEquivalent: ""
            )
            recommendBelowItem.target = self
            autoSwitchMenu.addItem(recommendBelowItem)

            let policyItem = NSMenuItem(title: "API-key accounts are manual-only", action: nil, keyEquivalent: "")
            policyItem.isEnabled = false
            autoSwitchMenu.addItem(.separator())
            autoSwitchMenu.addItem(policyItem)
            autoSwitchItem.submenu = autoSwitchMenu
            menu.addItem(autoSwitchItem)

            let animationItem = NSMenuItem(title: "Status Animation", action: nil, keyEquivalent: "")
            animationItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Animation")
            let animationMenu = NSMenu()
            for style in StatusAnimationStyle.allCases {
                let item = NSMenuItem(title: style.title, action: #selector(setStatusAnimationStyle(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = style.rawValue
                item.state = statusAnimationStyle == style ? .on : .off
                animationMenu.addItem(item)
            }
            animationItem.submenu = animationMenu
            menu.addItem(animationItem)

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
        lastBaseStatusTitle = newTitle
        let renderedTitle = animatedStatusTitle(for: newTitle)
        guard button.title != renderedTitle else { return }
        button.layer?.removeAnimation(forKey: "completionFlash")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            button.animator().alphaValue = 0.0
        }) {
            button.title = renderedTitle
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                button.animator().alphaValue = 1.0
            })
        }
    }

    private func advanceStatusFrame() {
        guard !lastBaseStatusTitle.isEmpty,
              let button = statusItem.button,
              !isSwitching,
              vibeAnimationTimer == nil else { return }
        statusAnimationFrame += 1
        button.title = animatedStatusTitle(for: lastBaseStatusTitle)
    }

    private func animatedStatusTitle(for title: String) -> String {
        guard !title.isEmpty else { return "" }
        return "\(statusAnimationPrefix()) \(title)"
    }

    private func statusAnimationPrefix() -> String {
        switch statusAnimationStyle {
        case .spark:
            return ["✦", "✧", "✶", "✳", "✢"][statusAnimationFrame % 5]
        case .orbit:
            return ["◜", "◠", "◝", "◞", "◡", "◟"][statusAnimationFrame % 6]
        case .pulse:
            return ["●", "•", "·", "•"][statusAnimationFrame % 4]
        case .wave:
            return ["≋", "∿", "≈", "∿"][statusAnimationFrame % 4]
        case .bars:
            return ["▁", "▃", "▅", "▇", "▅", "▃"][statusAnimationFrame % 6]
        case .arrows:
            return ["↻", "↺", "↻", "↺"][statusAnimationFrame % 4]
        }
    }

    // MARK: Status title helpers

    private func statusTitle(for account: CodexAccount) -> String {
        let label = displayLabel(for: account)
        switch usageMode {
        case .fiveHour:
            return "\(label) · 5hr \(remainingPercentText(fromRemaining: account.fiveHourRemainingPercent))"
        case .weekly:
            return "\(label) · W \(remainingPercentText(fromRemaining: account.weeklyRemainingPercent))"
        }
    }

    private func remainingPercentText(fromRemaining remaining: Int?) -> String {
        guard let remaining else { return "NIL" }
        return "\(max(0, min(100, remaining)))%"
    }

    private func remainingProgress(fromRemaining remaining: Int?) -> CGFloat {
        guard let remaining else { return 0 }
        return CGFloat(max(0, min(100, remaining))) / 100.0
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
        refreshAccounts(forceAPI: true)
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

    @objc private func setStatusAnimationStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = StatusAnimationStyle(rawValue: raw) else { return }
        statusAnimationStyle = style
        statusAnimationFrame = 0
        rebuildMenu()
    }

    @objc private func toggleAutoSwitch(_ sender: NSMenuItem) {
        autoSwitchEnabled.toggle()
        lastAutoSwitchKey = nil
        rebuildMenu()
    }

    @objc private func setAutoSwitchThreshold(_ sender: NSMenuItem) {
        promptForPercent(
            title: "Auto-switch threshold",
            message: "Switch away from the active account when either limit drops below this percentage.",
            currentValue: autoSwitchThresholdPercent
        ) { [weak self] value in
            self?.autoSwitchThresholdPercent = value
            if let self = self, self.autoSwitchTargetFloorPercent < value {
                self.autoSwitchTargetFloorPercent = value
            }
            self?.lastAutoSwitchKey = nil
            self?.rebuildMenu()
        }
    }

    @objc private func setAutoSwitchTargetFloor(_ sender: NSMenuItem) {
        promptForPercent(
            title: "Auto-switch target floor",
            message: "Prefer automatic targets whose lowest 5-hour/weekly limit is at or above this percentage. If none qualify, the app waits for the non-API account whose depleted limit resets soonest.",
            currentValue: autoSwitchTargetFloorPercent
        ) { [weak self] value in
            self?.autoSwitchTargetFloorPercent = value
            self?.lastAutoSwitchKey = nil
            self?.rebuildMenu()
        }
    }

    @objc private func setRecommendationThreshold(_ sender: NSMenuItem) {
        promptForPercent(
            title: "Recommendation threshold",
            message: "Show a non-automatic recommendation when the active account drops to or below this percentage.",
            currentValue: recommendationThresholdPercent
        ) { [weak self] value in
            self?.recommendationThresholdPercent = value
            self?.lastSuggestedEmail = nil
            self?.rebuildMenu()
        }
    }

    // MARK: - Account switching

    private func validatedSwitchAccount(for query: String) -> (account: CodexAccount?, revoked: CodexAccount?, error: String?) {
        var result = runCodexAuth(["list"])
        if result.status != 0 {
            result = runCodexAuth(["list", "--skip-api"])
        }
        guard result.status == 0 else {
            return (nil, nil, result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let liveAccounts = parseAccounts(result.output)
        guard let account = liveAccounts.first(where: { $0.email == query || $0.selector == query }) else {
            return (nil, nil, nil)
        }
        if account.isExpired {
            return (nil, account, nil)
        }
        return (account, nil, nil)
    }

    private func switchTo(selector: String, handoffReason: String = "manual account switch", runContinuation: Bool = true) {
        guard !isSwitching else { return }
        let target = accounts.first(where: { $0.selector == selector })
        isSwitching = true
        beginSwitchAnimation(label: target.map(displayLabel(for:)) ?? selector)
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let targetQuery = target?.email ?? selector
            let sourceThreadID = self.mostRecentCodexThreadID()
            let activeAccount = self.accounts.first(where: { $0.isActive })
            let validation = self.validatedSwitchAccount(for: targetQuery)
            if let revoked = validation.revoked {
                _ = self.runCodexAuth(["remove", revoked.email])
                DispatchQueue.main.async {
                    self.isSwitching = false
                    self.endSwitchAnimation()
                    self.authWarningTitle = "⚠︎ \(self.limitedLabel(self.customLabel(forEmail: revoked.email) ?? revoked.selector)) auth revoked · sign in"
                    self.accounts.removeAll { $0.email == revoked.email }
                    self.clearCustomLabel(forEmail: revoked.email)
                    self.rebuildMenu()
                    self.refreshAccounts(forceAPI: true)
                }
                return
            }
            if let error = validation.error {
                DispatchQueue.main.async {
                    self.isSwitching = false
                    self.endSwitchAnimation()
                    self.showAlert(title: "Cannot switch account", message: error)
                    self.refreshAccounts(forceAPI: true)
                }
                return
            }
            guard let validatedTarget = validation.account else {
                DispatchQueue.main.async {
                    self.isSwitching = false
                    self.endSwitchAnimation()
                    self.showAlert(title: "Cannot switch account", message: "The target account could not be found in codex-auth.")
                    self.refreshAccounts(forceAPI: true)
                }
                return
            }
            self.persistHandoffState(
                reason: handoffReason,
                sourceThreadID: sourceThreadID,
                previousEmail: activeAccount?.email,
                targetEmail: validatedTarget.email,
                active: activeAccount,
                recommended: validatedTarget,
                accounts: self.accounts
            )

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
            let switchResult = self.runCodexAuth(["switch", validatedTarget.email])
            if switchResult.status != 0 {
                DispatchQueue.main.async {
                    self.isSwitching = false
                    self.endSwitchAnimation()
                    self.showAlert(title: "Switch failed", message: switchResult.output)
                    self.refreshAccounts()
                }
                return
            }
            if let mismatch = self.activeAuthMismatchMessage(expectedEmail: validatedTarget.email) {
                DispatchQueue.main.async {
                    self.isSwitching = false
                    self.endSwitchAnimation()
                    self.showAlert(title: "Switch did not update Codex auth", message: mismatch)
                    self.refreshAccounts(forceAPI: true)
                }
                return
            }

            let restartResult = self.restartCodexApp(threadID: sourceThreadID)
            var handoffResult: CommandResult?
            if restartResult.status == 0, runContinuation {
                handoffResult = self.continueCodexAfterSwitch(
                    from: activeAccount?.email,
                    to: validatedTarget.email,
                    threadID: sourceThreadID
                )
            }
            DispatchQueue.main.async {
                self.isSwitching = false
                self.endSwitchAnimation()
                self.authWarningTitle = nil
                if restartResult.status != 0 {
                    self.showAlert(title: "Codex relaunch failed", message: restartResult.output)
                } else if let handoffResult, handoffResult.status != 0 {
                    self.sendNotification(
                        title: "Auto handoff could not start",
                        body: handoffResult.output.isEmpty ? "The handoff state was saved, but Codex resume did not launch." : handoffResult.output
                    )
                }
                self.refreshAccounts()
            }
        }
    }

    func runCurrentAccountHandoffTest() -> CommandResult {
        var listResult = runCodexAuth(["list"])
        if listResult.status != 0 {
            listResult = runCodexAuth(["list", "--skip-api"])
        }
        guard listResult.status == 0 else { return listResult }

        let liveAccounts = parseAccounts(listResult.output)
        guard let active = liveAccounts.first(where: { $0.isActive && !$0.isExpired }) else {
            return CommandResult(status: 1, output: "No active, valid Codex account was found for the handoff test.")
        }

        let sourceThreadID = mostRecentCodexThreadID()

        persistHandoffState(
            reason: "signed end-to-end handoff test",
            sourceThreadID: sourceThreadID,
            previousEmail: active.email,
            targetEmail: active.email,
            active: active,
            recommended: active,
            accounts: liveAccounts
        )

        let switchResult = runCodexAuth(["switch", active.email])
        guard switchResult.status == 0 else { return switchResult }

        let restartResult = restartCodexApp(threadID: sourceThreadID)
        guard restartResult.status == 0 else { return restartResult }
        return continueCodexAfterSwitch(from: active.email, to: active.email, threadID: sourceThreadID)
    }

    func runAccountPolicyTests() -> CommandResult {
        let calendar = Calendar.current
        guard let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 17, minute: 0)) else {
            return CommandResult(status: 1, output: "Could not construct the account-policy test date.")
        }

        func account(
            selector: String,
            email: String,
            plan: String = "Plus",
            fiveHour: Int?,
            fiveHourUsage: String,
            weekly: Int?,
            weeklyUsage: String
        ) -> CodexAccount {
            CodexAccount(
                selector: selector,
                email: email,
                plan: plan,
                fiveHourUsage: fiveHourUsage,
                weeklyUsage: weeklyUsage,
                fiveHourRemainingPercent: fiveHour,
                weeklyRemainingPercent: weekly,
                lastActivity: "-",
                isActive: false
            )
        }

        let apiKey = account(
            selector: "03",
            email: "sk-example(api@example.com)",
            plan: "API_KEY",
            fiveHour: nil,
            fiveHourUsage: "-",
            weekly: nil,
            weeklyUsage: "-"
        )
        let restoresFirst = account(
            selector: "05",
            email: "first@example.com",
            fiveHour: 0,
            fiveHourUsage: "0% (18:27)",
            weekly: 84,
            weeklyUsage: "84% (13:27 on 2 Jul)"
        )
        let restoresLater = account(
            selector: "06",
            email: "later@example.com",
            fiveHour: 3,
            fiveHourUsage: "3% (19:36)",
            weekly: 69,
            weeklyUsage: "69% (09:36 on 2 Jul)"
        )
        guard let fallback = automaticSwitchTarget(in: [apiKey, restoresLater, restoresFirst], now: now, targetFloor: 4),
              fallback.account.selector == restoresFirst.selector,
              fallback.waitsForReset else {
            return CommandResult(status: 1, output: "Fallback selection did not choose the next-restoring non-API account.")
        }

        let available = account(
            selector: "01",
            email: "available@example.com",
            fiveHour: 25,
            fiveHourUsage: "25% (22:00)",
            weekly: 40,
            weeklyUsage: "40% (12:00 on 3 Jul)"
        )
        guard let normal = automaticSwitchTarget(in: [apiKey, restoresFirst, available], now: now, targetFloor: 4),
              normal.account.selector == available.selector,
              !normal.waitsForReset else {
            return CommandResult(status: 1, output: "Normal selection did not prefer an available non-API account.")
        }

        let codexLookup = run("/usr/bin/which", ["codex"])
        guard codexLookup.status == 0,
              !codexLookup.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CommandResult(status: 1, output: "The menu-bar runtime environment still cannot resolve the codex executable.")
        }

        return CommandResult(
            status: 0,
            output: "Account policy tests passed: API-key accounts are manual-only, fallback chooses the next reset, and Add Account can resolve codex."
        )
    }

    func runAuthStateDiagnostics() -> CommandResult {
        var result = runCodexAuth(["list"])
        if result.status != 0 {
            result = runCodexAuth(["list", "--skip-api"])
        }
        guard result.status == 0 else { return result }

        let parsed = parseAccounts(result.output)
        let reconciled = reconciledAccountsWithActiveAuth(parsed)
        let codexAuthActive = parsed.first(where: \.isActive)?.email ?? "none"
        let switcherActive = reconciled.accounts.first(where: \.isActive)?.email ?? "none"
        let expired = parsed.filter(\.isExpired).map(\.email)
        let apiAutoEligible = automaticSwitchTarget(in: parsed.filter(\.isAPIKeyAccount), targetFloor: 4) != nil

        let identity = currentActiveAuthIdentity()
        let mode = identity?.authMode ?? "unknown"
        let accountID = identity?.accountID ?? "none"
        let registryEmail = identity?.accountID.flatMap { registryEntriesByAccountID()[$0]?.email } ?? "none"
        let warning = reconciled.warning ?? "none"

        let output = """
        Auth diagnostics:
        - auth.json mode: \(mode)
        - auth.json account id: \(accountID)
        - auth.json registry email: \(registryEmail)
        - codex-auth active row: \(codexAuthActive)
        - switcher reconciled active: \(switcherActive)
        - warning: \(warning)
        - expired/revoked rows: \(expired.isEmpty ? "none" : expired.joined(separator: ", "))
        - API key eligible for automatic switch: \(apiAutoEligible ? "yes" : "no")
        """
        return CommandResult(status: 0, output: output)
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
                  let activeKey = json["active_account_key"] as? String,
                  let accountObjects = json["accounts"] as? [[String: Any]] else {
                return "Could not read active_account_key from registry.json."
            }
            guard let registryAccount = accountObjects.first(where: { $0["account_key"] as? String == activeKey }),
                  (registryAccount["auth_mode"] as? String)?.lowercased() != "apikey",
                  let registryAccountID = registryAccount["chatgpt_account_id"] as? String,
                  !registryAccountID.isEmpty else {
                return nil
            }

            let encoded = Data(activeKey.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
            let accountAuthURL = URL(fileURLWithPath: "\(home)/.codex/accounts/\(encoded).auth.json")
            guard FileManager.default.fileExists(atPath: activeAuthURL.path) else {
                return "Active auth file does not exist at \(activeAuthURL.path)."
            }
            guard let activeAuthData = try? Data(contentsOf: activeAuthURL),
                  let activeAuth = try? JSONSerialization.jsonObject(with: activeAuthData) as? [String: Any],
                  let identity = currentActiveAuthIdentity(),
                  !identity.isAPIKeyMode,
                  identity.accountID == registryAccountID,
                  (activeAuth["auth_mode"] as? String)?.lowercased() != "apikey" else {
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

    private func restartCodexApp(threadID: String? = nil) -> CommandResult {
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

        if let threadID {
            let deepLinkResult = openCodexThread(threadID)
            if deepLinkResult.status != 0 {
                transcript.append("Could not open handoff thread \(threadID): \(deepLinkResult.output)")
            } else {
                Thread.sleep(forTimeInterval: 2)
            }
        }

        return CommandResult(status: 0, output: transcript.joined(separator: "\n"))
    }

    private func openCodexThread(_ threadID: String) -> CommandResult {
        let uuidPattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#
        guard threadID.range(of: uuidPattern, options: .regularExpression) != nil else {
            return CommandResult(status: 2, output: "Invalid Codex thread id: \(threadID)")
        }
        return run("/usr/bin/open", ["codex://threads/\(threadID)"])
    }

    private func continueCodexAfterSwitch(from oldEmail: String?, to newEmail: String, threadID: String?) -> CommandResult {
        let handoffNote = """
        Account handoff complete. Reopened the source Codex thread so its existing Goal state can continue without visible composer automation.
        """
        do {
            try ensureAppSupportDirectory()
            try handoffNote.write(to: handoffPromptURL, atomically: true, encoding: .utf8)
        } catch {
            return CommandResult(status: 1, output: error.localizedDescription)
        }

        let logURL = URL(fileURLWithPath: "/tmp/codex-account-switcher-handoff.log")
        let header = "Codex Account Switcher handoff\nprevious: \(oldEmail ?? "unknown")\ncurrent: \(newEmail)\nprimary: reopen source thread\ncontinuation: existing Goal state\ncomposer automation: disabled\n---\n"
        try? header.write(to: logURL, atomically: true, encoding: .utf8)

        let resolvedThreadID = threadID ?? mostRecentCodexThreadID()
        if let resolvedThreadID {
            appendHandoffLog("Source thread: \(resolvedThreadID)", to: logURL)
            if let status = goalStatus(for: resolvedThreadID) {
                appendHandoffLog("Existing goal status: \(status)", to: logURL)
            }
            let openResult = openCodexThread(resolvedThreadID)
            if openResult.status == 0 {
                appendHandoffLog("Opened source thread \(resolvedThreadID).", to: logURL)
                Thread.sleep(forTimeInterval: 2)
            } else {
                appendHandoffLog("Could not open source thread \(resolvedThreadID): \(openResult.output)", to: logURL)
            }
        } else {
            appendHandoffLog("No source thread id was available; using the visible Codex thread.", to: logURL)
        }

        appendHandoffLog("Composer automation skipped; no UI scripting permission is required.", to: logURL)
        return CommandResult(status: 0, output: "Codex thread reopened without composer automation or UI scripting permission.")
    }

    private func mostRecentCodexThreadID() -> String? {
        let sessionsURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var newest: (url: URL, date: Date)?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let date = values.contentModificationDate else { continue }
            if newest == nil || date > newest!.date {
                newest = (url, date)
            }
        }

        guard let filename = newest?.url.deletingPathExtension().lastPathComponent,
              let match = filename.range(
                of: #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
                options: .regularExpression
              ) else { return nil }
        return String(filename[match])
    }

    private func goalStatus(for threadID: String) -> String? {
        let databasePaths = [
            "\(NSHomeDirectory())/.codex/goals_1.sqlite",
            "\(NSHomeDirectory())/.codex/sqlite/goals_1.sqlite"
        ]
        let safeThreadID = threadID.replacingOccurrences(of: "'", with: "''")
        for path in databasePaths where FileManager.default.fileExists(atPath: path) {
            let result = run("/usr/bin/sqlite3", [
                path,
                "SELECT status FROM thread_goals WHERE thread_id = '\(safeThreadID)' LIMIT 1;"
            ])
            let status = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.status == 0, !status.isEmpty {
                return status
            }
        }
        return nil
    }

    private func appendHandoffLog(_ message: String, to url: URL) {
        guard let data = ("\(message)\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
        } else {
            _ = try? data.write(to: url)
        }
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
                fiveHourRemainingPercent: fiveHour.remainingPercent,
                weeklyRemainingPercent: weekly.remainingPercent,
                lastActivity: lastActivity.isEmpty ? "-" : lastActivity,
                isActive: isActive
            )
        }
    }

    private static func parseUsage(_ tokens: [String], from startIndex: Int) -> (text: String, remainingPercent: Int?, nextIndex: Int) {
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
        guard !digits.isEmpty, let val = Int(digits), val <= 100 else { return nil }
        return val
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
        let home = NSHomeDirectory()
        let requiredPathDirectories = [
            "\(home)/.local/bin",
            "/Applications/Codex.app/Contents/Resources",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let inheritedPathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        environment["PATH"] = (requiredPathDirectories + inheritedPathDirectories)
            .reduce(into: [String]()) { result, directory in
                if !directory.isEmpty, !result.contains(directory) {
                    result.append(directory)
                }
            }
            .joined(separator: ":")
        if let codexCLI = codexCLIPath() {
            environment["CODEX_CLI_PATH"] = codexCLI
        }
        if let brewNode = nodeExecutablePath() {
            environment["CODEX_AUTH_NODE_EXECUTABLE"] = brewNode
        } else {
            let bundledNode = "/Applications/Codex.app/Contents/Resources/node"
            if FileManager.default.isExecutableFile(atPath: bundledNode) {
                environment["CODEX_AUTH_NODE_EXECUTABLE"] = bundledNode
            }
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

    private func promptForPercent(title: String, message: String, currentValue: Int, onSave: (Int) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        field.stringValue = "\(currentValue)"
        field.placeholderString = "0-100"
        alert.accessoryView = field

        if alert.runModal() == .alertFirstButtonReturn {
            let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Int(raw) else {
                showAlert(title: "Invalid percentage", message: "Please enter a whole number from 0 to 100.")
                return
            }
            onSave(clampedPercent(value))
        }
    }

    private func clampedPercent(_ value: Int) -> Int {
        max(0, min(100, value))
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

    private func removeDeadAccounts(_ deadAccounts: [CodexAccount], activeWasDead: Bool, candidates: [CodexAccount]) {
        let pending = deadAccounts.filter { !removingDeadAccountEmails.contains($0.email) }
        guard !pending.isEmpty else { return }

        pending.forEach { removingDeadAccountEmails.insert($0.email) }
        let bestAfterCleanup = activeWasDead
            ? automaticSwitchTarget(in: candidates)?.account
            : nil

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            for account in pending {
                _ = self.runCodexAuth(["remove", account.email])
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for account in pending {
                    self.removingDeadAccountEmails.remove(account.email)
                    self.clearCustomLabel(forEmail: account.email)
                    self.previousAccounts.removeValue(forKey: account.email)
                    self.notifiedExpiredEmails.remove(account.email)
                }

                if activeWasDead, !self.isSwitching, let bestAfterCleanup {
                    self.sendNotification(
                        title: "Removed expired auth",
                        body: "Removed a dead account and switching to \(self.displayLabel(for: bestAfterCleanup))."
                    )
                    self.switchTo(selector: bestAfterCleanup.selector)
                } else {
                    self.refreshAccounts(forceAPI: true)
                }
            }
        }
    }

    private func ensureAppSupportDirectory() throws {
        try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
    }

    private func handoffPrompt(reason: String, sourceThreadID: String?, previousEmail: String?, targetEmail: String?) -> String {
        """
        Continue the previous Codex task after an account handoff.

        Handoff reason: \(reason)
        Source thread: \(sourceThreadID ?? "unknown")
        Previous account: \(previousEmail ?? "unknown")
        Current account: \(targetEmail ?? "unknown")

        Resume from the latest recorded Codex session and continue the user's most recent task. Preserve the prior intent, avoid restarting from scratch, and report only if required context is missing.
        """
    }

    private func persistHandoffState(
        reason: String,
        sourceThreadID: String? = nil,
        previousEmail: String?,
        targetEmail: String?,
        active: CodexAccount?,
        recommended: CodexAccount?,
        accounts: [CodexAccount]
    ) {
        let prompt = handoffPrompt(reason: reason, sourceThreadID: sourceThreadID, previousEmail: previousEmail, targetEmail: targetEmail)
        let state = HandoffState(
            updatedAt: Date(),
            reason: reason,
            sourceThreadID: sourceThreadID,
            previousEmail: previousEmail,
            targetEmail: targetEmail,
            activeEmail: active?.email,
            activeLowestRemainingPercent: active?.lowestRemainingPercent,
            recommendedEmail: recommended?.email,
            recommendedLowestRemainingPercent: recommended?.lowestRemainingPercent,
            accounts: accounts.map {
                HandoffAccountState(
                    email: $0.email,
                    label: displayLabel(for: $0),
                    plan: $0.plan,
                    fiveHourRemainingPercent: $0.fiveHourRemainingPercent,
                    weeklyRemainingPercent: $0.weeklyRemainingPercent,
                    isActive: $0.isActive
                )
            },
            continuationPrompt: prompt
        )

        do {
            try ensureAppSupportDirectory()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try data.write(to: handoffStateURL, options: .atomic)
            try prompt.write(to: handoffPromptURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Codex Account Switcher handoff state failed: \(error.localizedDescription)")
        }
    }

    private func shellEscaped(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Node.js Resolution

    private func nodeExecutablePath() -> String? {
        let paths = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node"
        ]
        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func codexCLIPath() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    // MARK: - Notifications and Scoring

    private func sendNotification(title: String, body: String, action: String? = nil, targetEmail: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default
        if let action = action, let targetEmail = targetEmail {
            content.userInfo = ["action": action, "targetEmail": targetEmail]
        }
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to deliver notification: \(error)")
            }
        }
    }

    private func score(for account: CodexAccount) -> Double {
        if account.isExpired { return -999.0 }
        guard account.hasComparableUsageCaps,
              let fiveHourRemaining = account.fiveHourRemainingPercent,
              let weeklyRemaining = account.weeklyRemainingPercent else {
            return -999.0
        }
        let lowest = Double(min(fiveHourRemaining, weeklyRemaining))
        let average = (Double(fiveHourRemaining) + Double(weeklyRemaining)) / 2.0
        return lowest * 0.7 + average * 0.3
    }

    private func shouldRecommendSwitch(from active: CodexAccount) -> Bool {
        guard let lowest = active.lowestRemainingPercent else { return false }
        return lowest <= recommendationThresholdPercent
    }

    private func shouldAutoSwitch(from active: CodexAccount) -> Bool {
        guard autoSwitchEnabled else { return false }
        guard let lowest = active.lowestRemainingPercent else { return false }
        return lowest < autoSwitchThresholdPercent
    }

    private func bestRecommendation(excluding email: String? = nil) -> CodexAccount? {
        automaticCandidates(excluding: email)
            .filter { ($0.lowestRemainingPercent ?? 0) >= autoSwitchTargetFloorPercent }
            .max { score(for: $0) < score(for: $1) }
    }

    private func automaticCandidates(excluding email: String? = nil) -> [CodexAccount] {
        accounts.filter { account in
            !account.isExpired &&
            !account.isAPIKeyAccount &&
            account.email != email &&
            account.hasComparableUsageCaps
        }
    }

    private func automaticSwitchTarget(excluding email: String? = nil, now: Date = Date()) -> (account: CodexAccount, waitsForReset: Bool)? {
        automaticSwitchTarget(in: automaticCandidates(excluding: email), now: now)
    }

    private func automaticSwitchTarget(in candidates: [CodexAccount], now: Date = Date(), targetFloor: Int? = nil) -> (account: CodexAccount, waitsForReset: Bool)? {
        let floor = targetFloor ?? autoSwitchTargetFloorPercent
        let eligible = candidates.filter {
            !$0.isExpired &&
            !$0.isAPIKeyAccount &&
            $0.hasComparableUsageCaps
        }
        if let available = eligible
            .filter({ ($0.lowestRemainingPercent ?? 0) >= floor })
            .max(by: { score(for: $0) < score(for: $1) }) {
            return (available, false)
        }

        let fallback = eligible.min { lhs, rhs in
            let lhsReset = nextDepletedLimitReset(for: lhs, now: now, targetFloor: floor) ?? .distantFuture
            let rhsReset = nextDepletedLimitReset(for: rhs, now: now, targetFloor: floor) ?? .distantFuture
            if lhsReset != rhsReset {
                return lhsReset < rhsReset
            }
            return score(for: lhs) > score(for: rhs)
        }
        return fallback.map { ($0, true) }
    }

    private func nextDepletedLimitReset(for account: CodexAccount, now: Date, targetFloor: Int? = nil) -> Date? {
        let floor = targetFloor ?? autoSwitchTargetFloorPercent
        let limits: [(remaining: Int?, usage: String)] = [
            (account.fiveHourRemainingPercent, account.fiveHourUsage),
            (account.weeklyRemainingPercent, account.weeklyUsage)
        ]
        return limits.compactMap { limit in
            guard let remaining = limit.remaining, remaining < floor else { return nil }
            return nextResetDate(from: limit.usage, now: now)
        }.min()
    }

    private func nextResetDate(from usage: String, now: Date) -> Date? {
        guard let resetText = parenthesizedValue(from: usage) else { return nil }
        let calendar = Calendar.current
        let locale = Locale(identifier: "en_US_POSIX")

        if resetText.contains(" on ") {
            let currentYear = calendar.component(.year, from: now)
            for format in ["HH:mm 'on' d MMM yyyy", "HH:mm 'on' MMM d yyyy"] {
                let formatter = DateFormatter()
                formatter.locale = locale
                formatter.calendar = calendar
                formatter.timeZone = calendar.timeZone
                formatter.dateFormat = format
                if let parsed = formatter.date(from: "\(resetText) \(currentYear)") {
                    return parsed > now
                        ? parsed
                        : calendar.date(byAdding: .year, value: 1, to: parsed)
                }
            }
            return nil
        }

        let components = resetText.split(separator: ":")
        guard components.count == 2,
              let hour = Int(components[0]),
              let minute = Int(components[1]),
              var reset = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else {
            return nil
        }
        if reset <= now {
            reset = calendar.date(byAdding: .day, value: 1, to: reset) ?? reset
        }
        return reset
    }

    private func processAccountUpdates(old: [CodexAccount], new: [CodexAccount], isLiveRefresh: Bool) {
        let isFirstLoad = previousAccounts.isEmpty
        
        if isFirstLoad {
            for acc in new {
                previousAccounts[acc.email] = acc
            }
        }
        
        for account in new {
            if let prev = previousAccounts[account.email] {
                if let prev5H = prev.fiveHourRemainingPercent, let new5H = account.fiveHourRemainingPercent {
                    if prev5H < 100 && new5H == 100 {
                        self.sendNotification(
                            title: "Usage Limit Refreshed ⚡️",
                            body: "Account \(account.email) usage limit is back. Start vibing!"
                        )
                        self.startVibingAnimation(label: self.displayLabel(for: account), type: "5H")
                    }
                }
                
                if let prevW = prev.weeklyRemainingPercent, let newW = account.weeklyRemainingPercent {
                    if prevW < 100 && newW == 100 {
                        self.sendNotification(
                            title: "Weekly Limit Restored 🌟",
                            body: "The weekly usage limit for \(account.email) has been restored."
                        )
                        self.startVibingAnimation(label: self.displayLabel(for: account), type: "Weekly")
                    }
                }
            }
            
            if account.isExpired {
                if !self.notifiedExpiredEmails.contains(account.email) {
                    self.sendNotification(
                        title: "Authentication Expired ⚠️",
                        body: "Please re-login for \(account.email).",
                        action: "relogin",
                        targetEmail: account.email
                    )
                    self.notifiedExpiredEmails.insert(account.email)
                }
            } else {
                self.notifiedExpiredEmails.remove(account.email)
            }
            
            previousAccounts[account.email] = account
        }
        
        if let active = new.first(where: { $0.isActive }), shouldRecommendSwitch(from: active) {
            if !isLiveRefresh {
                refreshAccounts(forceAPI: true)
                return
            }
            if shouldAutoSwitch(from: active),
               let target = automaticSwitchTarget(excluding: active.email) {
                let best = target.account
                let activeLowest = active.lowestRemainingPercent ?? 0
                let bestLowest = best.lowestRemainingPercent ?? 0
                let bestLabel = displayLabel(for: best)
                persistHandoffState(reason: "low usage", previousEmail: active.email, targetEmail: best.email, active: active, recommended: best, accounts: new)
                let key = "\(active.email)->\(best.email)|\(activeLowest)"
                if lastAutoSwitchKey != key && !isSwitching {
                    lastAutoSwitchKey = key
                    let detail = target.waitsForReset
                        ? "No account is at/above \(autoSwitchTargetFloorPercent)%. Switching to \(bestLabel), the non-API account whose depleted limit resets next."
                        : "\(displayLabel(for: active)) is below \(autoSwitchThresholdPercent)% on one limit. Switching to \(bestLabel) (\(bestLowest)% lowest cap)."
                    self.sendNotification(
                        title: "Auto-switching account ⚡️",
                        body: detail
                    )
                    self.switchTo(selector: best.selector, handoffReason: "automatic account switch", runContinuation: true)
                }
            } else if let best = bestRecommendation(excluding: active.email),
                      lastSuggestedEmail != best.email {
                let bestLabel = displayLabel(for: best)
                self.sendNotification(
                    title: "Low Usage Limit (≤\(recommendationThresholdPercent)%) ⚡️",
                    body: "Switch to \(bestLabel): 5-hour \(remainingPercentText(fromRemaining: best.fiveHourRemainingPercent)), weekly \(remainingPercentText(fromRemaining: best.weeklyRemainingPercent)).",
                    action: "switch",
                    targetEmail: best.email
                )
                lastSuggestedEmail = best.email
                lastAutoSwitchKey = nil
            } else {
                lastSuggestedEmail = nil
                lastAutoSwitchKey = nil
            }
        } else {
            lastSuggestedEmail = nil
            lastAutoSwitchKey = nil
        }
    }

    private func startVibingAnimation(label: String, type: String) {
        vibeAnimationTimer?.invalidate()
        vibeAnimationFrame = 0
        
        let frames: [String]
        if type == "5H" {
            frames = ["🎧 \(label) 🎧", "✨ \(label) ✨", "⚡️ \(label) ⚡️", "🕺 \(label) 🕺"]
        } else {
            frames = ["🌟 \(label) 🌟", "🎉 \(label) 🎉", "🎈 \(label) 🎈", "🧸 \(label) 🧸"]
        }
        
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            self.vibeAnimationFrame += 1
            if self.vibeAnimationFrame > 24 {
                t.invalidate()
                self.vibeAnimationTimer = nil
                if let active = self.accounts.first(where: { $0.isActive }) {
                    self.setStatusTitleAnimated(self.statusTitle(for: active))
                } else {
                    self.setStatusTitleAnimated("")
                }
                return
            }
            let frame = frames[self.vibeAnimationFrame % frames.count]
            self.statusItem.button?.title = frame
        }
        RunLoop.current.add(timer, forMode: .common)
        vibeAnimationTimer = timer
    }

    private func promptRelogin(for account: CodexAccount) {
        let alert = NSAlert()
        alert.messageText = "Authentication Expired"
        alert.informativeText = "The authentication for \(account.email) has expired. Would you like to re-login cleanly?"
        alert.addButton(withTitle: "Re-login")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            reloginAccount(account.email)
        }
    }

    private func reloginAccount(_ email: String) {
        let path = codexAuthPath() ?? "codex-auth"
        let home = NSHomeDirectory()
        let restartPath = "\(home)/.codex/skills/codex-account-switcher/scripts/codex_account_switch.sh"
        let script = """
        tell application "Terminal"
          activate
          do script "echo 'Re-logging in for \(email)...'; \(shellEscaped(path)) login --device-auth && \(shellEscaped(restartPath)) restart-app; echo; echo 'Codex account login finished and Codex App was relaunched. You can close this window.'"
        end tell
        """
        let result = run("/usr/bin/osascript", ["-e", script])
        if result.status != 0 {
            showAlert(title: "Re-login failed", message: result.output)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refreshAccounts()
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let action = userInfo["action"] as? String {
            if action == "switch", let email = userInfo["targetEmail"] as? String {
                DispatchQueue.main.async { [weak self] in
                    if let account = self?.accounts.first(where: { $0.email == email }) {
                        self?.switchTo(selector: account.selector)
                    }
                }
            } else if action == "relogin", let email = userInfo["targetEmail"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.reloginAccount(email)
                }
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
if CommandLine.arguments.contains("--test-account-policy") {
    let result = delegate.runAccountPolicyTests()
    print(result.output)
    exit(result.status)
}
if CommandLine.arguments.contains("--test-current-account-handoff") {
    let result = delegate.runCurrentAccountHandoffTest()
    print(result.output)
    exit(result.status)
}
if CommandLine.arguments.contains("--diagnose-auth-state") {
    let result = delegate.runAuthStateDiagnostics()
    print(result.output)
    exit(result.status)
}
app.delegate = delegate
app.run()
