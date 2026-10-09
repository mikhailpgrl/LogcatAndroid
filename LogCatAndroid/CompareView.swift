//
//  CompareView.swift
//  LogCatAndroid
//

import AppKit
import SwiftUI

/// What the compare window's detail pane shows: a log of one of the devices, or a recorded difference
private enum CompareSelection: Hashable {
    case entry(CompareSide, LogEntry.ID)
    case mismatch(CompareMismatch.ID)
}

/// The compare window: two devices' logs streamed side by side, the events that differ below,
/// and the selected log or difference in the detail pane on the right
struct CompareView: View {
    @StateObject private var session: CompareSession
    @StateObject private var themeManager = ThemeManager()
    /// Logs flagged from the detail pane land in the main window's fix list
    @ObservedObject private var fixList = FixListStore.shared
    /// Differences the user chose to ignore, shared by every compare window
    @ObservedObject private var ignoreStore = CompareIgnoreStore.shared
    @State private var selection: CompareSelection?

    init(request: CompareRequest) {
        _session = StateObject(wrappedValue: CompareSession(request: request))
    }

    var body: some View {
        HSplitView {
            VSplitView {
                HSplitView {
                    column(.left)
                    column(.right)
                }
                .frame(minHeight: 260)

                MismatchListView(session: session, ignoreStore: ignoreStore, selectedID: mismatchSelection)
                    .frame(minHeight: 160, idealHeight: 240)
            }
            .frame(minWidth: 740, maxWidth: .infinity)

            // Explicit bounds: the window takes its content's minimum size, so without them a log
            // with a long name or many chips would widen the whole window when selected
            detail
                .frame(minWidth: 380, idealWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(role: .destructive) {
                    selection = nil
                    session.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .help("Clear both devices' logs and the differences")
            }
        }
        .navigationTitle("Compare Devices")
        .onAppear { session.startStreams() }
        // The window owns its streams: closing it stops them (and saves a running comparison)
        .onDisappear { session.stopStreams() }
        .environment(\.appTheme, themeManager.currentTheme)
        .preferredColorScheme(themeManager.currentTheme.preferredScheme)
        .tint(themeManager.currentTheme.accent)
        .frame(minWidth: 1140, minHeight: 600)
    }

    private func column(_ side: CompareSide) -> some View {
        CompareColumn(device: session.device(for: side), appLabel: session.appLabel(for: side),
                      logs: session.manager(for: side), selectedID: entrySelection(side))
    }

    // MARK: Selection

    /// The selected entry of `side`'s column. Selecting anything else elsewhere clears it.
    private func entrySelection(_ side: CompareSide) -> Binding<LogEntry.ID?> {
        Binding(
            get: {
                if case .entry(side, let id) = selection { return id }
                return nil
            },
            set: { newValue in
                if let newValue {
                    selection = .entry(side, newValue)
                } else if case .entry(side, _) = selection {
                    selection = nil
                }
            }
        )
    }

    private var mismatchSelection: Binding<CompareMismatch.ID?> {
        Binding(
            get: {
                if case .mismatch(let id) = selection { return id }
                return nil
            },
            set: { newValue in
                if let newValue {
                    selection = .mismatch(newValue)
                } else if case .mismatch = selection {
                    selection = nil
                }
            }
        )
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .entry(let side, let id):
            EntryDetailPane(device: session.device(for: side), appLabel: session.appLabel(for: side),
                            logs: session.manager(for: side), entryID: id, fixList: fixList)
        case .mismatch(let id):
            // Once everything it reported is ignored, a difference leaves the detail pane too
            if let mismatch = session.visibleMismatches(ignoring: ignoreStore.rules).first(where: { $0.id == id }) {
                MismatchDetailView(mismatch: mismatch,
                                   left: session.device(for: .left), leftApp: session.appLabel(for: .left),
                                   right: session.device(for: .right), rightApp: session.appLabel(for: .right),
                                   fixList: fixList, ignoreStore: ignoreStore)
                    // A fresh pane per difference, so it opens on the side that logged it
                    .id(mismatch.id)
            } else {
                NoSelectionView()
            }
        case nil:
            NoSelectionView()
        }
    }
}

// MARK: - Device Column

/// One device's live analytics, newest first. Follows the newest log unless one of the column's
/// logs is selected, so reading it is not interrupted.
private struct CompareColumn: View {
    let device: Device
    let appLabel: String
    @ObservedObject var logs: LogStreamManager
    @Binding var selectedID: LogEntry.ID?
    @Environment(\.appTheme) private var theme

    var body: some View {
        let entries = Array(logs.displayedEntries.reversed())

        VStack(spacing: 0) {
            DeviceHeader(device: device, appLabel: appLabel) {
                Circle()
                    .fill(logs.isLogcatRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text("\(entries.count) logs")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Divider()

            ScrollViewReader { proxy in
                List(entries, selection: $selectedID) { entry in
                    LogRowView(entry: entry)
                        .tag(entry.id)
                        .id(entry.id)
                        .listRowBackground(theme.background)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(theme.background)
                // The newest entry changes even once the buffer is full and its count stays put
                .onChange(of: entries.first?.id) {
                    guard selectedID == nil, let newest = entries.first else { return }
                    withAnimation {
                        proxy.scrollTo(newest.id, anchor: .top)
                    }
                }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "Waiting for Events",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text("Use \(appLabel) on \(device.displayName): its analytics show up here.")
                    )
                }
            }
        }
        // Explicit bounds so a long row never widens the window (see the detail pane)
        .frame(minWidth: 360, maxWidth: .infinity)
    }
}

/// The device a column or a detail belongs to: name, platform and followed app, plus trailing accessories
private struct DeviceHeader<Accessory: View>: View {
    let device: Device
    let appLabel: String
    @ViewBuilder var accessory: Accessory
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: device.platform.symbol)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(device.platform.displayName) · \(appLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            accessory
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.background)
    }
}

// MARK: - Detail Panes

private struct NoSelectionView: View {
    var body: some View {
        ContentUnavailableView(
            "Select a Log",
            systemImage: "doc.text.magnifyingglass",
            description: Text("Choose a log of either device, or a difference, to view its details.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A device's log in the detail pane, with the device it comes from. Observes the device's
/// stream so tags merged after selection show up, and the pane empties once the log is cleared.
private struct EntryDetailPane: View {
    let device: Device
    let appLabel: String
    @ObservedObject var logs: LogStreamManager
    let entryID: LogEntry.ID
    @ObservedObject var fixList: FixListStore

    var body: some View {
        if let entry = logs.logEntries.first(where: { $0.id == entryID }) {
            VStack(spacing: 0) {
                DeviceHeader(device: device, appLabel: appLabel) { EmptyView() }
                Divider()
                LogDetailView(entry: entry, fixList: fixList)
            }
        } else {
            NoSelectionView()
        }
    }
}

/// A recorded difference: what differs, then each device's log, one at a time
private struct MismatchDetailView: View {
    let mismatch: CompareMismatch
    let left: Device
    let leftApp: String
    let right: Device
    let rightApp: String
    @ObservedObject var fixList: FixListStore
    @ObservedObject var ignoreStore: CompareIgnoreStore
    @Environment(\.appTheme) private var theme

    /// The device whose log is shown below the summary
    @State private var side: CompareSide

    init(mismatch: CompareMismatch, left: Device, leftApp: String, right: Device, rightApp: String,
         fixList: FixListStore, ignoreStore: CompareIgnoreStore) {
        self.mismatch = mismatch
        self.left = left
        self.leftApp = leftApp
        self.right = right
        self.rightApp = rightApp
        self.fixList = fixList
        self.ignoreStore = ignoreStore
        _side = State(initialValue: mismatch.leftRawLine != nil ? .left : .right)
    }

    private var candidates: [MismatchFixCandidate] {
        mismatch.fixCandidates(leftName: left.displayName, rightName: right.displayName)
    }

    /// Whether `candidate` is already in the fix list, whatever note it was given
    private func isAdded(_ candidate: MismatchFixCandidate) -> Bool {
        guard let rawLine = mismatch.entry(for: candidate.side)?.rawLine else { return false }
        return fixList.items.contains { $0.rawLine == rawLine && $0.fieldKey == candidate.fieldKey }
    }

    /// Adds `candidate` to the fix list, pointing at the log of the device it concerns
    private func add(_ candidate: MismatchFixCandidate, note: String? = nil) {
        guard !isAdded(candidate), let entry = mismatch.entry(for: candidate.side) else { return }
        fixList.add(FixItem(entry: entry, fieldKey: candidate.fieldKey, fieldValue: candidate.fieldValue,
                            note: note ?? candidate.note))
    }

    /// What can be ignored for `candidate`, narrowest first: this event only, then every event
    private func ignoreOptions(for candidate: MismatchFixCandidate) -> [CompareIgnoreRule] {
        let event = mismatch.eventName
        switch candidate.kind {
        case .differentValue:
            return [
                CompareIgnoreRule(kind: .value, key: candidate.fieldKey, eventName: event),
                CompareIgnoreRule(kind: .value, key: candidate.fieldKey),
                CompareIgnoreRule(kind: .field, key: candidate.fieldKey, eventName: event),
                CompareIgnoreRule(kind: .field, key: candidate.fieldKey),
            ]
        case .missingField:
            return [
                CompareIgnoreRule(kind: .field, key: candidate.fieldKey, eventName: event),
                CompareIgnoreRule(kind: .field, key: candidate.fieldKey),
            ]
        case .missingEvent:
            return [CompareIgnoreRule(kind: .event, key: event)]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: mismatch.kind == .missingOnOtherSide ? "questionmark.diamond" : "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(mismatch.eventName)
                        .font(.system(.title3, design: .monospaced, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    Spacer()
                    let remaining = candidates.filter { !isAdded($0) }
                    Button {
                        remaining.forEach { add($0) }
                    } label: {
                        Label("Add All", systemImage: "wrench.and.screwdriver")
                    }
                    .controlSize(.small)
                    .disabled(remaining.isEmpty)
                    .help("Add every difference of this event to the Fix List")
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(candidates) { candidate in
                        FixCandidateRow(candidate: candidate, isAdded: isAdded(candidate),
                                        ignoreOptions: ignoreOptions(for: candidate),
                                        onIgnore: ignoreStore.add) { note in
                            add(candidate, note: note)
                        }
                    }
                }

                if mismatch.kind == .fieldsDiffer {
                    Picker("Device", selection: $side) {
                        Text(left.displayName).tag(CompareSide.left)
                        Text(right.displayName).tag(CompareSide.right)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.background)

            Divider()

            DeviceHeader(device: side == .left ? left : right, appLabel: side == .left ? leftApp : rightApp) {
                EmptyView()
            }
            Divider()

            if let entry = mismatch.entry(for: side) {
                LogDetailView(entry: entry, fixList: fixList)
                    .id(side)
            } else {
                NoSelectionView()
            }
        }
    }
}

/// A line of a difference: one click adds it to the fix list with a note describing the gap,
/// right-click lets you write the note yourself
private struct FixCandidateRow: View {
    let candidate: MismatchFixCandidate
    let isAdded: Bool
    /// The rules that would hide this line, offered in the ignore menu
    let ignoreOptions: [CompareIgnoreRule]
    let onIgnore: (CompareIgnoreRule) -> Void
    /// Called with the note to use, `nil` for the generated one
    let onAdd: (String?) -> Void
    @Environment(\.appTheme) private var theme
    @State private var showNotePopover = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                onAdd(nil)
            } label: {
                Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                    .foregroundStyle(isAdded ? Color.green : theme.accent)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .disabled(isAdded)
            .help(isAdded ? "Already in the Fix List" : "Add to the Fix List: \(candidate.note)")

            Menu {
                ignoreMenuItems
            } label: {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Ignore this difference from now on")

            Text(candidate.label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.text)
                .textSelection(.enabled)
        }
        .contextMenu {
            Button("Add with Note…", systemImage: "square.and.pencil") {
                showNotePopover = true
            }
            .disabled(isAdded)

            Divider()
            ignoreMenuItems
        }
        .popover(isPresented: $showNotePopover, arrowEdge: .trailing) {
            AddToFixListPopover(fieldKey: candidate.fieldKey, fieldValue: candidate.fieldValue) { note in
                onAdd(note.isEmpty ? nil : note)
            }
        }
    }

    @ViewBuilder
    private var ignoreMenuItems: some View {
        ForEach(ignoreOptions, id: \.self) { rule in
            Button("Ignore \(rule.title) \(rule.scope)", systemImage: "eye.slash") {
                onIgnore(rule)
            }
        }
    }
}

// MARK: - Mismatches

/// The events that differ between the two devices, with the comparison status. Follows the newest
/// difference unless one is selected.
private struct MismatchListView: View {
    @ObservedObject var session: CompareSession
    @ObservedObject var ignoreStore: CompareIgnoreStore
    @Binding var selectedID: CompareMismatch.ID?
    @Environment(\.appTheme) private var theme
    @State private var showIgnored = false

    var body: some View {
        let mismatches = Array(session.visibleMismatches(ignoring: ignoreStore.rules).reversed())

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Differences", systemImage: "arrow.left.arrow.right")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()

                Button {
                    showIgnored = true
                } label: {
                    Label("Ignored (\(ignoreStore.rules.count))", systemImage: "eye.slash")
                }
                .controlSize(.small)
                .help("Show what the comparison ignores, and stop ignoring it")
                .popover(isPresented: $showIgnored, arrowEdge: .bottom) {
                    IgnoredRulesView(store: ignoreStore)
                }

                if session.isComparing {
                    stopButton
                } else if !mismatches.isEmpty {
                    // The placeholder holds the button while the list is empty
                    startButton
                }

                if let url = session.savedReportURL {
                    Button("Show Report in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .controlSize(.small)
                }
                if let error = session.saveError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if mismatches.isEmpty {
                ContentUnavailableView {
                    Label(session.isComparing ? "No Differences So Far" : "Not Comparing",
                          systemImage: session.isComparing ? "checkmark.circle" : "arrow.left.arrow.right")
                } description: {
                    Text(session.isComparing
                         ? "Events logged by both devices are compared as they come in."
                         : "Start Compare, then go through the same screens on both devices.")
                } actions: {
                    if !session.isComparing {
                        startButton
                            .controlSize(.large)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(mismatches, selection: $selectedID) { mismatch in
                        MismatchRow(mismatch: mismatch,
                                    leftName: session.device(for: .left).displayName,
                                    rightName: session.device(for: .right).displayName)
                            .tag(mismatch.id)
                            .id(mismatch.id)
                    }
                    .listStyle(.inset)
                    .onChange(of: mismatches.first?.id) {
                        guard selectedID == nil, let newest = mismatches.first else { return }
                        withAnimation {
                            proxy.scrollTo(newest.id, anchor: .top)
                        }
                    }
                }
            }
        }
        .background(theme.background)
    }

    private var startButton: some View {
        Button {
            selectedID = nil
            session.startCompare()
        } label: {
            Label("Start Compare", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .help("Pair the events logged from now on and record those that differ")
    }

    private var stopButton: some View {
        Button {
            session.stopCompare()
        } label: {
            Label("Stop Compare", systemImage: "stop.fill")
        }
        .controlSize(.small)
        .help("Stop pairing events and save the differences")
    }

    private var statusText: String {
        let visible = session.visibleMismatches(ignoring: ignoreStore.rules).count
        let hidden = session.mismatches.count - visible
        var differences = "\(visible) difference\(visible == 1 ? "" : "s")"
        if hidden > 0 {
            differences += " (\(hidden) ignored)"
        }
        let paired = "\(session.pairedCount) event\(session.pairedCount == 1 ? "" : "s") paired"
        return session.isComparing ? "Comparing… \(paired) · \(differences)" : "\(paired) · \(differences)"
    }
}

/// What the comparison ignores: each rule can be removed, or all of them at once
private struct IgnoredRulesView: View {
    @ObservedObject var store: CompareIgnoreStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Ignored Differences", systemImage: "eye.slash")
                    .font(.headline)
                Spacer()
                Button("Clear All", role: .destructive) {
                    store.removeAll()
                }
                .controlSize(.small)
                .disabled(store.rules.isEmpty)
            }

            if store.rules.isEmpty {
                Text("Nothing is ignored. Use the \(Image(systemName: "eye.slash")) button on a difference to ignore it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
            } else {
                List {
                    ForEach(store.rules) { rule in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.title)
                                    .font(.system(.body, design: .monospaced))
                                Text(rule.scope)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                store.remove(rule)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("Stop ignoring this")
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
                .frame(height: min(CGFloat(store.rules.count) * 44 + 16, 320))
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}

/// One recorded difference in the list
private struct MismatchRow: View {
    let mismatch: CompareMismatch
    let leftName: String
    let rightName: String

    var body: some View {
        MismatchSummary(mismatch: mismatch, leftName: leftName, rightName: rightName, isSelectable: false)
            .padding(.vertical, 2)
            .contextMenu {
                if let line = mismatch.leftRawLine {
                    Button("Copy \(leftName) Log", systemImage: "doc.on.doc") { copy(line) }
                }
                if let line = mismatch.rightRawLine {
                    Button("Copy \(rightName) Log", systemImage: "doc.on.doc") { copy(line) }
                }
            }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// What differs: the event, which values differ, which fields only one device logged
private struct MismatchSummary: View {
    let mismatch: CompareMismatch
    let leftName: String
    let rightName: String
    /// Text selection in the detail pane only: in the list it would swallow the clicks selecting the row
    let isSelectable: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: mismatch.kind == .missingOnOtherSide ? "questionmark.diamond" : "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(mismatch.eventName)
                    .font(.system(.body, design: .monospaced, weight: .medium))
                    .foregroundStyle(theme.text)
                if let timestamp = mismatch.leftTimestamp ?? mismatch.rightTimestamp, !timestamp.isEmpty {
                    Text(timestamp)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            switch mismatch.kind {
            case .missingOnOtherSide:
                Text("Only logged by \(mismatch.leftRawLine != nil ? leftName : rightName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .fieldsDiffer:
                ForEach(mismatch.differentValues, id: \.key) { difference in
                    detailLine("\(difference.key): \(difference.left)  ≠  \(difference.right)", color: theme.text)
                }
                if !mismatch.onlyOnLeft.isEmpty {
                    detailLine("Only on \(leftName): \(mismatch.onlyOnLeft.joined(separator: ", "))", color: .secondary)
                }
                if !mismatch.onlyOnRight.isEmpty {
                    detailLine("Only on \(rightName): \(mismatch.onlyOnRight.joined(separator: ", "))", color: .secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func detailLine(_ text: String, color: Color) -> some View {
        let line = Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(color)
        if isSelectable {
            line.textSelection(.enabled)
        } else {
            line
        }
    }
}

