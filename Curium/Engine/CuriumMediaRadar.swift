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
