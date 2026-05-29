# Codex Account Switcher (macOS Menu Bar Utility)

A lightweight, blazing-fast, and completely native macOS menu bar utility designed to switch between your saved `codex-auth` accounts with a single click. It automatically updates active auth credentials, handles process lifecycle restarts for the Codex App, and displays your active token usage limits.

---

## 🌟 Premium Features

This version has been polished and packed with professional macOS integration features:

1. **Sleek High-Tech Loader**: Features an incredibly smooth, fast-spinning Braille animation (`⠋`, `⠙`, `⠹`, `⠸`...) in the status bar while switching accounts to provide instant premium feedback.
2. **Active Usage Indicators**: Displays remaining usage remaining (5hr and Weekly) in the menu bar and dropdown items.
3. **Resilient Background Timer**: Standard Cocoa status-item menus block the main thread timer when open. We've added the refresh timers directly to the common run loop modes, ensuring background updates continue seamlessly even while interacting with the dropdown.
4. **Dynamic Environment Resolution**: Zero hardcoded paths! The utility dynamically inspects and traverses your NVM Node.js versions in `~/.nvm` to locate the `codex-auth` executable, and automatically falls back to your login shell configuration.
5. **Completely Portable**: Automatically resolves paths like script restart directories using standard native Cocoa environment properties (`NSHomeDirectory()`) so the app works flawlessly out of the box on any Mac.
6. **Robust Process Execution**: Prevents application hangs and deadlocks in stdout/stderr pipe buffers by reading data streams before executing process waits.

---

## 🚀 Getting Started

### Prerequisites

- A Mac running macOS 14.0 or newer (Apple Silicon supported).
- `codex-auth` installed on your system.

### Build & Run

Building the native Swift application has been simplified into simple executable scripts. Open your terminal in the repository directory and run:

```bash
# Build the native Mac app bundle
./build.sh

# Run the app locally to test it
./run.sh
```

### Installation

To install and add it permanently to your user Applications directory (`~/Applications/`):

```bash
./install.sh
```

---

## 🛠️ Technology Stack

- **Core**: 100% Pure native Apple Swift
- **Frameworks**: Native Cocoa & AppKit (NSStatusBar, NSMenu, NSMenuItem, Process, Pipe)
- **Dependencies**: None! Zero external framework dependencies, making the app bundle incredibly lightweight (~280KB) and highly performant.

---

## 📝 License

Developed with ❤️ for the Codex developer community. Feel free to use, share, and improve!
