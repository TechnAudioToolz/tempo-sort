// Makes royalty-free demo tracks (synthesized drum loops at known tempos) for screenshots and testing.
//   swift Tools/make_demo.swift "<output folder>"
import Foundation
import AVFoundation

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Demo Tracks", isDirectory: true)
let sr = 44100.0

// (subfolder, name, bpm, seconds, extension). All names are made up.
let tracks: [(String, String, Double, Double, String)] = [
    ("", "Lumen Drift - Harbor Lights (Extended Mix)", 124, 24, "m4a"),
    ("", "Velvet Static - Night Bus", 92, 24, "wav"),
    ("", "Orrin Vale - Paper Satellites", 128, 24, "m4a"),
    ("", "Kiko Marsh - Slow Tide", 86, 24, "aiff"),
    ("", "Quiet Engine - Low Orbit (Dub)", 118, 24, "m4a"),
    ("Promos", "Sable Arcade - Glass Hours", 126, 24, "m4a"),
    ("Promos", "Tamsin Rook - Afterglow Avenue", 104, 24, "wav"),
    ("Promos", "Noor Atlas - Copper Sky (Club Mix)", 132, 24, "m4a"),
    ("Promos", "Fenwick Hale - Static Bloom", 145, 24, "m4a"),
    ("Promos/Week 2", "Pell Moreau - Signal Fires", 122, 24, "aiff"),
    ("Promos/Week 2", "Juniper Coil - Undertow", 98, 24, "m4a"),
    ("Promos/Week 2", "Ardent Folk - Riverlight", 112, 24, "m4a"),
    ("Old Crate", "Marlo Finch - Second Wind", 138, 24, "wav"),
    ("Old Crate", "Ivo Brandt - Tin Roof Rain", 96, 24, "m4a"),
    ("Old Crate", "Calder Ray - Long Way Home", 150, 24, "m4a"),
    ("Old Crate", "riser fx 03", 128, 4, "wav"),          // too short for a BPM
]

var rng = SystemRandomNumberGenerator()
func render(bpm: Double, seconds: Double, seed: Double) -> [Float] {
    let n = Int(sr * seconds)
    var x = [Float](repeating: 0, count: n)
    let beat = 60 / bpm
    var t = 0.0, k = 0
    while t < seconds {
        let s = Int(t * sr)
        // Kick on every beat: falling sine with a fast decay.
        for i in 0..<min(Int(0.25 * sr), n - s) {
            let tt = Double(i) / sr
            let f = 50 + 90 * exp(-tt * 30)
            x[s + i] += Float(sin(2 * .pi * f * tt) * exp(-tt * 9) * 0.9)
        }
        // Hat on the off-beat.
        let h = Int((t + beat / 2) * sr)
        if h < n { for i in 0..<min(Int(0.04 * sr), n - h) { x[h + i] += Float.random(in: -1...1, using: &rng) * Float(exp(-Double(i) / sr * 90)) * 0.18 } }
        // A soft chord stab every 4 beats.
        if k % 4 == 2 {
            let root = 110 * pow(2, (seed.truncatingRemainder(dividingBy: 7)) / 12)
            for i in 0..<min(Int(beat * sr), n - s) {
                let tt = Double(i) / sr, env = exp(-tt * 5) * 0.12
                x[s + i] += Float(env * (sin(2 * .pi * root * tt) + sin(2 * .pi * root * 1.26 * tt) + sin(2 * .pi * root * 1.5 * tt)))
            }
        }
        t += beat; k += 1
    }
    let peak = x.map(abs).max() ?? 1
    return x.map { $0 / peak * 0.85 }
}

let fm = FileManager.default
for (i, (sub, name, bpm, secs, ext)) in tracks.enumerated() {
    let dir = sub.isEmpty ? out : out.appendingPathComponent(sub, isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let samples = render(bpm: bpm, seconds: secs, seed: Double(i * 3))
    let wavURL = dir.appendingPathComponent(name + ".wav")
    let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
    buf.frameLength = buf.frameCapacity
    samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 1,
                                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    do { let f = try AVAudioFile(forWriting: wavURL, settings: settings); try f.write(from: buf) }
    if ext != "wav" {
        let dest = dir.appendingPathComponent(name + "." + ext)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ext == "m4a" ? ["-f", "m4af", "-d", "aac", "-b", "96000", wavURL.path, dest.path]
                                   : ["-f", "AIFF", "-d", "BEI16", wavURL.path, dest.path]
        try p.run(); p.waitUntilExit()
        try fm.removeItem(at: wavURL)
    }
    print("\(Int(bpm)) BPM  \(sub.isEmpty ? "" : sub + "/")\(name).\(ext)")
}
