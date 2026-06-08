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

With zero external package dependencies, it integrates directly with standard macOS system APIs to hot-swap account tokens, safely restart Codex, preserve refreshed auth snapshots, and keep usage budgets visible in your status bar.

---

## ✨ Key Features

### 🎛️ One-Click Switch & Hot Reload
*   Instantly swap between saved profiles in less than a second.
*   Automatically terminates, purges, and restarts active desktop Codex app processes in the background to apply the new active session instantly.

### 🌀 High-Tech Braille Loader Animation
*   Upgraded with a modern, ultra-smooth spinning loader (`⠋`, `⠙`, `⠹`, `⠸`, `⠼`, `⠴`...) rotating at `0.08s` intervals in your menu bar. 
*   Provides immediate, state-of-the-art interactive feedback during backend swapping operations.

### 📊 Real-Time Usage & Cap Meters
*   Track remaining account limits (5-Hour and Weekly) directly in your status bar or inside the dropdown column.
*   Fast local polling keeps the menu-bar display responsive without hammering remote auth APIs.
*   **Live Usage Refresh** lets you choose a throttled API refresh cadence, with **Refresh Usage Now** for an immediate live update.

### 🔐 Session Preservation
*   The switcher syncs a newer active `~/.codex/auth.json` back into the saved active account snapshot so refreshed tokens are not lost when switching away.
*   **Sync Active Session** lets you manually preserve the current active session before changing accounts.

### 🔔 Low-Usage Notifications
*   Get a macOS notification when the active account drops below your chosen usage threshold.
*   Use **Usage Reminder → Set Reminder Percentage...** to change the default 10% threshold.
*   If alerts are blocked, **Test Notification** opens System Settings so you can enable notifications for Codex Account Switcher.

### 🗺️ Dynamic Environment Resolution
*   **Zero Hardcoding**: Dynamically parses and traverses your local NVM (`~/.nvm`) Node installations to locate the executable binary.
*   **Intelligent Shell Fallback**: Falls back to zsh login streams (`/bin/zsh -l`) to query environment maps if customized `PATH` parameters are missing.

### 🏷️ Custom Account Labeling
*   Add custom aliases, numbers, or emojis (e.g. `01`, `Work`, `🚀`) to identify accounts instantly in the status line while preserving emails in standard dropdown grids.

### 🎨 Separate App & Menu Bar Icons
*   `Sources/icon.png` is packaged as the application icon.
*   `Sources/toolbar-icon.png` is bundled separately for the menu bar status item.

---

## ⚙️ How It Works

The Swift menu bar orchestrates token swapping and app lifecycle management securely via local POSIX subprocess bindings:

```
[ macOS Menu Bar ]
       │
       ├─► [1] Swaps active credentials safely in registry.json & auth.json
       ├─► [2] Triggers background process termination signals (SIGTERM/SIGKILL)
       ├─► [3] Relaunches desktop app via CLI fallback (`open -a Codex`)
       ├─► [4] Preserves newer active auth snapshots before switching
       └─► [5] Keeps usage display fresh with local polling plus throttled live refresh
```

---

## 🚀 Installation

### 1. Clone the repository
```bash
git clone https://github.com/MohamedFuad16/Codex-Acc-Switcher.git
cd Codex-Acc-Switcher
```

### 2. Build the Application Bundle
We have provided standard executables to compile and assemble the App Bundle seamlessly. Run:
```bash
./build.sh
```
This builds and places `Codex Account Switcher.app` in the `./build` directory.

### 3. Deploy to Applications
To copy the application safely to your local Applications folder (`~/Applications`):
```bash
./install.sh
```

### 4. Enable Notifications
Open the menu bar item and choose **Usage Reminder → Test Notification**. If macOS blocks alerts, choose **Open Settings** and allow notifications for **Codex Account Switcher**.

---

## 🛠️ Development

This utility is built completely in Swift with **zero external package dependencies**. The app is now package-first through Swift Package Manager, while `build.sh` still assembles the signed macOS `.app` bundle layout.

*   **Language**: Swift 5.9+
*   **APIs**: Cocoa / AppKit (`NSStatusBar`, `NSStatusItem`, `NSMenu`, `NSWindow`, `NSTableView`, `Process`, `Pipe`)
*   **Build**: Swift Package Manager targeting macOS 14.0+

Build the executable directly:
```bash
swift build --product CodexAccountSwitcher
```

To test changes rapidly without installing:
```bash
./run.sh
```

---

## 📝 License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

Developed with ❤️ by **[MohamedFuad16](https://github.com/MohamedFuad16)**. Contributions and issues are always welcome!
