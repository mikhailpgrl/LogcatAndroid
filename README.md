# Android & iOS Log Viewer

<img width="1232" height="662" alt="Capture d’écran 2026-03-04 à 12 26 31" src="https://github.com/user-attachments/assets/2d6580a5-9f6e-4e00-a850-d83bdf25b2eb" />

A macOS app to follow, inspect and compare the analytics logs of the Pictarine apps, live, on Android devices (via ADB) and iPhones (via libimobiledevice). Built for developers and testers checking that every event is sent with the right parameters on both platforms.

## ✨ Features

- 📱 **Android and iOS devices**
  Lists every connected device: Android ones through `adb devices`, iPhones through `idevice_id`, over USB or Wi-Fi. Each platform is handled by its own module, as logs are not retrieved the same way.

- 🎯 **Per-app filtering**
  - **Android**: pick PhotoPrint or Pictadroid. Only the analytics lines of the app's processes are kept (release and `.debug` builds, child processes included).
  - **iOS**: pick a build of Picta, Walgreens or CVS, **Prod** or **Int**. The stream is narrowed down on the device (`idevicesyslog -p <process> -m "logId=["`). Prod and Int share their process name, so they are told apart by PID through Xcode's `devicectl`. When the other build is the one logging, the app says how many events are hidden and offers to switch.

- 📜 **Live log view**
  Streams in real time, newest first, and folds the same event logged under several tags (one per analytics backend) into a single entry.

- 🔍 **Search & filters**
  Filter by keywords, log level or logger tag.

- 🧾 **Readable payloads**
  Kotlin data classes (`LogDomainModel(...)`), `event=… params={…}` messages and the iOS `logId=[…] parameters=[{json}]` lines are parsed into fields. The detail page lists the event name first, then every field alphabetically, nested objects included.

- 🛠 **Fix list**
  Double-click (or right-click) an event or a field to flag it with a note. The list is kept across launches and can be exported for Slack.

- ⚖️ **Compare two devices**
  With exactly two devices connected, **Compare** opens a window showing both devices' analytics side by side, with a detail pane on the right.
  - **Start Compare** pairs the events by name, in the order they come in, and records those whose fields or values differ. Android and iOS payloads are lined up (`params`, `parameters` and `value` are flattened). The values of ids (`id`, `item_id`, `orderId`…) are not compared.
  - **Stop Compare** also reports the events only one device logged, and saves a JSON report in `~/Library/Application Support/LogCatAndroid/Comparisons/`.
  - Each difference can be added to the fix list in one click (**+**, or **Add All**).
  - Differences can be **ignored** (**eye.slash** button): a value, a field or a whole event, for one event or for all of them. **Ignored (N)** lists the rules, to remove them one by one or all at once. Rules apply live, are kept across launches and are listed in the report.

- 🔨 **Build & Run (Android)**
  Connect a git repository, pick a branch, a module and a variant, then build it with Gradle, install it and launch it on the selected Android device.

- 🎨 **Themes**
  Several light and dark themes, in Settings.

## 🚀 Getting Started

The first launch opens a setup screen that checks the command-line tools and installs the missing ones through Homebrew. Reopen it any time with the **?** button at the top right of the window; each command has a copy button.

### Android

1. **Install ADB**
   ```sh
   brew install --cask android-platform-tools
   ```
   The app runs adb from `/opt/homebrew/bin/adb` (`AndroidLogManager.adbPath`): change it there if yours lives elsewhere.

2. **Connect your device**
   Enable developer mode and USB debugging, connect the device and accept the debugging prompt.

### iOS

1. **Install libimobiledevice**
   ```sh
   brew install libimobiledevice
   ```
   It provides `idevice_id` and `idevicesyslog`, looked up in `/opt/homebrew/bin` and `/usr/local/bin`.

2. **Install Xcode** (recommended)
   Its `devicectl` tells the Prod and Int builds of an app apart. Without it, both builds' events show up together.

3. **Connect your iPhone**
   Plug it in, unlock it and accept « Trust This Computer ». Over Wi-Fi, the iPhone must be paired with this Mac and have « Show this iPhone when on Wi-Fi » enabled.

### Then

1. **Launch the app**: connected devices appear in the sidebar. With a single device connected, streaming starts by itself.
2. **Pick the app** to follow, use the app on the device: its analytics events show up as they are sent.

## 🧩 Architecture

| Part | Files |
|---|---|
| Shared log buffer (batching, duplicate folding) | `LogStreamManager.swift` |
| Android logs | `AndroidLogManager.swift`, `AppPackage.swift`, `LogEntry.swift` |
| iOS logs | `IOSLogManager.swift`, `IOSAppBuild.swift`, `LogEntry+IOS.swift` |
| Device list and routing to the right platform | `DeviceManager.swift` |
| Device comparison | `CompareSession.swift`, `LogComparator.swift`, `CompareIgnoreRules.swift`, `CompareView.swift` |
| Setup screen | `ToolSetup.swift`, `OnboardingView.swift` |
| Build & Run | `AndroidProjectManager.swift`, `ShellCommand.swift` |

The supported apps are declared in `AppPackage.swift` (Android packages and how they log analytics) and `IOSAppBuild.swift` (iOS bundle identifiers and process names).

## 🛠 Requirements

- macOS 15.4 or later.
- **Android:** ADB installed, a device with USB debugging enabled.
- **iOS:** libimobiledevice installed, a trusted iPhone over USB or Wi-Fi. Xcode to tell Prod and Int builds apart.

## 📄 License

[MIT License](LICENSE)

---

Made with ❤️ for Android and iOS developers and testers.
