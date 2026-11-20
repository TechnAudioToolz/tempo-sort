import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Key.mode) var modeRaw = SortMode.copy.rawValue
    @AppStorage(Key.other) var useOther = false
    @AppStorage(Key.useTags) var useTags = true
    @AppStorage(Key.window) var windowSetting = 0
    @AppStorage(Key.disclaimer) var accepted = 0
    @State private var confirmSort = false
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 360)
                .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            TrackList()
        }
        .frame(minWidth: 1000, minHeight: 680)
        .sheet(isPresented: Binding(get: { accepted < Disclaimer.version }, set: { _ in })) {
            DisclaimerSheet(required: true) { accepted = Disclaimer.version }
        }
        .confirmationDialog(confirmTitle, isPresented: $confirmSort) {
            Button(model.mode == .move ? "Move \(model.plan.count) Tracks" : "Copy \(model.plan.count) Tracks") { model.sort() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(confirmMessage) }
        .onChange(of: windowSetting) { _, _ in if model.phase != .idle { model.phase = .idle } }
        .onChange(of: useTags) { _, _ in if model.phase != .idle { model.phase = .idle } }
    }

    // MARK: Left column: the three steps and the button

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    folderStep
                    rangesStep
                    modeStep
                }
                .padding(20)
            }
            Divider()
            actionArea.padding(20)
        }
    }

    func stepTitle(_ n: Int, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text("\(n)").font(.caption.bold()).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(Circle().fill(Color.accentColor))
            Text(title).font(.headline)
        }
    }

    var folderStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepTitle(1, "Music folder")
            Button(action: model.chooseFolder) {
                HStack(spacing: 10) {
                    Image(systemName: model.folder == nil ? "folder.badge.plus" : "folder.fill")
                        .font(.title2).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.folder?.lastPathComponent ?? "Choose a folder…").font(.body.weight(.medium))
                        Text(model.folder.map { shortPath($0.path) } ?? "or drop one here")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    Spacer()
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(dropTargeted ? 0.12 : 0.05)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(dropTargeted ? Color.accentColor : .clear, lineWidth: 2))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.busy)
            .dropDestination(for: URL.self) { urls, _ in
                guard let u = urls.first, (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return false }
                model.folder = u; return true
            } isTargeted: { dropTargeted = $0 }
            if model.folder != nil {
                Text("\(model.tracks.count) audio file\(model.tracks.count == 1 ? "" : "s"), subfolders included")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var rangesStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                stepTitle(2, "BPM ranges")
                Spacer()
                Menu("Presets") {
                    Button("Hip-hop and R&B: 60–80, 80–95, 95–110") { model.usePreset([(60, 80), (80, 95), (95, 110)]) }
                    Button("House and techno: 115–122, 122–126, 126–130, 130–140") { model.usePreset([(115, 122), (122, 126), (126, 130), (130, 140)]) }
                    Button("Open format: 70–90, 90–110, 110–125, 125–140, 140–180") { model.usePreset([(70, 90), (90, 110), (110, 125), (125, 140), (140, 180)]) }
                    Button("Workout: 100–120, 120–140, 140–160") { model.usePreset([(100, 120), (120, 140), (140, 160)]) }
                }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.busy)
            }
            ForEach($model.ranges) { $r in
                RangeRow(range: $r, color: model.color(for: r.folderName),
                         count: model.phase == .idle ? nil : model.count(in: r),
                         canRemove: model.ranges.count > TempoRange.minCount,
                         folder: model.folder?.lastPathComponent) { model.removeRange(r) }
                    .disabled(model.busy)
            }
            if model.ranges.count < TempoRange.maxCount {
                Button { model.addRange() } label: { Label("Add range", systemImage: "plus") }
                    .buttonStyle(.borderless).disabled(model.busy)
            }
            if let p = model.rangeProblem {
                Label(p, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            } else {
                Text("A track right on a border (like 100) goes to the first range that has it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var modeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepTitle(3, "Copy or move")
            Picker("", selection: $modeRaw) {
                Text("Copy").tag(SortMode.copy.rawValue)
                Text("Move").tag(SortMode.move.rawValue)
            }
            .pickerStyle(.segmented).labelsHidden().disabled(model.busy)
            if modeRaw == SortMode.move.rawValue {
                Label("Tracks leave their current folders. You can undo right after.", systemImage: "arrow.right.doc.on.clipboard")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Label("Originals stay where they are. Copies use extra disk space.", systemImage: "doc.on.doc")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Put tracks outside every range in “\(TempoRange.otherFolderName)”", isOn: $useOther)
                .font(.callout).disabled(model.busy)
        }
    }

    // MARK: The big button

    @ViewBuilder
    var actionArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.phase {
            case .scanning(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1))) {
                    Text("Finding BPMs… \(done) of \(total)").font(.callout)
                }
                Button("Stop", action: model.stop).frame(maxWidth: .infinity)
            case .sorting(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1))) {
                    Text("\(model.lastMode == .move ? "Moving" : "Copying")… \(done) of \(total)").font(.callout)
                }
                Button("Stop", action: model.stop).frame(maxWidth: .infinity)
            case .idle:
                big(model.folder == nil ? "Choose a folder first" : "Find BPMs of \(model.tracks.count) tracks",
                    icon: "waveform.badge.magnifyingglass", enabled: model.folder != nil && !model.tracks.isEmpty) { model.scan() }
            case .ready, .finished:
                let n = model.plan.count
                big(n == 0 ? "Nothing to \(model.mode.rawValue)" : "\(model.mode == .move ? "Move" : "Copy") \(n) track\(n == 1 ? "" : "s")",
                    icon: model.mode == .move ? "arrow.right.doc.on.clipboard" : "doc.on.doc",
                    enabled: n > 0 && model.rangeProblem == nil) { confirmSort = true }
                HStack {
                    Button("Scan again") { model.scan() }.buttonStyle(.borderless).font(.caption)
                    Spacer()
                    if !model.lastOps.isEmpty {
                        Button("Undo \(model.lastMode == .move ? "move" : "copy")") { model.undo() }.font(.caption)
                    }
                }
            }
            if let m = model.message {
                Text(m).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.phase == .finished, model.message?.contains("Not enough") == false {
                    Button("Show in Finder", action: model.revealFolder).font(.caption)
                }
            }
        }
    }

    func big(_ title: String, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.title3.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!enabled)
        .keyboardShortcut(.defaultAction)
    }

    var confirmTitle: String {
        "\(model.mode == .move ? "Move" : "Copy") \(model.plan.count) tracks into BPM folders?"
    }

    var confirmMessage: String {
        let folders = Set(model.plan.compactMap { model.target(for: $0) }).sorted().joined(separator: ", ")
        let place = model.folder?.lastPathComponent ?? "your folder"
        if model.mode == .move {
            return "They'll be moved into \(folders) inside “\(place)”. Nothing is overwritten: a name that's taken gets a number. You can undo this right after. Make sure you have a backup."
        }
        return "Copies go into \(folders) inside “\(place)” and take about \(bytes(model.copyBytes)). Your originals aren't changed."
    }

    func shortPath(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}

// MARK: - One range: low – high, the folder it makes, how many tracks

struct RangeRow: View {
    @Binding var range: TempoRange
    var color: Color
    var count: Int?
    var canRemove: Bool
    var folder: String?
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 6, height: 22)
                field($range.low)
                Text("–").foregroundStyle(.secondary)
                field($range.high)
                Text("BPM").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                if let count {
                    Text("\(count)").font(.callout.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(color.opacity(0.18)))
                        .help("\(count) track\(count == 1 ? "" : "s") go here")
                }
                Button(action: onRemove) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless).disabled(!canRemove).help("Remove this range")
            }
            Text("→ \(folder.map { "\($0)/" } ?? "")\(range.folderName)")
                .font(.caption.monospaced()).foregroundStyle(.secondary).padding(.leading, 12)
        }
    }

    func field(_ v: Binding<Int>) -> some View {
        TextField("", value: v, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder).frame(width: 52).multilineTextAlignment(.trailing)
    }
}
