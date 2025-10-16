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
    @State private var autoScroll: Bool = true

    var filteredLogs: [String] {
        let keywords = searchText
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { String($0).lowercased() }
            .filter { !$0.isEmpty }
        guard !keywords.isEmpty else { return adbManager.logLines }

        return adbManager.logLines.filter { line in
            let lowerLine = line.lowercased()
            return keywords.allSatisfy { lowerLine.contains($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading) {
            DeviceSelectorView(adbManager: adbManager)
            
            HStack {
                Circle()
                    .fill(adbManager.isLogcatRunning ? Color.green : Color.red)
                    .frame(width: 12, height: 12)
                Text(adbManager.isLogcatRunning ? "Logcat Running" : "Logcat Stopped")
                    .foregroundColor(adbManager.isLogcatRunning ? .green : .red)
                    .font(.caption)
            }
            .padding(.horizontal)
            
            // Search bar + toggle
            HStack {
                TextField("Search logs...", text: $searchText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding(.horizontal)

                Toggle("Auto Scroll", isOn: $autoScroll)
                    .padding(.trailing)
            }
            .padding(.top)
            
            // Logs display
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(filteredLogs.enumerated()), id: \.offset) { index, line in
                            highlightedText(for: line)
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }
                .background(Color.black)
                .onChange(of: filteredLogs.count) { _ in
                    if autoScroll, let last = filteredLogs.indices.last {
                        DispatchQueue.main.async {
                            withAnimation {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            
            // Buttons
            HStack {
                Button("Start Logcat") {
                    adbManager.startLogcat()
                }
                Button("Stop Logcat") {
                    adbManager.stopLogcat()
                }
            }
            .padding()
            .padding(.leading, 10)
        }
        .onAppear {
            adbManager.refreshDevices()
        }
        .frame(minWidth: 800, minHeight: 600)
    }

    func highlightedText(for line: String) -> Text {
        let lowerLine = line.lowercased()
        let keywords = searchText
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { String($0).lowercased() }
            .filter { !$0.isEmpty }

        guard !keywords.isEmpty else {
            return Text(line).foregroundColor(.green)
        }

        // Find all matches
        let matches = keywords
            .flatMap { keyword in
                lowerLine.ranges(of: keyword)
            }
            .sorted { $0.lowerBound < $1.lowerBound }

        var result = Text("")
        var currentIndex = line.startIndex
        var matchIndex = 0

        while currentIndex < line.endIndex {
            if matchIndex < matches.count {
                let matchRange = matches[matchIndex]

                if currentIndex < matchRange.lowerBound {
                    let nonMatchRange = currentIndex..<matchRange.lowerBound
                    let nonMatchText = String(line[nonMatchRange])
                    result = result + Text(nonMatchText).foregroundColor(.green)
                    currentIndex = matchRange.lowerBound
                } else {
                    let matchText = String(line[matchRange])
                    var attributed = AttributedString(matchText)
                    attributed.foregroundColor = .white
                    attributed.backgroundColor = .green
                    // Uncomment to add underline
                    // attributed.underlineStyle = .single

                    result = result + Text(attributed)
                    currentIndex = matchRange.upperBound
                    matchIndex += 1
                }
            } else {
                let remainingRange = currentIndex..<line.endIndex
                let remainingText = String(line[remainingRange])
                result = result + Text(remainingText).foregroundColor(.green)
                break
            }
        }

        return result
    }

}

// MARK: - String Extension for Finding All Ranges
extension String {
    func ranges(of searchString: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStartIndex = self.startIndex

        while searchStartIndex < self.endIndex,
              let range = self.range(of: searchString, options: [.caseInsensitive], range: searchStartIndex..<self.endIndex) {
            ranges.append(range)
            searchStartIndex = range.upperBound
        }

        return ranges
    }
}
