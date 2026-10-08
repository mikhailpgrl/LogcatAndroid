# Android & iOS Log Viewer

<img width="1696" height="987" alt="Capture d’écran 2026-09-25 à 15 29 35" src="https://github.com/user-attachments/assets/83206436-08dd-45e7-8660-772e5302d422" />


A simple yet powerful desktop app that allows you to view and search the analytics logs of connected Android devices (via ADB) and iOS devices (via libimobiledevice). Ideal for developers and testers who need real-time logging with flexible filtering and device management.

## ✨ Features

- 📱 **Device Selection**  
  Automatically detects and lists all ADB-connected Android devices and USB-connected iPhones. Easily switch between devices.

- 📜 **Live Log View (Autoscroll)**  
  Continuously stream `logcat` output in real time, with optional autoscroll.

- 🔍 **Search & Filter Logs**  
  Filter logs by entering expressions or keywords — perfect for tracking specific issues or debugging tags.

- 🎨 **Clean UI**  
  User-friendly interface that makes reading and navigating logs simple and intuitive.

## 🚀 Getting Started

1. **Install the tools**  
   - Android: [Android Debug Bridge (ADB)](https://developer.android.com/tools/adb), e.g. `brew install --cask android-platform-tools`
   - iOS: [libimobiledevice](https://libimobiledevice.org), `brew install libimobiledevice`

   The setup screen shown at launch checks them and installs the missing ones through Homebrew (it is also in Settings). The tools are looked up in `/opt/homebrew/bin` and `/usr/local/bin` (and Android Studio's SDK for adb).

2. **Connect Your Device**  
   - Android: enable developer mode and USB debugging, then connect it via USB.
   - iOS: connect the iPhone via USB, unlock it and tap "Trust This Computer".
   - Over Wi-Fi: on Android, enable wireless debugging and `adb pair` / `adb connect`. On iOS, once the iPhone is trusted, enable "Show this iPhone when on Wi-Fi" in Finder; it then shows up as "· Wi-Fi" when unplugged, on the same network.

3. **Pick the app**  
   PhotoPrint maps to the Walgreens/CVS iOS apps (AppleLab), Pictadroid to Picta (picta-ios).

4. **Launch the App**  
   Run the application — connected devices will appear for selection.

5. **View Logs**  
   Start viewing logs, use search to filter, and toggle autoscroll as needed.

## 🛠 Requirements

- ADB installed on your system, and an Android device with USB debugging enabled.
- Or libimobiledevice installed, and an iPhone running an internal build (Debug or TestFlight): App Store builds redact their analytics logs as `<private>`.
- Desktop environment macOS.
## 📄 License

[MIT License](LICENSE)

---

Made with ❤️ for Android and iOS developers and testers.
