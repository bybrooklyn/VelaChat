import AppKit
import Observation

/// Fetches real provider logos: the provider's own site first
/// (apple-touch-icon, then favicon), Google's favicon service as fallback,
/// cached on disk in Application Support — with the hand-drawn vector mark
/// as the always-available last resort (offline, blocked, or just ugly
/// results never leave a blank tile).
@MainActor
@Observable
final class RemoteLogoLoader {
    static let shared = RemoteLogoLoader()

    private(set) var images: [String: NSImage] = [:]
    private var failedHosts: Set<String> = []
    private var inFlight: Set<String> = []
    private let directory: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("VelaChat/logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Loads from memory/disk or kicks a single network fetch for the host.
    /// Idempotent and cheap to call from `.task` on every appearance.
    func ensure(host: String) async {
        guard images[host] == nil, !failedHosts.contains(host), !inFlight.contains(host) else { return }
        let file = directory.appendingPathComponent("\(host).png")
        if let cached = NSImage(contentsOf: file), cached.isValid {
            images[host] = cached
            return
        }
        inFlight.insert(host)
        defer { inFlight.remove(host) }

        let candidates = [
            "https://\(host)/apple-touch-icon.png",
            "https://\(host)/favicon.ico",
            "https://www.google.com/s2/favicons?domain=\(host)&sz=64"
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count > 100,
                  let image = NSImage(data: data),
                  image.size.width >= 16 else { continue }
            if let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: file)
            }
            images[host] = image
            return
        }
        // Negative-cached for this session only — a network blip shouldn't
        // pin the fallback mark forever.
        failedHosts.insert(host)
    }
}
