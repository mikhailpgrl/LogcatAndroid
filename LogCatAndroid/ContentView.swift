//
//  ContentView.swift
//  LogCatAndroid
//
//  Created by Mikhail on 27/05/2025.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var adbManager = ADBManager()

    @State private var searchText: String = ""
    @State private var selectedLevel: LogEntry.LogLevel? = nil
    @State private var selectedEntry: LogEntry? = nil

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
            VStack(spacing: 0) {
                DeviceSelectorView(adbManager: adbManager)

                Divider()

                // Log level filter
                Section {
                    Picker("Log Level", selection: $selectedLevel) {
                        Text("All Levels").tag(nil as LogEntry.LogLevel?)
                        ForEach(LogEntry.LogLevel.allCases, id: \.self) { level in
                            Label(level.displayName, systemImage: level.symbol)
                                .tag(level as LogEntry.LogLevel?)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal)
                }

                Divider()

                // Controls
                HStack(spacing: 12) {
                    Button {
                        adbManager.startLogcat()
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .disabled(adbManager.isLogcatRunning)

                    Button {
                        adbManager.stopLogcat()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .disabled(!adbManager.isLogcatRunning)

                    Button {
                        adbManager.logLines.removeAll()
                        adbManager.logEntries.removeAll()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                }
                .glassButtons()
                .padding()

                // Status indicator
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
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 350)
        } content: {
            List(filteredEntries, selection: $selectedEntry) { entry in
                LogRowView(entry: entry)
                    .tag(entry)
            }
            .listStyle(.inset)
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.level.symbol)
                .foregroundStyle(colorForLevel(entry.level))
                .font(.caption)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.eventName)
                    .font(.system(.body, design: .monospaced, weight: .medium))
                    .lineLimit(1)

                Text(entry.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if !entry.timestamp.isEmpty {
                Text(entry.timestamp)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func colorForLevel(_ level: LogEntry.LogLevel) -> Color {
        switch level {
        case .verbose: return .gray
        case .debug: return .blue
        case .info: return .green
        case .warning: return .orange
        case .error: return .red
        case .fatal: return .red
        case .silent: return .gray
        case .unknown: return .secondary
        }
    }
}

// MARK: - Log Detail View

struct LogDetailView: View {
    let entry: LogEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Image(systemName: entry.level.symbol)
                        .font(.title2)
                        .foregroundStyle(colorForLevel(entry.level))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.eventName)
                            .font(.title2.weight(.semibold))
                        Text(entry.level.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !entry.timestamp.isEmpty {
                        Text(entry.timestamp)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .glassCard()

                // Metadata
                if !entry.pid.isEmpty {
                    HStack(spacing: 16) {
                        MetadataItem(label: "PID", value: entry.pid)
                        MetadataItem(label: "TID", value: entry.tid)
                        MetadataItem(label: "Tag", value: entry.tag)
                    }
                    .padding(.horizontal)
                }

                // Message content
                GroupBox("Message") {
                    Text(entry.message)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .padding(.horizontal)

                // Raw log line
                GroupBox("Raw Log") {
                    Text(entry.rawLine)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle(entry.eventName)
    }

    private func colorForLevel(_ level: LogEntry.LogLevel) -> Color {
        switch level {
        case .verbose: return .gray
        case .debug: return .blue
        case .info: return .green
        case .warning: return .orange
        case .error: return .red
        case .fatal: return .red
        case .silent: return .gray
        case .unknown: return .secondary
        }
    }
}

// MARK: - Metadata Item

struct MetadataItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
        }
    }
}
