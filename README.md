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

With zero external package dependencies, it integrates directly with standard macOS system APIs to hot-swap account tokens, safely restart active desktop applications, feed real-time usage budgets into your status bar, and manage isolated multi-instance app clones from a native Mac window.

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
*   Timers are registered in the `.common` run loop mode, ensuring background checks keep updating even when you are interacting with the menu!

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

### 🧩 Isolated App Instance Manager
*   Open **Open Instance Manager** from the menu bar dropdown to clone any `.app` bundle.
*   Create 1-12 managed clones with unique bundle identifiers and separate app data roots.
*   Launch selected clones or all clones at once.
*   For Codex/Electron-style apps, each clone is launched with isolated `HOME`, `CODEX_HOME`, `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, `TMPDIR`, and `--user-data-dir` values so memory, local settings, cache, and Chromium profile data stay separated.
*   Reveal clone bundles, open their data folders, or remove clone bundles while optionally preserving their data.

---

## ⚙️ How It Works

The Swift menu bar orchestrates token swapping and app lifecycle management securely via local POSIX subprocess bindings:

```
[ macOS Menu Bar ]
       │
       ├─► [1] Swaps active credentials safely in registry.json & auth.json
       ├─► [2] Triggers background process termination signals (SIGTERM/SIGKILL)
       ├─► [3] Relaunches desktop app via CLI fallback (`open -a Codex`)
       ├─► [4] Starts smooth Braille spinner on Main Thread (.common Run Loop)
       └─► [5] Opens the native Instance Manager for isolated app clones
```

The Instance Manager uses a bundle-clone strategy: each clone gets a rewritten `CFBundleIdentifier` and display name, is ad-hoc signed locally, and is registered with Launch Services. Runtime isolation is handled by launching the clone process with a dedicated data directory and environment variables. This works best for apps that respect process environment paths or Electron/Chromium `--user-data-dir`; some apps may still use hardcoded shared locations.

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
