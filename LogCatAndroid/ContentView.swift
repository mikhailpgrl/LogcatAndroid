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
            // Keep only lines containing ALL keywords (AND search)
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
            }.padding(.horizontal)  // <-- Add horizontal padding here
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
                            Text(line)
                                .foregroundColor(.green)
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
                        // Scroll to last line if auto-scroll enabled
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
            
        }.onAppear{
            adbManager.refreshDevices()
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}
