import SwiftUI

// MARK: - App Theme

struct AppTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let background: Color
    let surface: Color
    let text: Color
    let textSecondary: Color
    let accent: Color
    let verbose: Color
    let debug: Color
    let info: Color
    let warning: Color
    let error: Color

    func colorForLevel(_ level: LogEntry.LogLevel) -> Color {
        switch level {
        case .verbose: return verbose
        case .debug: return debug
        case .info: return info
        case .warning: return warning
        case .error, .fatal: return error
        case .silent: return verbose
        case .unknown: return textSecondary
        }
    }
}

// MARK: - Built-in Themes

extension AppTheme {
    static let defaultLight = AppTheme(
        id: "default", name: "Default", icon: "circle.lefthalf.filled",
        background: Color(.windowBackgroundColor),
        surface: Color(.controlBackgroundColor),
        text: .primary,
        textSecondary: .secondary,
        accent: .accentColor,
        verbose: .gray,
        debug: .blue,
        info: .green,
        warning: .orange,
        error: .red
    )

    static let monokai = AppTheme(
        id: "monokai", name: "Monokai", icon: "paintpalette",
        background: Color(red: 0.16, green: 0.16, blue: 0.16),
        surface: Color(red: 0.20, green: 0.20, blue: 0.20),
        text: Color(red: 0.97, green: 0.97, blue: 0.94),
        textSecondary: Color(red: 0.60, green: 0.60, blue: 0.55),
        accent: Color(red: 0.65, green: 0.89, blue: 0.18),
        verbose: Color(red: 0.60, green: 0.60, blue: 0.55),
        debug: Color(red: 0.40, green: 0.85, blue: 0.94),
        info: Color(red: 0.65, green: 0.89, blue: 0.18),
        warning: Color(red: 0.99, green: 0.59, blue: 0.12),
        error: Color(red: 0.98, green: 0.15, blue: 0.45)
    )

    static let dracula = AppTheme(
        id: "dracula", name: "Dracula", icon: "moon.stars",
        background: Color(red: 0.16, green: 0.16, blue: 0.21),
        surface: Color(red: 0.21, green: 0.22, blue: 0.28),
        text: Color(red: 0.97, green: 0.97, blue: 0.95),
        textSecondary: Color(red: 0.47, green: 0.51, blue: 0.65),
        accent: Color(red: 0.74, green: 0.58, blue: 0.98),
        verbose: Color(red: 0.47, green: 0.51, blue: 0.65),
        debug: Color(red: 0.55, green: 0.81, blue: 0.99),
        info: Color(red: 0.31, green: 0.98, blue: 0.48),
        warning: Color(red: 1.00, green: 0.72, blue: 0.42),
        error: Color(red: 1.00, green: 0.33, blue: 0.33)
    )

    static let solarizedDark = AppTheme(
        id: "solarized", name: "Solarized", icon: "sun.max",
        background: Color(red: 0.00, green: 0.17, blue: 0.21),
        surface: Color(red: 0.03, green: 0.21, blue: 0.26),
        text: Color(red: 0.51, green: 0.58, blue: 0.59),
        textSecondary: Color(red: 0.40, green: 0.48, blue: 0.51),
        accent: Color(red: 0.15, green: 0.55, blue: 0.82),
        verbose: Color(red: 0.40, green: 0.48, blue: 0.51),
        debug: Color(red: 0.15, green: 0.55, blue: 0.82),
        info: Color(red: 0.52, green: 0.60, blue: 0.00),
        warning: Color(red: 0.71, green: 0.54, blue: 0.00),
        error: Color(red: 0.86, green: 0.20, blue: 0.18)
    )

    static let nord = AppTheme(
        id: "nord", name: "Nord", icon: "snowflake",
        background: Color(red: 0.18, green: 0.20, blue: 0.25),
        surface: Color(red: 0.23, green: 0.26, blue: 0.32),
        text: Color(red: 0.85, green: 0.87, blue: 0.91),
        textSecondary: Color(red: 0.62, green: 0.67, blue: 0.74),
        accent: Color(red: 0.53, green: 0.75, blue: 0.82),
        verbose: Color(red: 0.62, green: 0.67, blue: 0.74),
        debug: Color(red: 0.53, green: 0.75, blue: 0.82),
        info: Color(red: 0.64, green: 0.74, blue: 0.55),
        warning: Color(red: 0.92, green: 0.80, blue: 0.54),
        error: Color(red: 0.75, green: 0.38, blue: 0.42)
    )

    static let tokyoNight = AppTheme(
        id: "tokyo", name: "Tokyo Night", icon: "building.2",
        background: Color(red: 0.10, green: 0.11, blue: 0.18),
        surface: Color(red: 0.13, green: 0.15, blue: 0.23),
        text: Color(red: 0.66, green: 0.68, blue: 0.82),
        textSecondary: Color(red: 0.33, green: 0.36, blue: 0.52),
        accent: Color(red: 0.48, green: 0.51, blue: 0.93),
        verbose: Color(red: 0.33, green: 0.36, blue: 0.52),
        debug: Color(red: 0.48, green: 0.73, blue: 0.96),
        info: Color(red: 0.45, green: 0.83, blue: 0.59),
        warning: Color(red: 0.88, green: 0.59, blue: 0.34),
        error: Color(red: 0.96, green: 0.29, blue: 0.39)
    )

    static let catppuccinMocha = AppTheme(
        id: "catppuccin", name: "Catppuccin", icon: "cat",
        background: Color(red: 0.12, green: 0.12, blue: 0.18),
        surface: Color(red: 0.18, green: 0.19, blue: 0.26),
        text: Color(red: 0.80, green: 0.84, blue: 0.96),
        textSecondary: Color(red: 0.43, green: 0.45, blue: 0.55),
        accent: Color(red: 0.54, green: 0.71, blue: 0.99),
        verbose: Color(red: 0.43, green: 0.45, blue: 0.55),
        debug: Color(red: 0.54, green: 0.71, blue: 0.99),
        info: Color(red: 0.65, green: 0.89, blue: 0.63),
        warning: Color(red: 0.98, green: 0.70, blue: 0.53),
        error: Color(red: 0.95, green: 0.55, blue: 0.66)
    )

    static let githubDark = AppTheme(
        id: "github", name: "GitHub Dark", icon: "chevron.left.forwardslash.chevron.right",
        background: Color(red: 0.06, green: 0.07, blue: 0.09),
        surface: Color(red: 0.09, green: 0.11, blue: 0.13),
        text: Color(red: 0.90, green: 0.93, blue: 0.96),
        textSecondary: Color(red: 0.48, green: 0.53, blue: 0.58),
        accent: Color(red: 0.34, green: 0.61, blue: 0.97),
        verbose: Color(red: 0.48, green: 0.53, blue: 0.58),
        debug: Color(red: 0.34, green: 0.61, blue: 0.97),
        info: Color(red: 0.24, green: 0.69, blue: 0.44),
        warning: Color(red: 0.83, green: 0.60, blue: 0.13),
        error: Color(red: 1.00, green: 0.48, blue: 0.44)
    )

    static let allThemes: [AppTheme] = [
        .defaultLight, .monokai, .dracula, .solarizedDark,
        .nord, .tokyoNight, .catppuccinMocha, .githubDark
    ]
}

// MARK: - Theme Manager

class ThemeManager: ObservableObject {
    @Published var currentTheme: AppTheme {
        didSet {
            UserDefaults.standard.set(currentTheme.id, forKey: "selectedThemeID")
        }
    }

    init() {
        let savedID = UserDefaults.standard.string(forKey: "selectedThemeID") ?? "default"
        self.currentTheme = AppTheme.allThemes.first { $0.id == savedID } ?? .defaultLight
    }
}

// MARK: - Environment Key

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .defaultLight
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
