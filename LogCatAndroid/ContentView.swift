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
    @StateObject private var fixList = FixListStore()

    @State private var searchText: String = ""
    @State private var selectedLevel: LogEntry.LogLevel? = nil
    /// Logger tags to show; empty means every tag
    @State private var selectedTags: Set<String> = []
    @State private var selectedEntryID: LogEntry.ID? = nil
    @State private var showSettings = false

    /// Field path (e.g. `params.items[0].price`) briefly highlighted in the detail view after a reveal
    @State private var highlightedFieldPath: String? = nil
    /// Entry the log list should scroll to; reset once the scroll happened
    @State private var scrollTargetID: LogEntry.ID? = nil

    /// Entry revealed from the fix list, shown in the detail even when the list cannot select it
    /// (gone from the buffer after a restart, or hidden by the current search/level filter)
    @State private var detachedEntry: LogEntry? = nil

    /// The selected entry, looked up by id so tags merged after selection show up in the detail view
    private var selectedEntry: LogEntry? {
        guard let selectedEntryID else { return nil }
        return adbManager.logEntries.first { $0.id == selectedEntryID }
    }

    /// What the detail column shows: the list selection first, otherwise a revealed entry
    private var detailEntry: LogEntry? { selectedEntry ?? detachedEntry }

    /// Opens the log a fix item was taken from and flashes the flagged field for a second
    private func reveal(_ item: FixItem) {
        if let live = adbManager.logEntries.first(where: { $0.id == item.entryID }) {
            selectedEntryID = live.id
            scrollTargetID = live.id
            // Also keep it as the detached entry in case the list filter hides the row
            detachedEntry = live
        } else {
            // Gone from the buffer: rebuild it from the raw line stored with the item
            selectedEntryID = nil
            detachedEntry = item.reconstructedEntry()
        }
        withAnimation(.easeIn(duration: 0.15)) {
            highlightedFieldPath = item.fieldKey
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            // Leave a newer reveal alone if one happened in the meantime
            if highlightedFieldPath == item.fieldKey {
                withAnimation(.easeOut(duration: 0.4)) {
                    highlightedFieldPath = nil
                }
            }
        }
    }

    /// Every logger tag seen in the current buffer, for the filter bar
    var availableTags: [String] {
        var seen: Set<String> = []
        for entry in adbManager.logEntries {
            seen.formUnion(entry.tags)
        }
        return seen.sorted()
    }

    /// Filtered entries based on tags, search text and log level, reversed so newest is first
    var filteredEntries: [LogEntry] {
        var entries = adbManager.logEntries

        if !selectedTags.isEmpty {
            // A merged entry carries several tags: keep it if any of them is selected
            entries = entries.filter { entry in entry.tags.contains(where: selectedTags.contains) }
        }

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
                    .frame(maxWidth: .infinity, alignment: .leading)
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

                // Logs flagged for a fix, pinned to the bottom of the sidebar
                FixListView(store: fixList, onReveal: reveal)

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
            VStack(spacing: 0) {
                // Title, search + tag filters, pinned above the log list
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Logs")
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Text("\(filteredEntries.count) / \(adbManager.logEntries.count)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .help("Shown / total")
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Filter logs...", text: $searchText)
                            .textFieldStyle(.plain)
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Clear search")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.background.secondary)
                    .clipShape(.rect(cornerRadius: 8))

                    TagFilterBar(tags: availableTags, selectedTags: $selectedTags)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(themeManager.currentTheme.background)

                Divider()

                logList
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 400, max: 600)
        } detail: {
            if let entry = detailEntry {
                LogDetailView(entry: entry, fixList: fixList, highlightedFieldPath: highlightedFieldPath)
            } else {
                ContentUnavailableView(
                    "Select a Log",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Choose a log entry from the list to view its details.")
                )
            }
        }
        .toolbar {
            // App icon and name at the left of the title bar. On macOS 26 toolbar items get a
            // glass capsule behind them: hide it so they sit bare on the title bar.
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) { appIcon }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { appIcon }
            }
        }
        // No window title text: the icon + name plays that role
        .toolbar(removing: .title)
        .onAppear {
            adbManager.refreshDevices()
        }
        .onChange(of: selectedEntryID) {
            // Picking another row in the list dismisses a revealed entry
            if let selectedEntryID, selectedEntryID != detachedEntry?.id {
                detachedEntry = nil
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(themeManager: themeManager)
        }
        .environment(\.appTheme, themeManager.currentTheme)
        .preferredColorScheme(themeManager.currentTheme.preferredScheme)
        .tint(themeManager.currentTheme.accent)
        .frame(minWidth: 900, minHeight: 600)
    }

    /// The running app's icon and name, shown in the title bar
    private var appIcon: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
            Text("LogCat")
                .font(.headline)
        }
        .help("LogCatAndroid")
    }

    /// The scrolling list of filtered log entries
    private var logList: some View {
        ScrollViewReader { proxy in
            List(filteredEntries, selection: $selectedEntryID) { entry in
                LogRowView(entry: entry)
                    .tag(entry.id)
                    .id(entry.id)
                    .listRowBackground(themeManager.currentTheme.background)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(themeManager.currentTheme.background)
            .onChange(of: adbManager.logEntries.count) {
                // Auto-scroll to the newest entry (top) only when nothing is selected
                if selectedEntryID == nil, let first = filteredEntries.first {
                    withAnimation {
                        proxy.scrollTo(first.id, anchor: .top)
                    }
                }
            }
            .onChange(of: scrollTargetID) {
                // Bring a revealed fix-list entry into view, then reset so the same
                // entry can be revealed again later
                guard let scrollTargetID else { return }
                withAnimation {
                    proxy.scrollTo(scrollTargetID, anchor: .center)
                }
                self.scrollTargetID = nil
            }
        }
    }
}

// MARK: - Tag Filter Bar

/// Row of toggleable chips, one per logger tag seen so far, shown above the log list
struct TagFilterBar: View {
    let tags: [String]
    @Binding var selectedTags: Set<String>
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FilterChip(title: "All", isSelected: selectedTags.isEmpty) {
                    selectedTags.removeAll()
                }

                ForEach(tags, id: \.self) { tag in
                    FilterChip(title: tag, isSelected: selectedTags.contains(tag)) {
                        if selectedTags.contains(tag) {
                            selectedTags.remove(tag)
                        } else {
                            selectedTags.insert(tag)
                        }
                    }
                }

                if tags.isEmpty {
                    Text("Tags appear here as logs come in")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        // Drop selections for tags that vanished from the buffer (e.g. after Clear All Logs)
        .onChange(of: tags) {
            selectedTags = selectedTags.filter(tags.contains)
        }
    }
}

#Preview("Tag filter bar") {
    @Previewable @State var selected: Set<String> = ["AnalyticsPostHog"]
    TagFilterBar(tags: ["Analytics", "AnalyticsPostHog", "Firebase"], selectedTags: $selected)
        .padding(12)
        .frame(width: 400)
}

/// A capsule toggle used by the tag filter bar
struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSelected ? theme.accent : theme.surface.opacity(0.5))
                .clipShape(.capsule)
                .overlay {
                    Capsule().strokeBorder(theme.accent.opacity(isSelected ? 0 : 0.3), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
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
                HStack(spacing: 6) {
                    Text(entry.eventName)
                        .font(.system(.body, design: .monospaced, weight: .medium))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)

                    // One chip per logger tag this event was seen with
                    ForEach(entry.tags, id: \.self) { tag in
                        TagChip(tag: tag)
                    }
                }

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
    @ObservedObject var fixList: FixListStore
    /// Field path to flash, set for a second when a fix-list item is revealed
    var highlightedFieldPath: String? = nil
    @Environment(\.appTheme) private var theme
    @State private var showEventPopover = false

    /// Records a field of this entry in the fix list together with the user's note
    private func addToFixList(key: String, value: String, note: String) {
        fixList.add(FixItem(entry: entry, fieldKey: key, fieldValue: value, note: note))
    }

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
                            .contentShape(Rectangle())
                            // Double-click (or right-click) the event name to flag this log
                            .onTapGesture(count: 2) { showEventPopover = true }
                            .contextMenu {
                                Button("Add to Fix List…", systemImage: "wrench.and.screwdriver") {
                                    showEventPopover = true
                                }
                            }
                            .popover(isPresented: $showEventPopover, arrowEdge: .bottom) {
                                AddToFixListPopover(fieldKey: "event", fieldValue: entry.eventName) { note in
                                    addToFixList(key: "event", value: entry.eventName, note: note)
                                }
                            }
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
                            FieldRowView(field: field, path: field.key, onAddToFixList: addToFixList,
                                         highlightedPath: highlightedFieldPath)

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
                        MetadataChip(label: entry.tags.count > 1 ? "Tags" : "Tag",
                                     value: entry.tags.joined(separator: ", "))
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
        Self.matches(of: searchText, in: rawLine)
    }

    /// The raw line with matches highlighted
    private var highlightedText: AttributedString {
        Self.highlighted(rawLine, matching: searchText)
    }

    /// Every case-insensitive, diacritic-insensitive occurrence of `query` in `text`
    static func matches(of query: String, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: query,
                                     options: [.caseInsensitive, .diacriticInsensitive],
                                     range: searchStart..<text.endIndex) {
            ranges.append(range)
            searchStart = range.upperBound
        }
        return ranges
    }

    /// `text` as an attributed string where every match of `query` is drawn
    /// bold and black on a solid yellow background, so it stands out on any theme.
    static func highlighted(_ text: String, matching query: String) -> AttributedString {
        var attributed = AttributedString(text)
        for range in matches(of: query, in: text) {
            guard let attributedRange = Range(range, in: attributed) else { continue }
            attributed[attributedRange].backgroundColor = .yellow
            attributed[attributedRange].foregroundColor = .black
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

#Preview("Raw log highlight") {
    Text(RawLogView.highlighted(
        "09-25 11:11:44.394 19903 26403 D Analytics: event=add_to_cart params={item_name=Classic Pet Portrait, price=19.99}",
        matching: "it"
    ))
    .font(.system(.body, design: .monospaced))
    .padding()
    .frame(width: 500)
}

// MARK: - Field Row View

struct FieldRowView: View {
    let field: LogEntry.ParsedField
    var depth: Int = 0
    /// Dotted path from the root, e.g. `params.items[0].item_name`, recorded in the fix list
    var path: String
    /// Called with (path, value, note) when the user flags this field for a fix
    var onAddToFixList: (String, String, String) -> Void
    /// Field path currently flashed after a reveal from the fix list
    var highlightedPath: String? = nil
    @Environment(\.appTheme) private var theme
    @State private var showAddPopover = false

    /// User toggle state; `nil` until the user interacts, so the default below applies
    @State private var userExpanded: Bool? = nil

    /// Top-level containers start open, deeper ones stay collapsed until the user drills in
    private var isExpanded: Bool { userExpanded ?? (depth == 0) }

    private var keyWidth: CGFloat { max(100 - CGFloat(depth) * 16, 60) }

    /// Whether this exact field is the one being flashed
    private var isHighlighted: Bool { highlightedPath == path }

    /// Whether the flashed field lives somewhere inside this container
    private var containsHighlight: Bool {
        guard let highlightedPath else { return false }
        return highlightedPath.hasPrefix(path + ".") || highlightedPath.hasPrefix(path + "[")
    }

    /// Flash background, animated in and out by the caller's `withAnimation`
    private var highlightBackground: Color {
        isHighlighted ? theme.accent.opacity(0.3) : .clear
    }

    /// Opens this container when a reveal targets one of its descendants
    private func expandIfNeededForHighlight() {
        if containsHighlight && !isExpanded {
            userExpanded = true
        }
    }

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
                    .background(highlightBackground)
                }
                .buttonStyle(.plain)
                .onAppear(perform: expandIfNeededForHighlight)
                .onChange(of: highlightedPath) { expandIfNeededForHighlight() }

                if isExpanded {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(field.children.enumerated()), id: \.offset) { index, child in
                            // List elements already carry their `[n]` key; object children get a dot
                            let childPath = child.key.hasPrefix("[") ? path + child.key : path + "." + child.key
                            FieldRowView(field: child, depth: depth + 1, path: childPath,
                                         onAddToFixList: onAddToFixList, highlightedPath: highlightedPath)

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

                // Not selectable on purpose: text selection would swallow the double-click.
                // The value can be copied from the context menu instead.
                Text(field.value)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16 + CGFloat(depth) * 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(highlightBackground)
            // Double-click (or right-click) anywhere on the row, value included, to flag it for a fix
            .onTapGesture(count: 2) { showAddPopover = true }
            .contextMenu {
                Button("Add to Fix List…", systemImage: "wrench.and.screwdriver") {
                    showAddPopover = true
                }
                Button("Copy Value", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(field.value, forType: .string)
                }
            }
            .popover(isPresented: $showAddPopover, arrowEdge: .trailing) {
                AddToFixListPopover(fieldKey: path, fieldValue: field.value) { note in
                    onAddToFixList(path, field.value, note)
                }
            }
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

// MARK: - Tag Chip

/// Small capsule showing a logger tag in a list row
struct TagChip: View {
    let tag: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        Text(tag)
            .font(.system(.caption2, design: .rounded, weight: .medium))
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(theme.accent.opacity(0.12))
            .clipShape(.capsule)
            .lineLimit(1)
            .fixedSize()
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


