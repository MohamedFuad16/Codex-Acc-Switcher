<p align="center">
  <img src="https://raw.githubusercontent.com/MohamedFuad16/Codex-Acc-Switcher/MoneyMap/Sources/icon.png" alt="Codex Account Switcher Logo" width="96" height="96" style="border-radius: 20%;" onerror="this.style.display='none'"/>
</p>

<h1 align="center">Codex Account Switcher</h1>

<p align="center">
  <strong>A premium, native macOS menu bar utility to switch active Codex accounts in a single click.</strong>
</p>

<p align="center">
  <a href="https://developer.apple.com/swift/"><img src="https://img.shields.io/badge/Language-Swift_5.9+-orange.svg?style=flat-square" alt="Swift"/></a>
  <a href="https://www.apple.com/macos/"><img src="https://img.shields.io/badge/Platform-macOS_14.0+-black.svg?style=flat-square&logo=apple" alt="macOS"/></a>
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square" alt="MIT License"/></a>
  <a href="https://github.com/MohamedFuad16/Codex-Acc-Switcher/actions"><img src="https://img.shields.io/badge/Build-passing-success.svg?style=flat-square" alt="Build Status"/></a>
  <a href="#"><img src="https://img.shields.io/badge/Dependencies-none-brightgreen.svg?style=flat-square" alt="Dependencies"/></a>
</p>

<p align="center">
  <a href="#-key-features">Key Features</a> •
  <a href="#%EF%B8%8F-how-it-works">How It Works</a> •
  <a href="#-installation">Installation</a> •
  <a href="#%EF%B8%8F-development">Development</a> •
  <a href="#-license">License</a>
</p>

---

## 📖 Overview

**Codex Account Switcher** is an ultra-lightweight, blazing-fast macOS menu bar utility built in pure Swift. It eliminates the friction of managing multiple OpenAI Codex / ChatGPT credentials on your local machine.

With zero external dependencies and a footprint under 300 KB, it integrates directly with macOS system APIs to hot-swap account tokens, safely restart active desktop applications, and display real-time usage budgets directly in your status bar.

---

## ✨ Key Features

### 🎛️ One-Click Account Switching
- Instantly swap between saved profiles with a single click from the menu bar.
- Automatically terminates, purges, and restarts the active Codex desktop app to apply the new session.

### 🎨 Redesigned Menu UI
- **Account cards** — Each account is shown as a rich card with a coloured avatar circle (deterministic hue from your email), email, plan badge, and a green **Active** pill.
- **Glass-effect usage bars** — Animated progress bars with gradient fills and a liquid-glass specular highlight stripe that fill with a smooth ease-out cubic animation when the menu opens.
- **Section headers** — Styled uppercase labels with SF Symbol icons for visual hierarchy.
- **SF Symbol icons** on all action items for a native macOS look.

### 🌗 Dark & Light Mode
- Full adaptive rendering for both macOS appearances.
- Avatar colours, glass highlights, progress bars, and all text use dynamic `NSColor` providers and semantic system colours that automatically adjust.

### 🔄 Smooth Animations
- **Braille spinner** (`⠋ ⠙ ⠹ ⠸ ⠼ ⠴ …`) rotating at 80 ms intervals during account switches.
- **Core Animation opacity pulse** on the status-bar button while switching (0.7 s ease-in-out cycle).
- **Crossfade title transitions** — status-bar text fades out, swaps, then fades back in.
- **Animated progress fill** — usage bars sweep from zero with an ease-out cubic curve on menu open.
- All timers registered in `.common` run-loop mode so animations keep running even during menu tracking.

### 📊 Real-Time Usage Tracking
- Track remaining 5-Hour and Weekly usage limits directly in the status bar.
- Select which metric appears in the menu bar by clicking the corresponding usage row.
- When API data is unavailable, usage is displayed as **NIL** with a dashed placeholder bar instead of misleading zeroes.

### 🔁 Custom Menu Bar Icon
- Crisp, template-mode SF Symbol icon (`arrow.triangle.2.circlepath`) that automatically adapts to light/dark menu bar and highlights.
- Falls back to a hand-drawn CoreGraphics glyph if SF Symbols are unavailable.

### 🗺️ Smart Environment Detection
- **Zero hardcoding**: Dynamically traverses your local nvm (`~/.nvm`) Node installations (sorted latest-first) to locate `codex-auth`.
- **Intelligent shell fallback**: Falls back to an interactive zsh login shell (`/bin/zsh -l`) to resolve `PATH` if customised.

### 🏷️ Custom Account Labels
- Add custom aliases, numbers, or emojis (e.g. `01`, `Work`, `🚀`) to identify accounts instantly in the status bar.

---

## ⚙️ How It Works

The Swift menu bar app orchestrates token swapping and app lifecycle management securely via local POSIX subprocess bindings:

```
[ macOS Menu Bar ]
       │
       ├─► [1] Snapshots active token to per-account storage (base64-keyed)
       ├─► [2] Calls `codex-auth switch <selector>` to swap credentials
       ├─► [3] Terminates Codex processes (SIGTERM → SIGKILL, filtering own PID)
       ├─► [4] Relaunches via `codex-auth app` with `open -a` fallback
       └─► [5] Runs braille spinner + CA opacity pulse on the main run loop
```

---

## 🚀 Installation

### 1. Clone the repository
```bash
git clone https://github.com/MohamedFuad16/Codex-Acc-Switcher.git
cd Codex-Acc-Switcher
```

### 2. Build the Application Bundle
```bash
./build.sh
```
This compiles `Sources/main.swift` with `swiftc` and assembles `Codex Account Switcher.app` in `./build/`.

### 3. Deploy to Applications
```bash
./install.sh
```
Copies the app to `~/Applications/`.

### 4. Run without installing
```bash
./run.sh
```

---

## 🛠️ Development

This utility is built entirely in Swift with **zero external dependencies** — no CocoaPods, no SPM packages, no dynamic frameworks. It compiles directly with `swiftc` for an incredibly responsive, native app with negligible memory footprint.

| | |
|---|---|
| **Language** | Swift 5.9+ |
| **Frameworks** | AppKit, QuartzCore (Core Animation) |
| **Compiler** | `swiftc` targeting `arm64-apple-macosx14.0` |
| **Min OS** | macOS 14.0 (Sonoma) |
| **Dependencies** | None |
| **App size** | < 300 KB |

### Project Structure
```
Sources/
  main.swift          — Single-file app: data models, custom views, app delegate
build.sh              — Compiles + assembles .app bundle with Info.plist
install.sh            — Copies built app to ~/Applications
run.sh                — Build + launch in one step
```

---

## 📝 License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

Developed with ❤️ by **[MohamedFuad16](https://github.com/MohamedFuad16)**. Contributions and issues are always welcome!
