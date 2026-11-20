import SwiftUI
import AppKit

@main
struct TempoSortApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @State private var showDisclaimer = false

    var body: some Scene {
        WindowGroup("Tempo Sort") {
            ContentView()
                .environmentObject(model)
                .sheet(isPresented: $showDisclaimer) { DisclaimerSheet(required: false) { showDisclaimer = false } }
                .task { await Snapshot.runIfAsked(model) }
        }
        .defaultSize(width: 1100, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Choose Music Folder…") { model.chooseFolder() }.keyboardShortcut("o")
            }
            CommandGroup(after: .newItem) {
                Button("Find BPMs Again (Ignore Saved)") { model.scan(rescanAll: true) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.folder == nil || model.busy)
            }
            CommandGroup(replacing: .help) {
                Button("Disclaimer") { showDisclaimer = true }
                Button("Show Logs Folder") {
                    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("Tempo Sort/Logs", isDirectory: true)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(dir)
                }
            }
        }

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Key.useTags) var useTags = true
    @AppStorage(Key.window) var windowSetting = 0
    @State private var cleared = false

    var body: some View {
        Form {
            Section("Finding the BPM") {
                Toggle("Use the BPM in the file's tag when there is one", isOn: $useTags)
                Text("Tags from Rekordbox, Serato, Traktor, Mixed In Key or your store are usually right and instant. Turn this off to detect every track from its audio.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Detected tempos fall between", selection: $windowSetting) {
                    Text("Automatic (\(Analyzer.automaticWindow(for: model.ranges))–\(Analyzer.automaticWindow(for: model.ranges) * 2), from your ranges)").tag(0)
                    ForEach([60, 70, 80, 85, 90, 100], id: \.self) { Text("\($0)–\($0 * 2) BPM").tag($0) }
                }
                Text("Detection can't always tell 85 from 170 (double time). It always answers inside this window. Automatic starts it at your lowest range.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Saved BPMs") {
                HStack {
                    Text("BPMs are remembered, so scanning the same files again is instant.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(cleared ? "Forgotten" : "Forget saved BPMs") { BPMCache.shared.clear(); cleared = true; model.phase = .idle }
                        .disabled(cleared)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onChange(of: windowSetting) { _, _ in model.phase = .idle }
    }
}

// MARK: - Disclaimer

enum Disclaimer {
    static let version = 1
    static let text = """
    Tempo Sort copies or moves your files. Please read this before you use it.

    Back up first. Moving changes where your files live. Keep a backup of your music before sorting, especially before using Move.

    BPMs can be wrong. Detected tempos are an estimate. A track can land in the wrong folder, often at half or double its real tempo. BPM tags in your files can also be wrong. Check the list before you sort.

    Your files, your choice. You choose the folder, the ranges and whether files are copied or moved. Tempo Sort doesn't change the contents of your audio files, and it never overwrites a file: a name that's already taken gets a number. Copies use extra disk space.

    No warranty. Tempo Sort is provided "as is", without warranty of any kind, express or implied, including merchantability, fitness for a particular purpose and non-infringement.

    Limitation of liability. To the fullest extent the law allows, the author is not liable for any loss of data, files, time, income or any other damage, direct or indirect, arising from using or not being able to use Tempo Sort, even if told such damage was possible. If your law doesn't allow some of these limits, they apply as far as it does.

    By clicking I Agree you accept these terms.
    """
}

struct DisclaimerSheet: View {
    var required: Bool
    var onAgree: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Before you start", systemImage: "exclamationmark.shield.fill")
                .font(.title2.bold()).foregroundStyle(.orange)
            ScrollView {
                Text(Disclaimer.text).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 320)
            HStack {
                if required { Button("Quit") { NSApp.terminate(nil) } }
                Spacer()
                Button(required ? "I Agree" : "Close", action: onAgree).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 500)
        .interactiveDismissDisabled(required)
    }
}
