# Android Log Viewer via ADB

<img width="1232" height="662" alt="Capture d’écran 2026-03-04 à 12 26 31" src="https://github.com/user-attachments/assets/2d6580a5-9f6e-4e00-a850-d83bdf25b2eb" />



A simple yet powerful desktop app that allows you to view and search all logs from connected Android devices using ADB. Ideal for developers and testers who need real-time logging with flexible filtering and device management.

## ✨ Features

- 📱 **Device Selection**  
  Automatically detects and lists all ADB-connected devices. Easily switch between devices.

- 📜 **Live Log View (Autoscroll)**  
  Continuously stream `logcat` output in real time, with optional autoscroll.

- 🔍 **Search & Filter Logs**  
  Filter logs by entering expressions or keywords — perfect for tracking specific issues or debugging tags.

- 🎨 **Clean UI**  
  User-friendly interface that makes reading and navigating logs simple and intuitive.

## 🚀 Getting Started

1. **Install ADB**  
   Make sure [Android Debug Bridge (ADB)](https://developer.android.com/tools/adb) is installed and added to your system's path.

2. Set the adb path here ``` let adbPath: String = "/opt/homebrew/bin/adb" ```

3. **Connect Your Device**  
   Enable developer mode and USB debugging on your Android device, then connect it via USB.

4. **Launch the App**  
   Run the application — connected devices will appear for selection.

5. **View Logs**  
   Start viewing logs, use search to filter, and toggle autoscroll as needed.

## 🛠 Requirements

- ADB installed on your system.
- Android device with USB debugging enabled.
- Desktop environment macOS.
## 📄 License

[MIT License](LICENSE)

---

Made with ❤️ for Android developers and testers.
