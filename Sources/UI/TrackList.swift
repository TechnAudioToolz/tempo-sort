import SwiftUI
import AppKit

enum TrackFilter: String, CaseIterable, Identifiable {
    case all = "All", sorting = "Will be sorted", outside = "Outside ranges", unreadable = "No BPM"
    var id: String { rawValue }
}

struct TrackList: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Key.other) var useOther = false        // re-draws when it changes
    @State private var filter: TrackFilter = .all
    @State private var search = ""
    @State private var selection = Set<URL>()

    var shown: [Track] {
        model.tracks.filter { t in
            let ok: Bool
            switch filter {
            case .all: ok = true
            case .sorting: ok = model.target(for: t) != nil
            case .outside: ok = t.bpm != nil && model.target(for: t) == nil
            case .unreadable: ok = t.failed
            }
            return ok && (search.isEmpty || t.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            summary.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if model.folder == nil {
                empty("Choose a music folder", "Tempo Sort looks through it and every subfolder, finds each track's BPM, then copies or moves it into a folder for its range.", "folder")
            } else if model.tracks.isEmpty {
                empty("No audio files here", "Tempo Sort looks for MP3, WAV, AIFF, FLAC, M4A and AAC files in the folder and its subfolders.", "music.note")
            } else {
                Table(shown, selection: $selection) {
                    TableColumn("Track") { t in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.name).lineLimit(1).truncationMode(.middle)
                            Text(relativeFolder(t)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                    }
                    TableColumn("BPM") { t in
                        HStack(spacing: 4) {
                            Text(t.bpmText).monospacedDigit().foregroundStyle(t.bpm == nil ? .secondary : .primary)
                            if let o = t.origin {
                                Image(systemName: o == .tag ? "tag" : "waveform")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .help(o == .tag ? "From the file's BPM tag" : "Detected from the audio")
                            }
                        }
                    }
                    .width(min: 70, ideal: 80, max: 100)
                    TableColumn("Goes to") { t in destination(t) }
                        .width(min: 120, ideal: 150, max: 200)
                }
                .contextMenu(forSelectionType: URL.self) { urls in
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
                } primaryAction: { urls in
                    NSWorkspace.shared.activateFileViewerSelecting(Array(urls))
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Find a track")
    }

    var summary: some View {
        HStack(spacing: 6) {
            ForEach(model.ranges) { r in
                chip("\(r.low)–\(r.high)", model.phase == .idle ? nil : model.count(in: r), model.color(for: r.folderName))
            }
            if model.phase != .idle && model.outsideCount > 0 {
                chip(useOther ? TempoRange.otherFolderName : "outside ranges", model.outsideCount, .gray)
            }
            if model.noBPMCount > 0 { chip("no BPM", model.noBPMCount, .red) }
            Spacer()
            Picker("Show", selection: $filter) {
                ForEach(TrackFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
        }
    }

    func chip(_ label: String, _ n: Int?, _ c: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text(label).font(.caption).lineLimit(1).fixedSize()
            if let n { Text("\(n)").font(.caption.monospacedDigit().bold()) }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(c.opacity(0.13)))
        .fixedSize()
    }

    @ViewBuilder
    func destination(_ t: Track) -> some View {
        if let placed = model.placed[t.url] {
            Label(placed, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(model.color(for: placed))
        } else if let f = model.target(for: t) {
            Text(f).font(.caption.monospaced())
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(model.color(for: f).opacity(0.18)))
        } else if t.bpm != nil {
            Text("stays").font(.caption).foregroundStyle(.secondary)
        } else if t.failed {
            Text("stays (no BPM)").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    func relativeFolder(_ t: Track) -> String {
        guard let root = model.folder?.path else { return "" }
        let dir = t.url.deletingLastPathComponent().path
        let rel = dir.hasPrefix(root) ? String(dir.dropFirst(root.count)) : dir
        return (model.folder?.lastPathComponent ?? "") + rel
    }

    func empty(_ title: String, _ text: String, _ icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
