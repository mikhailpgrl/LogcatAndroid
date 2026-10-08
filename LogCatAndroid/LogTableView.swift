//
//  LogTableView.swift
//  LogCatAndroid
//

import AppKit
import SwiftUI

/// The log list, backed by an `NSTableView`. A SwiftUI `List` diffs every row on each update,
/// which saturates the main thread past a few thousand entries; the table only builds the visible
/// rows, so it keeps up with a full buffer (`ADBManager.maxEntries`) while logs stream in.
struct LogTableView: NSViewRepresentable {
    /// The entries to show, newest first
    let entries: [LogEntry]
    @Binding var selection: LogEntry.ID?
    /// Entry to bring into view, reset once scrolled to
    @Binding var scrollTarget: LogEntry.ID?
    @Environment(\.appTheme) private var theme

    /// Every row has the same height, so keeping the scroll position is plain arithmetic
    static let rowHeight: CGFloat = 40

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("log"))
        column.resizingMask = .autoresizingMask

        let tableView = NSTableView()
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        context.coordinator.tableView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(with: self)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var parent: LogTableView
        weak var tableView: NSTableView?
        private var entries: [LogEntry] = []
        /// Set while the table is reloaded or reselected programmatically, so that is not
        /// mistaken for the user picking a row
        private var isUpdating = false

        init(_ parent: LogTableView) {
            self.parent = parent
        }

        func update(with parent: LogTableView) {
            self.parent = parent
            guard let tableView, let scrollView = tableView.enclosingScrollView else { return }

            let background = NSColor(parent.theme.background)
            tableView.backgroundColor = background
            scrollView.backgroundColor = background

            // What is on screen before the update, to keep it in place when rows arrive on top
            let clipView = scrollView.contentView
            let firstVisibleRow = tableView.rows(in: clipView.documentVisibleRect).location
            let isAtTop = clipView.bounds.minY <= -scrollView.contentInsets.top + 1
            let anchorID = entries.indices.contains(firstVisibleRow) ? entries[firstVisibleRow].id : nil

            isUpdating = true
            entries = parent.entries
            tableView.reloadData()
            let selectedRow = parent.selection.flatMap { id in entries.firstIndex { $0.id == id } }
            if let selectedRow {
                tableView.selectRowIndexes([selectedRow], byExtendingSelection: false)
            } else {
                tableView.deselectAll(nil)
            }
            isUpdating = false

            if let target = parent.scrollTarget {
                if let row = entries.firstIndex(where: { $0.id == target }) {
                    scrollToCenter(row: row, in: tableView)
                }
                // Reset outside of the view update, so the same entry can be revealed again later
                DispatchQueue.main.async { parent.scrollTarget = nil }
            } else if isAtTop, parent.selection == nil {
                // Following the stream: show the newest entry
                tableView.scrollRowToVisible(0)
            } else if let anchorID, let row = entries.firstIndex(where: { $0.id == anchorID }), row != firstVisibleRow {
                // Reading older entries: shift by the rows inserted above so the content stays still
                let delta = CGFloat(row - firstVisibleRow) * LogTableView.rowHeight
                clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: clipView.bounds.minY + delta))
                scrollView.reflectScrolledClipView(clipView)
            }
        }

        private func scrollToCenter(row: Int, in tableView: NSTableView) {
            guard let clipView = tableView.enclosingScrollView?.contentView else { return }
            let rowRect = tableView.rect(ofRow: row)
            let y = rowRect.midY - clipView.bounds.height / 2
            clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: max(y, -clipView.contentInsets.top)))
            tableView.enclosingScrollView?.reflectScrolledClipView(clipView)
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            entries.count
        }

        // MARK: NSTableViewDelegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = LogRowCell(entry: entries[row], theme: parent.theme)
            let identifier = NSUserInterfaceItemIdentifier("LogRow")

            if let host = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSHostingView<LogRowCell> {
                host.rootView = cell
                return host
            }
            let host = NSHostingView(rootView: cell)
            host.identifier = identifier
            // The table sizes the cell: no intrinsic size constraints fighting it
            host.sizingOptions = []
            return host
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let tableView else { return }
            let row = tableView.selectedRow
            let id = entries.indices.contains(row) ? entries[row].id : nil
            if parent.selection != id {
                parent.selection = id
            }
        }
    }
}

/// A row of the log table, hosted in an `NSHostingView`
struct LogRowCell: View {
    let entry: LogEntry
    let theme: AppTheme

    var body: some View {
        LogRowView(entry: entry)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .environment(\.appTheme, theme)
    }
}
