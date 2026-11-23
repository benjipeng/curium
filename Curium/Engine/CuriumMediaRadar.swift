import CuriumEngineContract
import Foundation
import Observation

/// Structured media resource candidate captured from Build 41's
/// `CrIOSBrowserHostDelegateV1.browserHost(_:tab:didLoadResourceEvent:)`.
struct CuriumMediaResourceEvent: Identifiable, Equatable, Sendable {
    enum StreamKind: String, Equatable, Sendable {
        case hls
        case dash
        case video
        case audio
    }

    let id: String
    let url: URL
    let originalURL: URL?
    let mimeType: String?
    let httpMethod: String?
    let httpStatusCode: Int
    let contentLength: Int64
    let requestDestination: String
    let referrer: URL?
    let frameURL: URL?
    let frameOrigin: String?
    let effectiveUserAgent: String?
    let kind: StreamKind
    let capturedAt: Date

    static func parse(
        from raw: [String: Any],
        effectiveUserAgent: String? = nil,
        now: Date = .now
    ) -> CuriumMediaResourceEvent? {
        guard let url = raw["url"] as? URL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        let rawMethod = (raw["httpMethod"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let httpMethod = (rawMethod?.isEmpty == false) ? rawMethod : nil
        if let httpMethod, httpMethod != "GET" {
            return nil
        }

        let status = (raw["httpStatusCode"] as? NSNumber)?.intValue ?? 0
        if status >= 400 {
            return nil
        }

        let mime = (raw["mimeType"] as? String)?
            .split(separator: ";", maxSplits: 1)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let dest = ((raw["requestDestination"] as? String) ?? "").lowercased()
        let contentLength = (raw["contentLength"] as? NSNumber)?.int64Value ?? -1

        guard let kind = classify(url: url, mimeType: mime, destination: dest) else {
            return nil
        }

        let originalURL = raw["originalURL"] as? URL
        let referrer = raw["referrer"] as? URL
        let frameURL = raw["frameURL"] as? URL
        let frameOrigin = raw["frameOrigin"] as? String
        let ua = effectiveUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines)

        return CuriumMediaResourceEvent(
            id: url.absoluteString,
            url: url,
            originalURL: originalURL,
            mimeType: mime?.isEmpty == false ? mime : nil,
            httpMethod: httpMethod,
            httpStatusCode: status,
            contentLength: contentLength,
            requestDestination: dest,
            referrer: referrer,
            frameURL: frameURL,
            frameOrigin: frameOrigin,
            effectiveUserAgent: ua?.isEmpty == false ? ua : nil,
            kind: kind,
            capturedAt: now
        )
    }

    static func classify(url: URL, mimeType: String?, destination: String) -> StreamKind? {
        let pathExt = url.pathExtension.lowercased()
        let mime = mimeType ?? ""

        // Ignore segmented transport chunks (.ts/.m4s/mp2t) so HLS/DASH streams do not
        // flood the bounded per-tab radar ahead of their master/media manifests.
        if pathExt == "ts" || pathExt == "m4s" || mime.contains("mp2t") {
            return nil
        }

        if pathExt == "m3u8" || mime == "application/vnd.apple.mpegurl" || mime == "application/x-mpegurl"
            || mime == "audio/mpegurl" || mime == "audio/x-mpegurl"
        {
            return .hls
        }
        if pathExt == "mpd" || mime == "application/dash+xml" {
            return .dash
        }
        if mime.hasPrefix("video/")
            || ["mp4", "m4v", "webm", "mov", "mkv"].contains(pathExt)
            || destination == "video"
        {
            return .video
        }
        if mime.hasPrefix("audio/")
            || ["mp3", "m4a", "aac", "ogg", "opus", "flac", "wav"].contains(pathExt)
            || destination == "audio"
        {
            return .audio
        }
        return nil
    }
}

/// Bounded per-tab media stream radar fed by Build 41's pre-filtered C++ resource callback.
@MainActor
@Observable
final class CuriumMediaRadar {
    static let maxEventsPerTab = 64

    private(set) var eventsByTabID: [String: [CuriumMediaResourceEvent]] = [:]

    func events(for tabID: String?) -> [CuriumMediaResourceEvent] {
        guard let tabID else { return [] }
        return eventsByTabID[tabID] ?? []
    }

    @discardableResult
    func ingest(
        rawEvent: [String: Any],
        tabID: String,
        effectiveUserAgent: String?
    ) -> CuriumMediaResourceEvent? {
        guard let parsed = CuriumMediaResourceEvent.parse(
            from: rawEvent,
            effectiveUserAgent: effectiveUserAgent
        ) else {
            return nil
        }

        var list = eventsByTabID[tabID] ?? []
        if let existingIndex = list.firstIndex(where: { $0.id == parsed.id }) {
            list[existingIndex] = parsed
        } else {
            list.insert(parsed, at: 0)
            if list.count > Self.maxEventsPerTab {
                list.removeLast(list.count - Self.maxEventsPerTab)
            }
        }
        eventsByTabID[tabID] = list
        return parsed
    }

    func clear(tabID: String) {
        eventsByTabID.removeValue(forKey: tabID)
    }
}

/// Sendable JSON value decoded from Build 42's isolated-world JavaScript evaluator.
enum CuriumJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CuriumJSONValue])
    case object([String: CuriumJSONValue])

    static func fromFoundation(_ raw: Any?) -> CuriumJSONValue? {
        guard let raw else { return nil }
        if raw is NSNull { return .null }
        if let num = raw as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return .bool(num.boolValue)
            }
            return .number(num.doubleValue)
        }
        if let str = raw as? String { return .string(str) }
        if let arr = raw as? [Any] {
            return .array(arr.map { fromFoundation($0) ?? .null })
        }
        if let dict = raw as? [String: Any] {
            var out: [String: CuriumJSONValue] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict {
                out[k] = fromFoundation(v) ?? .null
            }
            return .object(out)
        }
        return nil
    }
}

/// One frame's parsed output from Build 42's `evaluateJavaScriptInIsolatedWorld:allFrames:completion:`.
struct CuriumIsolatedFrameEvalResult: Equatable, Sendable {
    let isMainFrame: Bool
    let frameURL: URL?
    let frameOrigin: String?
    let result: CuriumJSONValue?

    static func parse(from raw: [String: Any]) -> CuriumIsolatedFrameEvalResult {
        let isMain = (raw["isMainFrame"] as? NSNumber)?.boolValue ?? false
        let frameURL = raw["frameURL"] as? URL
        let frameOrigin = raw["frameOrigin"] as? String
        let result = CuriumJSONValue.fromFoundation(raw["result"])
        return CuriumIsolatedFrameEvalResult(
            isMainFrame: isMain,
            frameURL: frameURL,
            frameOrigin: frameOrigin,
            result: result
        )
    }
}

/// Media element extracted from an isolated-world DOM scan across main and subframes.
struct CuriumDOMMediaEntry: Equatable, Sendable {
    let url: URL?
    let isBlob: Bool
    let tag: String
    let title: String?
    let width: Int?
    let height: Int?
    let durationSeconds: Double?
    let frameURL: URL?
    let frameOrigin: String?
    let mimeType: String?
}

/// Deduplicated, enriched media stream or file surfaced by Media Radar.
struct CuriumMediaCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let kind: CuriumMediaResourceEvent.StreamKind
    let title: String
    let host: String
    let mimeType: String?
    let contentLength: Int64
    let resolutionLabel: String?
    let durationSeconds: Double?
    let referrer: URL?
    let frameOrigin: String?
    let effectiveUserAgent: String?
    let fromDOM: Bool
    let fromNetwork: Bool

    var formatBadge: String {
        switch kind {
        case .hls:
            return "HLS"
        case .dash:
            return "DASH"
        case .video:
            let ext = url.pathExtension.lowercased()
            switch ext {
            case "mp4", "m4v", "webm", "mov", "mkv":
                return ext.uppercased()
            default:
                if let mime = mimeType?.lowercased() {
                    if mime.contains("mp4") { return "MP4" }
                    if mime.contains("webm") { return "WEBM" }
                    if mime.contains("quicktime") { return "MOV" }
                    if mime.contains("matroska") { return "MKV" }
                }
                return "VIDEO"
            }
        case .audio:
            let ext = url.pathExtension.lowercased()
            switch ext {
            case "mp3", "m4a", "aac", "ogg", "opus", "flac", "wav":
                return ext.uppercased()
            default:
                if let mime = mimeType?.lowercased() {
                    if mime.contains("mpeg") || mime.contains("mp3") { return "MP3" }
                    if mime.contains("mp4") || mime.contains("m4a") { return "M4A" }
                    if mime.contains("aac") { return "AAC" }
                    if mime.contains("opus") { return "OPUS" }
                    if mime.contains("ogg") { return "OGG" }
                    if mime.contains("flac") { return "FLAC" }
                    if mime.contains("wav") { return "WAV" }
                }
                return "AUDIO"
            }
        }
    }

    var formattedByteSize: String? {
        guard contentLength > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: contentLength, countStyle: .file)
    }

    var formattedDuration: String? {
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        let totalSeconds = Int(durationSeconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    var suggestedFilename: String {
        let ext = preferredFileExtension()
        let cleanedTitle = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let rawStem: String
        let titleNS = cleanedTitle as NSString
        let existingExt = titleNS.pathExtension.lowercased()
        if !existingExt.isEmpty,
           ["mp4", "m4v", "webm", "mov", "mkv", "ts", "m3u8", "mpd", "mp3", "m4a", "aac", "ogg", "opus", "flac", "wav"].contains(existingExt) {
            rawStem = titleNS.deletingPathExtension
        } else {
            rawStem = cleanedTitle
        }

        let safeStem = CuriumDownloadStorage.sanitizedFilename(rawStem, fallback: defaultFallbackStem)
        return CuriumDownloadStorage.sanitizedFilename("\(safeStem).\(ext)", fallback: "\(defaultFallbackStem).\(ext)")
    }

    private var defaultFallbackStem: String {
        switch kind {
        case .hls, .dash, .video:
            return "Video"
        case .audio:
            return "Audio"
        }
    }

    private func preferredFileExtension() -> String {
        let urlExt = url.pathExtension.lowercased()
        let mime = mimeType?.lowercased() ?? ""

        switch kind {
        case .hls:
            return "ts"
        case .dash:
            return "mpd"
        case .video:
            if ["mp4", "m4v", "webm", "mov", "mkv"].contains(urlExt) {
                return urlExt
            }
            if mime.contains("webm") { return "webm" }
            if mime.contains("quicktime") { return "mov" }
            if mime.contains("matroska") { return "mkv" }
            return "mp4"
        case .audio:
            if ["mp3", "m4a", "aac", "ogg", "opus", "flac", "wav"].contains(urlExt) {
                return urlExt
            }
            if mime.contains("mpeg") || mime.contains("mp3") { return "mp3" }
            if mime.contains("aac") { return "aac" }
            if mime.contains("opus") { return "opus" }
            if mime.contains("ogg") { return "ogg" }
            if mime.contains("flac") { return "flac" }
            if mime.contains("wav") { return "wav" }
            return "m4a"
        }
    }
}

/// Merged snapshot of network-captured and DOM-scanned media candidates for one tab.
struct CuriumMediaScanSnapshot: Equatable, Sendable {
    let tabID: String
    let pageTitle: String?
    let candidates: [CuriumMediaCandidate]
    let detectedBlobVideoCount: Int
    let scannedAt: Date
}

/// Isolated-world DOM media probe script, result parser, and network/DOM merger.
enum CuriumMediaDOMScanner {
    static let maxEntriesPerFrame = 32

    private static let genericStemNames: Set<String> = [
        "master", "index", "playlist", "manifest", "chunklist",
        "stream", "video", "audio", "media", "play", "watch", "embed",
    ]

    /// Synchronous, read-only probe script for Build 42's isolated-world evaluator.
    /// Wrapped in an IIFE + `try/catch`, collects `pageTitle`, `<video>`/`<audio>`/`<source>`
    /// sources, `blob:` counts, dimensions, and finite durations (capped at 32 per frame).
    static let probeScript: String = """
    (() => {
      try {
        const maxEntries = 32;
        const entries = [];
        let blobVideoCount = 0;
        const seen = new Set();
        const resolveURL = (raw) => {
          if (typeof raw !== "string") return "";
          const trimmed = raw.trim();
          if (!trimmed) return "";
          if (trimmed.startsWith("blob:")) return trimmed;
          try {
            return new URL(trimmed, document.baseURI || location.href).href;
          } catch (_) {
            return "";
          }
        };
        const cleanTitle = (el) => {
          const raw = el.getAttribute("title") || el.getAttribute("aria-label") || "";
          return typeof raw === "string" ? raw.trim() : "";
        };
        const mediaEls = document.querySelectorAll("video, audio");
        for (let i = 0; i < mediaEls.length && entries.length < maxEntries; i++) {
          const el = mediaEls[i];
          const tag = (el.tagName || "").toLowerCase();
          const width = tag === "video" && Number.isFinite(el.videoWidth) && el.videoWidth > 0 ? Math.round(el.videoWidth) : null;
          const height = tag === "video" && Number.isFinite(el.videoHeight) && el.videoHeight > 0 ? Math.round(el.videoHeight) : null;
          const duration = Number.isFinite(el.duration) && el.duration > 0 ? el.duration : null;
          const title = cleanTitle(el) || null;
          let countedBlobForElement = false;
          const rawSources = [];
          if (el.currentSrc) rawSources.push({ src: el.currentSrc, type: null, tag });
          if (el.src && el.src !== el.currentSrc) rawSources.push({ src: el.src, type: null, tag });
          const children = el.querySelectorAll("source");
          for (let j = 0; j < children.length; j++) {
            const srcNode = children[j];
            if (srcNode.src) {
              rawSources.push({ src: srcNode.src, type: srcNode.type || null, tag: "source" });
            }
          }
          for (let k = 0; k < rawSources.length && entries.length < maxEntries; k++) {
            const candidate = rawSources[k];
            const resolved = resolveURL(candidate.src);
            if (!resolved) continue;
            if (resolved.startsWith("blob:")) {
              if (tag === "video" && !countedBlobForElement) {
                countedBlobForElement = true;
                blobVideoCount += 1;
              }
              entries.push({
                url: null,
                isBlob: true,
                tag,
                title,
                width,
                height,
                duration,
                mimeType: candidate.type || null
              });
              continue;
            }
            if (seen.has(resolved)) continue;
            seen.add(resolved);
            entries.push({
              url: resolved,
              isBlob: false,
              tag: candidate.tag,
              title,
              width,
              height,
              duration,
              mimeType: candidate.type || null
            });
          }
        }
        const pageTitle = typeof document.title === "string" ? document.title.trim() : "";
        return {
          pageTitle: pageTitle || null,
          blobVideoCount,
          entries
        };
      } catch (_) {
        return { pageTitle: null, blobVideoCount: 0, entries: [] };
      }
    })()
    """

    static func parseProbeResults(
        _ frames: [CuriumIsolatedFrameEvalResult]
    ) -> (pageTitle: String?, entries: [CuriumDOMMediaEntry], blobVideoCount: Int) {
        var resolvedPageTitle: String?
        var fallbackPageTitle: String?
        var parsedEntries: [CuriumDOMMediaEntry] = []
        var totalBlobVideos = 0

        for frame in frames {
            guard case .object(let dict) = frame.result else { continue }

            if case .string(let rawTitle) = dict["pageTitle"] {
                let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    if frame.isMainFrame, resolvedPageTitle == nil {
                        resolvedPageTitle = trimmed
                    } else if fallbackPageTitle == nil {
                        fallbackPageTitle = trimmed
                    }
                }
            }

            let reportedBlobCount: Int
            if case .number(let n) = dict["blobVideoCount"], n.isFinite, n > 0 {
                reportedBlobCount = Int(n)
            } else {
                reportedBlobCount = 0
            }

            var frameBlobVideoEntries = 0
            if case .array(let rawItems) = dict["entries"] {
                for item in rawItems.prefix(maxEntriesPerFrame) {
                    guard case .object(let entryDict) = item else { continue }

                    let rawTag: String
                    if case .string(let t) = entryDict["tag"], !t.isEmpty {
                        rawTag = t.lowercased()
                    } else {
                        rawTag = "video"
                    }

                    let rawURLString: String?
                    if case .string(let s) = entryDict["url"] {
                        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        rawURLString = trimmed.isEmpty ? nil : trimmed
                    } else {
                        rawURLString = nil
                    }

                    let explicitBlob: Bool
                    if case .bool(let b) = entryDict["isBlob"] {
                        explicitBlob = b
                    } else {
                        explicitBlob = false
                    }
                    let isBlob = explicitBlob || (rawURLString?.lowercased().hasPrefix("blob:") == true)

                    let parsedURL: URL?
                    if isBlob {
                        parsedURL = nil
                        if rawTag != "audio" {
                            frameBlobVideoEntries += 1
                        }
                    } else if let rawURLString,
                              let candidateURL = URL(string: rawURLString),
                              CuriumHLSParser.isAllowedHTTPURL(candidateURL) {
                        parsedURL = candidateURL
                    } else {
                        // Drop non-HTTP(S) schemes (`file://`, `data:`, `javascript:`, etc.).
                        continue
                    }

                    let entryTitle: String?
                    if case .string(let t) = entryDict["title"] {
                        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                        entryTitle = trimmed.isEmpty ? nil : trimmed
                    } else {
                        entryTitle = nil
                    }

                    let width: Int?
                    if case .number(let w) = entryDict["width"], w.isFinite, w > 0 {
                        width = Int(w.rounded())
                    } else {
                        width = nil
                    }

                    let height: Int?
                    if case .number(let h) = entryDict["height"], h.isFinite, h > 0 {
                        height = Int(h.rounded())
                    } else {
                        height = nil
                    }

                    let duration: Double?
                    if case .number(let d) = entryDict["duration"] ?? entryDict["durationSeconds"],
                       d.isFinite, d > 0 {
                        duration = d
                    } else {
                        duration = nil
                    }

                    let mimeType: String?
                    if case .string(let m) = entryDict["mimeType"] {
                        let normalized = m
                            .split(separator: ";", maxSplits: 1).first?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .lowercased()
                        mimeType = (normalized?.isEmpty == false) ? normalized : nil
                    } else {
                        mimeType = nil
                    }

                    parsedEntries.append(
                        CuriumDOMMediaEntry(
                            url: parsedURL,
                            isBlob: isBlob,
                            tag: rawTag,
                            title: entryTitle,
                            width: width,
                            height: height,
                            durationSeconds: duration,
                            frameURL: frame.frameURL,
                            frameOrigin: frame.frameOrigin,
                            mimeType: mimeType
                        )
                    )
                }
            }

            totalBlobVideos += max(reportedBlobCount, frameBlobVideoEntries)
        }

        return (resolvedPageTitle ?? fallbackPageTitle, parsedEntries, totalBlobVideos)
    }

    static func merge(
        tabID: String,
        pageTitle: String?,
        networkEvents: [CuriumMediaResourceEvent],
        domEntries: [CuriumDOMMediaEntry],
        blobVideoCount: Int,
        effectiveUserAgent: String?,
        now: Date = .now
    ) -> CuriumMediaScanSnapshot {
        struct Builder {
            let url: URL
            var kind: CuriumMediaResourceEvent.StreamKind
            var explicitTitle: String?
            var mimeType: String?
            var contentLength: Int64
            var width: Int?
            var height: Int?
            var durationSeconds: Double?
            var referrer: URL?
            var frameOrigin: String?
            var effectiveUserAgent: String?
            var fromDOM: Bool
            var fromNetwork: Bool
            var capturedAt: Date
        }

        let trimmedPageTitle = pageTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let trimmedFallbackUA = effectiveUserAgent?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        var buildersByID: [String: Builder] = [:]

        for event in networkEvents {
            guard CuriumHLSParser.isAllowedHTTPURL(event.url) else { continue }
            let key = event.url.absoluteString
            if var existing = buildersByID[key] {
                existing.fromNetwork = true
                if existing.mimeType == nil { existing.mimeType = event.mimeType }
                if event.contentLength > existing.contentLength {
                    existing.contentLength = event.contentLength
                }
                if existing.referrer == nil { existing.referrer = event.referrer ?? event.frameURL }
                if existing.frameOrigin == nil { existing.frameOrigin = event.frameOrigin }
                if existing.effectiveUserAgent == nil {
                    existing.effectiveUserAgent = event.effectiveUserAgent ?? trimmedFallbackUA
                }
                if event.capturedAt > existing.capturedAt {
                    existing.capturedAt = event.capturedAt
                }
                buildersByID[key] = existing
            } else {
                buildersByID[key] = Builder(
                    url: event.url,
                    kind: event.kind,
                    explicitTitle: nil,
                    mimeType: event.mimeType,
                    contentLength: event.contentLength,
                    width: nil,
                    height: nil,
                    durationSeconds: nil,
                    referrer: event.referrer ?? event.frameURL,
                    frameOrigin: event.frameOrigin,
                    effectiveUserAgent: event.effectiveUserAgent ?? trimmedFallbackUA,
                    fromDOM: false,
                    fromNetwork: true,
                    capturedAt: event.capturedAt
                )
            }
        }

        var blobEntriesCount = 0
        for entry in domEntries {
            if entry.isBlob || entry.url == nil {
                if entry.isBlob && entry.tag != "audio" {
                    blobEntriesCount += 1
                }
                continue
            }
            guard let url = entry.url, CuriumHLSParser.isAllowedHTTPURL(url) else { continue }
            let destination = entry.tag == "audio" ? "audio" : "video"
            guard let kind = CuriumMediaResourceEvent.classify(
                url: url,
                mimeType: entry.mimeType,
                destination: destination
            ) else {
                continue
            }

            let key = url.absoluteString
            let entryTitle = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

            if var existing = buildersByID[key] {
                existing.fromDOM = true
                if existing.explicitTitle == nil, let entryTitle {
                    existing.explicitTitle = entryTitle
                }
                if existing.mimeType == nil, let mime = entry.mimeType {
                    existing.mimeType = mime
                }
                if existing.width == nil, let w = entry.width, w > 0 {
                    existing.width = w
                }
                if existing.height == nil, let h = entry.height, h > 0 {
                    existing.height = h
                }
                if existing.durationSeconds == nil, let d = entry.durationSeconds, d.isFinite, d > 0 {
                    existing.durationSeconds = d
                }
                if existing.referrer == nil, let ref = entry.frameURL {
                    existing.referrer = ref
                }
                if existing.frameOrigin == nil, let origin = entry.frameOrigin {
                    existing.frameOrigin = origin
                }
                buildersByID[key] = existing
            } else {
                buildersByID[key] = Builder(
                    url: url,
                    kind: kind,
                    explicitTitle: entryTitle,
                    mimeType: entry.mimeType,
                    contentLength: -1,
                    width: entry.width,
                    height: entry.height,
                    durationSeconds: entry.durationSeconds,
                    referrer: entry.frameURL,
                    frameOrigin: entry.frameOrigin,
                    effectiveUserAgent: trimmedFallbackUA,
                    fromDOM: true,
                    fromNetwork: false,
                    capturedAt: now
                )
            }
        }

        let sortedBuilders = buildersByID.values.sorted { lhs, rhs in
            let lhsRank = streamKindSortRank(lhs.kind)
            let rhsRank = streamKindSortRank(rhs.kind)
            if lhsRank != rhsRank { return lhsRank < rhsRank }

            if lhs.capturedAt != rhs.capturedAt {
                return lhs.capturedAt > rhs.capturedAt
            }
            if lhs.contentLength != rhs.contentLength {
                return lhs.contentLength > rhs.contentLength
            }
            let lhsPixels = (lhs.width ?? 0) * (lhs.height ?? 0)
            let rhsPixels = (rhs.width ?? 0) * (rhs.height ?? 0)
            if lhsPixels != rhsPixels {
                return lhsPixels > rhsPixels
            }
            return lhs.url.absoluteString < rhs.url.absoluteString
        }

        let candidates: [CuriumMediaCandidate] = sortedBuilders.map { item in
            let host = item.url.host ?? ""
            let resolvedTitle = resolveCandidateTitle(
                explicitTitle: item.explicitTitle,
                pageTitle: trimmedPageTitle,
                url: item.url,
                kind: item.kind,
                host: host
            )
            let resolutionLabel = formatResolution(width: item.width, height: item.height)

            return CuriumMediaCandidate(
                id: item.url.absoluteString,
                url: item.url,
                kind: item.kind,
                title: resolvedTitle,
                host: host,
                mimeType: item.mimeType,
                contentLength: item.contentLength,
                resolutionLabel: resolutionLabel,
                durationSeconds: item.durationSeconds,
                referrer: item.referrer,
                frameOrigin: item.frameOrigin,
                effectiveUserAgent: item.effectiveUserAgent,
                fromDOM: item.fromDOM,
                fromNetwork: item.fromNetwork
            )
        }

        return CuriumMediaScanSnapshot(
            tabID: tabID,
            pageTitle: trimmedPageTitle,
            candidates: candidates,
            detectedBlobVideoCount: max(blobVideoCount, blobEntriesCount),
            scannedAt: now
        )
    }

    private static func streamKindSortRank(_ kind: CuriumMediaResourceEvent.StreamKind) -> Int {
        switch kind {
        case .hls: return 0
        case .video: return 1
        case .audio: return 2
        case .dash: return 3
        }
    }

    private static func formatResolution(width: Int?, height: Int?) -> String? {
        guard let height, height > 0 else { return nil }
        let standardHeights: Set<Int> = [4320, 2160, 1440, 1080, 720, 540, 480, 360, 240, 144]
        if standardHeights.contains(height) {
            return "\(height)p"
        }
        if let width, width > 0 {
            return "\(width)×\(height)"
        }
        return "\(height)p"
    }

    private static func resolveCandidateTitle(
        explicitTitle: String?,
        pageTitle: String?,
        url: URL,
        kind: CuriumMediaResourceEvent.StreamKind,
        host: String
    ) -> String {
        if let explicitTitle, !explicitTitle.isEmpty {
            return explicitTitle
        }

        let rawLast = url.lastPathComponent
        let stem = (rawLast as NSString).deletingPathExtension
            .removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let isMeaningfulStem = !stem.isEmpty
            && stem != "/"
            && !genericStemNames.contains(stem.lowercased())
            && !isOpaqueHashStem(stem)

        if let pageTitle, !pageTitle.isEmpty {
            if kind == .hls || kind == .dash || !isMeaningfulStem {
                return pageTitle
            }
        }

        if isMeaningfulStem {
            return stem
        }
        if let pageTitle, !pageTitle.isEmpty {
            return pageTitle
        }
        if !stem.isEmpty && stem != "/" {
            return stem
        }
        return host.isEmpty ? "Media" : host
    }

    private static func isOpaqueHashStem(_ stem: String) -> Bool {
        guard stem.count >= 16 else { return false }
        return stem.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (v >= 48 && v <= 57)
                || (v >= 65 && v <= 70)
                || (v >= 97 && v <= 102)
                || scalar == "-"
                || scalar == "_"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
