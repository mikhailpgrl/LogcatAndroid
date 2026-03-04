import SwiftUI

struct SettingsView: View {
    @ObservedObject var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Theme section
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Theme", systemImage: "paintbrush")
                            .font(.headline)

                        LazyVGrid(columns: [
                            GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)
                        ], spacing: 12) {
                            ForEach(AppTheme.allThemes) { theme in
                                ThemeCard(
                                    theme: theme,
                                    isSelected: themeManager.currentTheme.id == theme.id
                                ) {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        themeManager.currentTheme = theme
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 420, height: 480)
    }
}

// MARK: - Theme Card

struct ThemeCard: View {
    let theme: AppTheme
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                // Color preview
                HStack(spacing: 0) {
                    theme.background
                    theme.surface
                }
                .frame(height: 40)
                .overlay(alignment: .bottom) {
                    // Sample log level colors
                    HStack(spacing: 4) {
                        Circle().fill(theme.debug).frame(width: 8, height: 8)
                        Circle().fill(theme.info).frame(width: 8, height: 8)
                        Circle().fill(theme.warning).frame(width: 8, height: 8)
                        Circle().fill(theme.error).frame(width: 8, height: 8)
                    }
                    .padding(6)
                }

                // Name
                HStack(spacing: 6) {
                    Image(systemName: theme.icon)
                        .font(.caption2)
                    Text(theme.name)
                        .font(.caption.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.background.secondary)
            }
            .clipShape(.rect(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
            .shadow(color: isSelected ? Color.accentColor.opacity(0.3) : .clear, radius: 4)
        }
        .buttonStyle(.plain)
    }
}
