import Foundation
import AppKit
import Vision
import IOKit.ps

/// Local, native capabilities that serve agentic work: machine state,
/// and on-device image understanding for models without vision. Every
/// value here is read from a real system API — nothing estimated.
@MainActor
enum SystemTools {
    // MARK: - system_status

    static func status() -> String {
        var lines: [String] = []

        if let battery = batteryLine() { lines.append(battery) }
        if let disk = diskLine() { lines.append(disk) }
        lines.append(memoryLine())
        lines.append("Uptime: \(uptimeLine())")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        if let media = nowPlayingLine() { lines.append(media) }

        return lines.joined(separator: "\n")
    }

    private static func batteryLine() -> String? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let percent = Int(Double(capacity) / Double(max) * 100)
            let state = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue ? "on AC power" : "on battery"
            var line = "Battery: \(percent)%, \(state)"
            if let minutes = description[kIOPSTimeToEmptyKey] as? Int, minutes > 0 {
                line += ", ~\(minutes / 60)h \(minutes % 60)m remaining"
            }
            return line
        }
        return nil
    }

    private static func diskLine() -> String? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let available = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "Disk: \(formatter.string(fromByteCount: available)) free of \(formatter.string(fromByteCount: Int64(total)))"
    }

    private static func memoryLine() -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        let total = ProcessInfo.processInfo.physicalMemory
        return "Memory: \(formatter.string(fromByteCount: Int64(total))) installed"
    }

    private static func uptimeLine() -> String {
        let seconds = Int(ProcessInfo.processInfo.systemUptime)
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// Whatever app currently owns audio playback, by name — the private
    /// now-playing details aren't public API, so this reports only what
    /// NSWorkspace legitimately exposes.
    private static func nowPlayingLine() -> String? {
        let players: Set<String> = ["Music", "Spotify", "TV", "Podcasts", "VLC", "IINA", "QuickTime Player"]
        let running = NSWorkspace.shared.runningApplications
            .compactMap(\.localizedName)
            .filter { players.contains($0) }
        guard !running.isEmpty else { return nil }
        return "Media apps running: \(running.joined(separator: ", "))"
    }

    // MARK: - analyze_image

    /// On-device OCR + scene classification for an image attachment, so
    /// models without vision can still work with what the user sent.
    static func analyzeImage(data: Data, filename: String) async -> String {
        guard let image = NSImage(data: data), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return "Error: \(filename) could not be decoded as an image."
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        let classifyRequest = VNClassifyImageRequest()

        do {
            try handler.perform([textRequest, classifyRequest])
        } catch {
            return "Error analyzing \(filename): \(error.localizedDescription)"
        }

        var sections: [String] = ["Image: \(filename) (\(Int(image.size.width))×\(Int(image.size.height)))"]

        let lines = (textRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        if lines.isEmpty {
            sections.append("No readable text found.")
        } else {
            var text = lines.joined(separator: "\n")
            if text.count > 6_000 { text = String(text.prefix(6_000)) + "\n[Truncated.]" }
            sections.append("Text found in the image:\n\(text)")
        }

        let labels = (classifyRequest.results ?? [])
            .filter { $0.confidence > 0.25 }
            .prefix(6)
            .map { "\($0.identifier) (\(Int($0.confidence * 100))%)" }
        if !labels.isEmpty {
            sections.append("Visual content: \(labels.joined(separator: ", "))")
        }
        sections.append("(Analyzed on-device with Apple's Vision framework — OCR and scene labels only, not a full visual description.)")
        return sections.joined(separator: "\n\n")
    }
}
