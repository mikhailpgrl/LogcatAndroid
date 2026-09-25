//
//  FixListView.swift
//  LogCatAndroid
//

import SwiftUI

/// Sidebar list of the logs flagged for a fix
struct FixListView: View {
    @ObservedObject var store: FixListStore
    /// Called when the user asks to see an item's log, to open and highlight it
    let onReveal: (FixItem) -> Void
    @Environment(\.appTheme) private var theme

    /// Briefly true after the list was copied, to confirm the action on the button
    @State private var justCopied = false

    /// Puts the Slack-formatted list on the clipboard and shows a short confirmation
    private func copyForSlack() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.slackExport(), forType: .string)
        justCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            justCopied = false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("To Fix", systemImage: "wrench.and.screwdriver")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                if !store.items.isEmpty {
                    Text("\(store.items.count)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(theme.accent.opacity(0.15))
                        .clipShape(.capsule)
                }

                Spacer()

                if !store.items.isEmpty {
                    Button {
                        copyForSlack()
                    } label: {
                        Label(justCopied ? "Copied" : "Slack",
                              systemImage: justCopied ? "checkmark" : "doc.on.clipboard")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(justCopied ? theme.accent : .secondary)
                    .help("Copy the list to the clipboard, formatted for Slack")

                    Button("Clear", role: .destructive) {
                        store.removeAll()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // Keep the destructive action clearly apart from the copy button
                    .padding(.leading, 12)
                    .help("Remove every item from the list")
                }
            }

            if store.items.isEmpty {
                Text("Double-click a field in a log to add it here.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(store.items) { item in
                            FixItemRow(
                                item: item,
                                onReveal: { onReveal(item) },
                                onRemove: { store.remove(item) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }
}

// MARK: - Fix Item Row

/// One flagged log: event name, the field to change and the user's note
struct FixItemRow: View {
    let item: FixItem
    let onReveal: () -> Void
    let onRemove: () -> Void
    @Environment(\.appTheme) private var theme
    @State private var isHovering = false
    @State private var showRemoveConfirmation = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.eventName)
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)

                Text("\(item.fieldKey) = \(item.fieldValue)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !item.note.isEmpty {
                    Text(item.note)
                        .font(.caption2)
                        .italic()
                        .foregroundStyle(theme.accent)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Button {
                    onReveal()
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
                .help("Show this log and highlight the field")

                Button {
                    showRemoveConfirmation = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from list")
            }
            .opacity(isHovering ? 1 : 0.4)
        }
        .padding(8)
        .background(theme.surface.opacity(isHovering ? 0.6 : 0.3))
        .clipShape(.rect(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { onReveal() }
        .onHover { isHovering = $0 }
        .alert("Remove this log from the list?", isPresented: $showRemoveConfirmation) {
            Button("Remove", role: .destructive) { onRemove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(item.eventName) · \(item.fieldKey)")
        }
    }
}

#Preview("Fix item row") {
    let entry = LogEntry.parse(
        line: "09-25 11:11:44.394 19903 26403 D Analytics: event=add_to_cart params={currency=USD, items=[{item_name=Classic Pet Portrait, price=19.99}]}",
        index: 0
    )
    VStack(spacing: 4) {
        FixItemRow(
            item: FixItem(entry: entry, fieldKey: "params.items[0].price", fieldValue: "19.99",
                          note: "Should be a string, not a number"),
            onReveal: {}, onRemove: {}
        )
        FixItemRow(
            item: FixItem(entry: entry, fieldKey: "event", fieldValue: "add_to_cart", note: ""),
            onReveal: {}, onRemove: {}
        )
    }
    .padding(12)
    .frame(width: 280)
}

// MARK: - Add To Fix List Popover

/// Popover shown on double-click of a field: confirms the field and asks what needs fixing
struct AddToFixListPopover: View {
    let fieldKey: String
    let fieldValue: String
    /// Called with the note when the user confirms
    let onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Add to Fix List", systemImage: "wrench.and.screwdriver")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text(fieldKey)
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(fieldValue)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary)
            .clipShape(.rect(cornerRadius: 8))

            TextField("What needs to be fixed?", text: $note, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    onAdd(note.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 340)
    }
}

#Preview("Add popover") {
    AddToFixListPopover(fieldKey: "params.items[0].item_name", fieldValue: "Classic Pet Portrait") { _ in }
}
