# Android & iOS Log Viewer

<img width="1232" height="662" alt="Capture d’écran 2026-03-04 à 12 26 31" src="https://github.com/user-attachments/assets/2d6580a5-9f6e-4e00-a850-d83bdf25b2eb" />



A simple yet powerful desktop app that allows you to view and search logs from connected Android devices (via ADB) and iPhones (via libimobiledevice). Ideal for developers and testers who need real-time logging with flexible filtering and device management.

## ✨ Features

- 📱 **Device Selection**  
  Automatically detects and lists all connected devices, Android (`adb devices`) and iOS (`idevice_id`). Each device shows a platform badge. Easily switch between devices.

- 📜 **Live Log View (Autoscroll)**  
  Continuously stream `adb logcat` (Android) or `idevicesyslog` (iOS) output in real time, with optional autoscroll.

- 🎯 **Per-App Filtering**  
  Pick the app whose analytics logs you want to follow. On Android the stream is restricted to the app's process IDs; on iOS it is restricted by process name (`idevicesyslog -p`).

- 🔍 **Search & Filter Logs**  
  Filter logs by entering expressions or keywords — perfect for tracking specific issues or debugging tags.

- 🎨 **Clean UI**  
  User-friendly interface that makes reading and navigating logs simple and intuitive.

## 🚀 Getting Started

### Android

1. **Install ADB**  
   Make sure [Android Debug Bridge (ADB)](https://developer.android.com/tools/adb) is installed and added to your system's path.

2. Set the adb path here ``` let adbPath: String = "/opt/homebrew/bin/adb" ```

3. **Connect Your Device**  
   Enable developer mode and USB debugging on your Android device, then connect it via USB.

### iOS

1. **Install libimobiledevice**  
   ```sh
   brew install libimobiledevice
   ```
   This provides `idevice_id`, `ideviceinfo` and `idevicesyslog`, the direct equivalent of `adb logcat`.

2. Set the tool paths in `ADBManager.swift` if Homebrew is not installed in `/opt/homebrew`:
   ```swift
   let ideviceIdPath: String = "/opt/homebrew/bin/idevice_id"
   let ideviceInfoPath: String = "/opt/homebrew/bin/ideviceinfo"
   let ideviceSyslogPath: String = "/opt/homebrew/bin/idevicesyslog"
   ```

3. **Set the iOS process names**  
   In `AppPackage.swift`, `iosProcessNames` must match each app's executable name (`CFBundleExecutable`, visible in any syslog line). The values shipped are placeholders.

4. **Connect Your iPhone**  
   Plug it in via USB, unlock it and accept « Trust This Computer ».

### Then

1. **Launch the App**  
   Run the application — connected devices will appear for selection. With a single device connected, streaming starts automatically.

2. **View Logs**  
   Start viewing logs, use search to filter, and toggle autoscroll as needed.

## 🛠 Requirements

- macOS desktop environment.
- **Android:** ADB installed, device with USB debugging enabled.
- **iOS:** libimobiledevice installed, iPhone connected via USB and trusted. The Build & Run (Gradle) section of the sidebar is Android-only.

## 📄 License

[MIT License](LICENSE)

---

Made with ❤️ for Android and iOS developers and testers.
