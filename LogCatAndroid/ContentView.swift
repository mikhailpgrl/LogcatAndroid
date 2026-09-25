//
//  ContentView.swift
//  LogCatAndroid
//
//  Created by Mikhail on 27/05/2025.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var adbManager = ADBManager()
    @StateObject private var themeManager = ThemeManager()

    @State private var searchText: String = ""
    @State private var selectedLevel: LogEntry.LogLevel? = nil
    @State private var selectedEntry: LogEntry? = nil
    @State private var showSettings = false

    /// Filtered entries based on search text and log level, reversed so newest is first
    var filteredEntries: [LogEntry] {
        var entries = adbManager.logEntries

        if let level = selectedLevel {
            entries = entries.filter { $0.level == level }
        }

        let keywords = searchText
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { String($0).lowercased() }
            .filter { !$0.isEmpty }

        if !keywords.isEmpty {
            entries = entries.filter { entry in
                let lowerLine = entry.rawLine.lowercased()
                return keywords.allSatisfy { lowerLine.contains($0) }
            }
        }

        return entries.reversed()
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 16) {
                // Device section
                SidebarSection(title: "Device", icon: "cable.connector") {
                    DeviceSelectorView(adbManager: adbManager)
                }

                // App package section
                SidebarSection(title: "App", icon: "app.badge") {
                    PackageSelectorView(adbManager: adbManager)
                }

                // Filter section
                SidebarSection(title: "Filter", icon: "line.3.horizontal.decrease") {
                    Picker("Log Level", selection: $selectedLevel) {
                        Text("All Levels").tag(nil as LogEntry.LogLevel?)
                        ForEach(LogEntry.LogLevel.allCases, id: \.self) { level in
                            Label(level.displayName, systemImage: level.symbol)
                                .tag(level as LogEntry.LogLevel?)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                // Controls section
                SidebarSection(title: "Controls", icon: "playpause") {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Button {
                                adbManager.startLogcat()
                            } label: {
                                Label("Start", systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .disabled(adbManager.isLogcatRunning)

                            Button {
                                adbManager.stopLogcat()
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .disabled(!adbManager.isLogcatRunning)
                        }
                        .glassButtons()
                        .controlSize(.regular)

                        Button(role: .destructive) {
                            adbManager.clearLogs()
                        } label: {
                            Label("Clear All Logs", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.small)
                    }
                }

                Spacer()

                // Settings button
                Button {
                    showSettings.toggle()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)

                // Status bar at the bottom
                HStack(spacing: 6) {
                    Circle()
                        .fill(adbManager.isLogcatRunning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(adbManager.isLogcatRunning ? "Running" : "Stopped")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(adbManager.logEntries.count) logs")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)
            }
            .padding(12)
            .frame(maxHeight: .infinity)
            .background(themeManager.currentTheme.background)
            .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 350)
        } content: {
            ScrollViewReader { proxy in
                List(filteredEntries, selection: $selectedEntry) { entry in
                    LogRowView(entry: entry)
                        .tag(entry)
                        .id(entry.id)
                        .listRowBackground(themeManager.currentTheme.background)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(themeManager.currentTheme.background)
                .onChange(of: adbManager.logEntries.count) {
                    // Auto-scroll to the newest entry (top) only when nothing is selected
                    if selectedEntry == nil, let first = filteredEntries.first {
                        withAnimation {
                            proxy.scrollTo(first.id, anchor: .top)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Filter logs...")
            .navigationTitle("Logs")
            .navigationSplitViewColumnWidth(min: 300, ideal: 400, max: 600)
        } detail: {
            if let entry = selectedEntry {
                LogDetailView(entry: entry)
            } else {
                ContentUnavailableView(
                    "Select a Log",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Choose a log entry from the list to view its details.")
                )
            }
        }
        .onAppear {
            adbManager.refreshDevices()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(themeManager: themeManager)
        }
        .environment(\.appTheme, themeManager.currentTheme)
        .preferredColorScheme(themeManager.currentTheme.preferredScheme)
        .tint(themeManager.currentTheme.accent)
        .frame(minWidth: 900, minHeight: 600)
    }
}

// MARK: - Liquid Glass Availability Helpers

extension View {
    /// Applies `.buttonStyle(.glass)` on macOS 26+, plain style otherwise
    @ViewBuilder
    func glassButtons() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self
        }
    }

    /// Applies `.glassEffect(.regular, in:)` on macOS 26+, background fallback otherwise
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 12) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

// MARK: - Log Row View

struct LogRowView: View {
    let entry: LogEntry
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.level.symbol)
                .foregroundStyle(theme.colorForLevel(entry.level))
                .font(.caption)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.eventName)
                    .font(.system(.body, design: .monospaced, weight: .medium))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)

                Text(entry.message)
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            if !entry.timestamp.isEmpty {
                Text(entry.timestamp)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.textSecondary.opacity(0.6))
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Log Detail View

struct LogDetailView: View {
    let entry: LogEntry
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header card
                HStack(spacing: 12) {
                    Image(systemName: entry.level.symbol)
                        .font(.title)
                        .foregroundStyle(theme.colorForLevel(entry.level))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.eventName)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(theme.text)
                        HStack(spacing: 8) {
                            Text(entry.level.displayName)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(theme.colorForLevel(entry.level).opacity(0.15))
                                .clipShape(.capsule)

                            if !entry.timestamp.isEmpty {
                                Text(entry.timestamp)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(theme.textSecondary)
                            }
                        }
                    }

                    Spacer()
                }
                .padding()
                .glassCard()

                // Parsed fields — each on its own row
                if !entry.parsedFields.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entry.parsedFields.enumerated()), id: \.offset) { index, field in
                            FieldRowView(field: field)

                            if index < entry.parsedFields.count - 1 {
                                Divider()
                                    .padding(.leading, 16)
                            }
                        }
                    }
                    .background(.background.secondary)
                    .clipShape(.rect(cornerRadius: 10))
                    .padding(.horizontal)
                } else {
                    // Fallback for non-parseable messages
                    GroupBox("Message") {
                        Text(entry.message)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .padding(.horizontal)
                }

                // Process metadata
                if !entry.pid.isEmpty {
                    HStack(spacing: 12) {
                        MetadataChip(label: "PID", value: entry.pid)
                        MetadataChip(label: "TID", value: entry.tid)
                        MetadataChip(label: "Tag", value: entry.tag)
                    }
                    .padding(.horizontal)
                }

                // Raw log
                RawLogView(rawLine: entry.rawLine)
                    .padding(.horizontal)
            }
            .padding(.bottom)
        }
        .navigationTitle(entry.eventName)
        .background(theme.background)
    }
}

// MARK: - Raw Log View

/// The raw logcat line with a search field that highlights every match in the text
struct RawLogView: View {
    let rawLine: String
    @Environment(\.appTheme) private var theme

    @State private var isExpanded = true
    @State private var searchText = ""

    /// Every case-insensitive occurrence of `searchText` in the raw line
    private var matches: [Range<String.Index>] {
        guard !searchText.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchStart = rawLine.startIndex
        while searchStart < rawLine.endIndex,
              let range = rawLine.range(of: searchText,
                                        options: [.caseInsensitive, .diacriticInsensitive],
                                        range: searchStart..<rawLine.endIndex) {
            ranges.append(range)
            searchStart = range.upperBound
        }
        return ranges
    }

    /// The raw line with matches highlighted
    private var highlightedText: AttributedString {
        var attributed = AttributedString(rawLine)
        for range in matches {
            guard let attributedRange = Range(range, in: attributed) else { continue }
            attributed[attributedRange].backgroundColor = Color.yellow.opacity(0.35)
            attributed[attributedRange].font = .system(.body, design: .monospaced, weight: .bold)
        }
        return attributed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Text("Raw Log")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                if !searchText.isEmpty {
                    Text(matches.isEmpty ? "No match" : "\(matches.count) match\(matches.count == 1 ? "" : "es")")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(matches.isEmpty ? .orange : .secondary)
                }

                TextField("Search in raw log", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onChange(of: searchText) {
                        // Typing a query should always reveal the text it is searching
                        if !searchText.isEmpty && !isExpanded {
                            isExpanded = true
                        }
                    }
            }

            if isExpanded {
                Text(highlightedText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.background.secondary)
                    .clipShape(.rect(cornerRadius: 10))
            }
        }
    }
}

// MARK: - Field Row View

struct FieldRowView: View {
    let field: LogEntry.ParsedField
    var depth: Int = 0
    @Environment(\.appTheme) private var theme

    /// User toggle state; `nil` until the user interacts, so the default below applies
    @State private var userExpanded: Bool? = nil

    /// Top-level containers start open, deeper ones stay collapsed until the user drills in
    private var isExpanded: Bool { userExpanded ?? (depth == 0) }

    private var keyWidth: CGFloat { max(100 - CGFloat(depth) * 16, 60) }

    var body: some View {
        if field.isNested {
            // Container field: a clickable header that reveals its children one level at a time
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        userExpanded = !isExpanded
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(field.key)
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .foregroundStyle(theme.accent)
                            .frame(width: keyWidth, alignment: .trailing)

                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(theme.textSecondary.opacity(0.6))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))

                        Text(field.summary)
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)

                        if !isExpanded {
                            // Compact preview of the raw value while collapsed
                            Text(field.value)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(theme.textSecondary.opacity(0.6))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16 + CGFloat(depth) * 16)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(field.children.enumerated()), id: \.offset) { index, child in
                            FieldRowView(field: child, depth: depth + 1)

                            if index < field.children.count - 1 {
                                Divider()
                                    .padding(.leading, 32 + CGFloat(depth + 1) * 16)
                            }
                        }
                    }
                    .background(theme.surface.opacity(0.3))
                }
            }
        } else {
            // Leaf field: key + value on one row
            HStack(alignment: .top, spacing: 12) {
                Text(field.key)
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: keyWidth, alignment: .trailing)

                Text(field.value)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16 + CGFloat(depth) * 16)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Sidebar Section

struct SidebarSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            content
        }
    }
}

// MARK: - Metadata Chip

struct MetadataChip: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.background.secondary)
        .clipShape(.capsule)
    }
}


