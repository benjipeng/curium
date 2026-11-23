import CommonCrypto
import Darwin
import Foundation

/// Errors thrown while validating, parsing, or decrypting RFC 8216 HLS playlists and segments.
enum CuriumHLSParserError: LocalizedError, Equatable, Sendable {
    case playlistTooLarge(bytes: Int)
    case invalidPlaylist(String)
    case tooManySegments(Int)
    case disallowedURLScheme(String)
    case blockedPrivateNetworkHost(String)
    case invalidKeyLength(Int)
    case invalidIVLength(Int)
    case decryptionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .playlistTooLarge(let bytes):
            return "HLS playlist exceeds the 4 MiB safety limit (\(bytes) bytes)."
        case .invalidPlaylist(let reason):
            return "Invalid HLS playlist: \(reason)"
        case .tooManySegments(let count):
            return "HLS playlist exceeds the \(CuriumHLSParser.maxSegments)-segment limit (\(count) segments)."
        case .disallowedURLScheme(let detail):
            return "Disallowed URL scheme in HLS playlist: \(detail)"
        case .blockedPrivateNetworkHost(let host):
            return "Blocked private or local network host in HLS playlist: \(host)"
        case .invalidKeyLength(let length):
            return "Invalid AES-128 key length (\(length) bytes; expected 16)."
        case .invalidIVLength(let length):
            return "Invalid AES-128 IV length (\(length) bytes; expected 16)."
        case .decryptionFailed(let status):
            return "AES-128-CBC segment decryption failed (CCCrypt status \(status))."
        }
    }
}

enum CuriumHLSEncryptionKind: Equatable, Sendable {
    case none
    case aes128(keyURL: URL, iv: Data?)
    case unsupportedDRM(method: String)
}

struct CuriumHLSVariant: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let bandwidth: Int?
    let averageBandwidth: Int?
    let width: Int?
    let height: Int?
    let codecs: String?
    let frameRate: Double?
    let audioGroupID: String?
    let audioURI: URL?

    var resolutionLabel: String? {
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

    var bitrateLabel: String? {
        guard let bps = (averageBandwidth ?? bandwidth), bps > 0 else { return nil }
        if bps >= 1_000_000 {
            let mbps = Double(bps) / 1_000_000.0
            return String(format: "%.1f Mbps", mbps)
        }
        let kbps = max(1, Int((Double(bps) / 1_000.0).rounded()))
        return "\(kbps) kbps"
    }

    var displayTitle: String {
        switch (resolutionLabel, bitrateLabel) {
        case let (resolution?, bitrate?):
            return "\(resolution) · \(bitrate)"
        case let (resolution?, nil):
            return resolution
        case let (nil, bitrate?):
            return bitrate
        case (nil, nil):
            return "Variant"
        }
    }
}

struct CuriumHLSSegment: Equatable, Sendable {
    let index: Int
    let mediaSequence: Int
    let url: URL
    let duration: Double
    let byteRange: (length: Int, offset: Int?)?
    let encryption: CuriumHLSEncryptionKind
    let mapURL: URL?
    let mapByteRange: (length: Int, offset: Int?)?
    let mapEncryption: CuriumHLSEncryptionKind

    init(
        index: Int,
        mediaSequence: Int,
        url: URL,
        duration: Double,
        byteRange: (length: Int, offset: Int?)?,
        encryption: CuriumHLSEncryptionKind,
        mapURL: URL?,
        mapByteRange: (length: Int, offset: Int?)?,
        mapEncryption: CuriumHLSEncryptionKind = .none
    ) {
        self.index = index
        self.mediaSequence = mediaSequence
        self.url = url
        self.duration = duration
        self.byteRange = byteRange
        self.encryption = encryption
        self.mapURL = mapURL
        self.mapByteRange = mapByteRange
        self.mapEncryption = mapEncryption
    }

    static func == (lhs: CuriumHLSSegment, rhs: CuriumHLSSegment) -> Bool {
        lhs.index == rhs.index
            && lhs.mediaSequence == rhs.mediaSequence
            && lhs.url == rhs.url
            && lhs.duration == rhs.duration
            && lhs.byteRange?.length == rhs.byteRange?.length
            && lhs.byteRange?.offset == rhs.byteRange?.offset
            && lhs.encryption == rhs.encryption
            && lhs.mapURL == rhs.mapURL
            && lhs.mapByteRange?.length == rhs.mapByteRange?.length
            && lhs.mapByteRange?.offset == rhs.mapByteRange?.offset
            && lhs.mapEncryption == rhs.mapEncryption
    }
}

struct CuriumHLSMediaPlaylist: Equatable, Sendable {
    let sourceURL: URL
    let mediaSequence: Int
    let targetDuration: Double?
    let isEndList: Bool
    let playlistType: String?
    let isFMP4: Bool
    let segments: [CuriumHLSSegment]
    let encryptionSummary: CuriumHLSEncryptionKind

    var totalDurationSeconds: Double {
        segments.reduce(0) { partial, segment in
            guard segment.duration.isFinite, segment.duration > 0 else { return partial }
            return partial + segment.duration
        }
    }

    var isLiveStream: Bool {
        !isEndList && playlistType?.uppercased() != "VOD"
    }
}

struct CuriumHLSMasterInspection: Equatable, Sendable {
    let sourceURL: URL
    let isMasterPlaylist: Bool
    let variants: [CuriumHLSVariant]
    let directSegmentCount: Int
    let estimatedDurationSeconds: Double?
    let isLiveStream: Bool
    let isFMP4: Bool
    let encryption: CuriumHLSEncryptionKind
    /// All child variant and `#EXT-X-MEDIA` rendition playlist URLs referenced by a master playlist,
    /// allowing Media Radar UI to collapse redundant child `.m3u8` rows once the master is inspected.
    let referencedPlaylistURLs: Set<URL>

    init(
        sourceURL: URL,
        isMasterPlaylist: Bool,
        variants: [CuriumHLSVariant],
        directSegmentCount: Int,
        estimatedDurationSeconds: Double?,
        isLiveStream: Bool,
        isFMP4: Bool,
        encryption: CuriumHLSEncryptionKind,
        referencedPlaylistURLs: Set<URL> = []
    ) {
        self.sourceURL = sourceURL
        self.isMasterPlaylist = isMasterPlaylist
        self.variants = variants
        self.directSegmentCount = directSegmentCount
        self.estimatedDurationSeconds = estimatedDurationSeconds
        self.isLiveStream = isLiveStream
        self.isFMP4 = isFMP4
        self.encryption = encryption
        self.referencedPlaylistURLs = referencedPlaylistURLs
    }

    var isDownloadable: Bool {
        if case .unsupportedDRM = encryption {
            return false
        }
        if isLiveStream {
            return false
        }
        if isMasterPlaylist {
            return !variants.isEmpty
        }
        return directSegmentCount > 0
    }

    var unavailableReason: String? {
        if case .unsupportedDRM(let method) = encryption {
            return "DRM-protected stream (\(method)) cannot be downloaded."
        }
        if isLiveStream {
            return "Live streams cannot be downloaded while broadcasting."
        }
        if isMasterPlaylist && variants.isEmpty {
            return "No downloadable stream variants were found."
        }
        if !isMasterPlaylist && directSegmentCount == 0 {
            return "No media segments were found in this playlist."
        }
        return nil
    }
}

enum CuriumHLSParser {
    static let maxPlaylistBytes = 4 * 1024 * 1024
    static let maxSegments = 5_000

    private static let fmp4Extensions: Set<String> = ["m4s", "mp4", "m4v", "m4a", "cmfv", "cmfa"]

    /// Strictly permits only `http` or `https` URLs with a non-empty host.
    /// Rejects `file://`, `data:`, `javascript:`, `ftp:`, and hostless URLs.
    static func isAllowedHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            return false
        }
        return true
    }

    /// Returns `true` when `rawHost` is a literal loopback, link-local, RFC 1918, CGNAT,
    /// IPv6 ULA/multicast/unspecified, IPv4-mapped private IPv6, or `.localhost`/`.local` host.
    static func isPrivateOrLocalHost(_ rawHost: String) -> Bool {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("[") && host.hasSuffix("]"), host.count >= 2 {
            host = String(host.dropFirst().dropLast())
        }
        if let pct = host.firstIndex(of: "%") {
            host = String(host[..<pct])
        }
        host = host.lowercased()
        while host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty else { return true }

        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }

        // Standard dotted-quad IPv4.
        var addr4 = in_addr()
        if inet_pton(AF_INET, host, &addr4) == 1 {
            return isPrivateIPv4HostOrder(UInt32(bigEndian: addr4.s_addr))
        }

        // Legacy/non-canonical IPv4 forms accepted by BSD resolvers (e.g. `127.1`, `0x7f000001`, `2130706433`, `0177.0.0.1`).
        var atonAddr = in_addr()
        if inet_aton(host, &atonAddr) != 0 {
            return isPrivateIPv4HostOrder(UInt32(bigEndian: atonAddr.s_addr))
        }

        // IPv6 literals (including IPv4-mapped `::ffff:127.0.0.1`, ULA `fc00::/7`, link-local `fe80::/10`, loopback `::1`).
        var addr6 = in6_addr()
        if inet_pton(AF_INET6, host, &addr6) == 1 {
            let bytes = withUnsafeBytes(of: addr6) { Array($0) }
            guard bytes.count == 16 else { return true }
            if bytes.allSatisfy({ $0 == 0 }) {
                return true // ::
            }
            if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 {
                return true // ::1
            }
            if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 {
                return true // fe80::/10 link-local
            }
            if (bytes[0] & 0xFE) == 0xFC {
                return true // fc00::/7 ULA
            }
            if bytes[0] == 0xFF {
                return true // ff00::/8 multicast
            }
            if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
                let ipv4 = (UInt32(bytes[12]) << 24) | (UInt32(bytes[13]) << 16)
                    | (UInt32(bytes[14]) << 8) | UInt32(bytes[15])
                return isPrivateIPv4HostOrder(ipv4)
            }
            if bytes[0..<12].allSatisfy({ $0 == 0 }) {
                let ipv4 = (UInt32(bytes[12]) << 24) | (UInt32(bytes[13]) << 16)
                    | (UInt32(bytes[14]) << 8) | UInt32(bytes[15])
                return isPrivateIPv4HostOrder(ipv4)
            }
            if bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xFF && bytes[3] == 0x9B
                && bytes[4..<12].allSatisfy({ $0 == 0 }) {
                let ipv4 = (UInt32(bytes[12]) << 24) | (UInt32(bytes[13]) << 16)
                    | (UInt32(bytes[14]) << 8) | UInt32(bytes[15])
                return isPrivateIPv4HostOrder(ipv4)
            }
            return false
        }

        return false
    }

    static func isPrivateOrLocalURL(_ url: URL) -> Bool {
        guard let host = url.host, !host.isEmpty else { return true }
        return isPrivateOrLocalHost(host)
    }

    /// Blocks public-to-private SSRF transitions while preserving private/loopback -> private/loopback
    /// (e.g. local test servers or LAN pages referencing LAN streams).
    static func isAllowedTargetURL(_ targetURL: URL, originatingURL: URL?) -> Bool {
        guard isAllowedHTTPURL(targetURL) else { return false }
        guard let originatingURL, isAllowedHTTPURL(originatingURL) else { return true }
        if !isPrivateOrLocalURL(originatingURL) && isPrivateOrLocalURL(targetURL) {
            return false
        }
        return true
    }

    private static func isPrivateIPv4HostOrder(_ ip: UInt32) -> Bool {
        let a = (ip >> 24) & 0xFF
        let b = (ip >> 16) & 0xFF
        if a == 0 || a == 10 || a == 127 { return true }
        if a == 169 && b == 254 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 192 && b == 168 { return true }
        if a == 100 && (64...127).contains(b) { return true }
        if a >= 224 { return true }
        return false
    }

    static func parseMasterOrMedia(text: String, baseURL: URL) throws -> CuriumHLSMasterInspection {
        let lines = try validatedPlaylistLines(text: text, baseURL: baseURL)

        let hasStreamInf = lines.contains { $0.hasPrefix("#EXT-X-STREAM-INF:") }
        let hasExtInf = lines.contains { $0.hasPrefix("#EXTINF:") }
        let hasIFrameInf = lines.contains { $0.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") }

        if hasStreamInf || (hasIFrameInf && !hasExtInf) {
            return try parseMasterPlaylist(lines: lines, baseURL: baseURL)
        }

        let media = try parseMediaPlaylist(lines: lines, baseURL: baseURL)
        return CuriumHLSMasterInspection(
            sourceURL: media.sourceURL,
            isMasterPlaylist: false,
            variants: [],
            directSegmentCount: media.segments.count,
            estimatedDurationSeconds: media.segments.isEmpty ? nil : media.totalDurationSeconds,
            isLiveStream: media.isLiveStream,
            isFMP4: media.isFMP4,
            encryption: media.encryptionSummary
        )
    }

    static func parseMediaPlaylist(text: String, baseURL: URL) throws -> CuriumHLSMediaPlaylist {
        let lines = try validatedPlaylistLines(text: text, baseURL: baseURL)
        return try parseMediaPlaylist(lines: lines, baseURL: baseURL)
    }

    /// Resolves the 16-byte AES-128-CBC initialization vector per RFC 8216 §5.2:
    /// uses `explicitIV` when present and 16 bytes, otherwise encodes `mediaSequence`
    /// as a big-endian 128-bit unsigned integer.
    static func resolveIV(explicitIV: Data?, mediaSequence: Int) -> Data {
        if let explicitIV, explicitIV.count == kCCBlockSizeAES128 {
            return explicitIV
        }
        var bytes = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        let sequence = UInt64(max(0, mediaSequence)).bigEndian
        withUnsafeBytes(of: sequence) { raw in
            for idx in 0..<8 {
                bytes[8 + idx] = raw[idx]
            }
        }
        return Data(bytes)
    }

    /// Decrypts AES-128-CBC PKCS#7-padded segment bytes using CommonCrypto.
    static func decryptAES128CBC(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128 else {
            throw CuriumHLSParserError.invalidKeyLength(key.count)
        }
        guard iv.count == kCCBlockSizeAES128 else {
            throw CuriumHLSParserError.invalidIVLength(iv.count)
        }
        guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else {
            throw CuriumHLSParserError.decryptionFailed(Int32(kCCAlignmentError))
        }

        let outCapacity = ciphertext.count + kCCBlockSizeAES128
        var outData = Data(count: outCapacity)
        var outLength = 0

        let status: CCCryptorStatus = outData.withUnsafeMutableBytes { outBuf in
            ciphertext.withUnsafeBytes { dataBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress,
                            kCCKeySizeAES128,
                            ivBuf.baseAddress,
                            dataBuf.baseAddress,
                            ciphertext.count,
                            outBuf.baseAddress,
                            outCapacity,
                            &outLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw CuriumHLSParserError.decryptionFailed(status)
        }
        outData.count = outLength
        return outData
    }

    // MARK: - Master Playlist Parsing

    private struct AudioRenditionCandidate {
        let uri: URL?
        let isDefault: Bool
        let isAutoSelect: Bool
    }

    private static func parseMasterPlaylist(
        lines: [String],
        baseURL: URL
    ) throws -> CuriumHLSMasterInspection {
        var audioGroups: [String: AudioRenditionCandidate] = [:]
        var referencedPlaylistURLs: Set<URL> = []
        var masterEncryption: CuriumHLSEncryptionKind = .none

        // Pass 1: Collect #EXT-X-MEDIA renditions and #EXT-X-SESSION-KEY declarations
        // (tags may appear before or after #EXT-X-STREAM-INF in RFC 8216).
        // Record URI-less TYPE=AUDIO renditions too so a muxed DEFAULT=YES primary track
        // is never overwritten by a non-default commentary/foreign URI rendition.
        for line in lines {
            if line.hasPrefix("#EXT-X-MEDIA:") {
                let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                let resolvedURI: URL?
                if let rawURI = attrs["URI"], !rawURI.isEmpty {
                    let url = try resolveAllowedURL(rawURI, relativeTo: baseURL)
                    referencedPlaylistURLs.insert(url)
                    resolvedURI = url
                } else {
                    resolvedURI = nil
                }
                if attrs["TYPE"]?.uppercased() == "AUDIO",
                   let groupID = attrs["GROUP-ID"], !groupID.isEmpty {
                    let isDefault = attrs["DEFAULT"]?.uppercased() == "YES"
                    let isAutoSelect = attrs["AUTOSELECT"]?.uppercased() == "YES"
                    let candidate = AudioRenditionCandidate(
                        uri: resolvedURI,
                        isDefault: isDefault,
                        isAutoSelect: isAutoSelect
                    )
                    if let existing = audioGroups[groupID] {
                        let replaces = (!existing.isDefault && candidate.isDefault)
                            || (!existing.isDefault && !existing.isAutoSelect && candidate.isAutoSelect)
                        if replaces {
                            audioGroups[groupID] = candidate
                        }
                    } else {
                        audioGroups[groupID] = candidate
                    }
                }
            } else if line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") {
                let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-I-FRAME-STREAM-INF:".count)))
                if let rawURI = attrs["URI"], !rawURI.isEmpty {
                    let resolvedURI = try resolveAllowedURL(rawURI, relativeTo: baseURL)
                    referencedPlaylistURLs.insert(resolvedURI)
                }
            } else if line.hasPrefix("#EXT-X-SESSION-KEY:") {
                let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-SESSION-KEY:".count)))
                let parsedKey = try parseEncryption(attrs: attrs, baseURL: baseURL)
                masterEncryption = mergeEncryptionSummary(existing: masterEncryption, incoming: parsedKey)
            }
        }

        // Pass 2: Parse #EXT-X-STREAM-INF variant streams.
        var variantsByID: [String: CuriumHLSVariant] = [:]
        var orderedIDs: [String] = []
        var pendingStreamAttrs: [String: String]?

        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingStreamAttrs = parseAttributeList(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                continue
            }
            if line.hasPrefix("#") || line.isEmpty {
                continue
            }
            guard let attrs = pendingStreamAttrs else { continue }
            pendingStreamAttrs = nil

            let resolvedURL = try resolveAllowedURL(line, relativeTo: baseURL)
            referencedPlaylistURLs.insert(resolvedURL)
            let bandwidth = attrs["BANDWIDTH"].flatMap(Int.init)
            let averageBandwidth = attrs["AVERAGE-BANDWIDTH"].flatMap(Int.init)
            let (width, height) = parseResolution(attrs["RESOLUTION"])
            let codecs = attrs["CODECS"].flatMap { $0.isEmpty ? nil : $0 }
            let frameRate = attrs["FRAME-RATE"].flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let audioGroupID = attrs["AUDIO"].flatMap { $0.isEmpty ? nil : $0 }
            let audioURI: URL? = audioGroupID.flatMap { audioGroups[$0]?.uri }

            let variant = CuriumHLSVariant(
                id: resolvedURL.absoluteString,
                url: resolvedURL,
                bandwidth: bandwidth,
                averageBandwidth: averageBandwidth,
                width: width,
                height: height,
                codecs: codecs,
                frameRate: frameRate,
                audioGroupID: audioGroupID,
                audioURI: audioURI
            )

            if variantsByID[variant.id] == nil {
                orderedIDs.append(variant.id)
                variantsByID[variant.id] = variant
            } else if let existing = variantsByID[variant.id] {
                // When a master playlist lists multiple audio-codec groups for the exact same
                // video playlist URL (e.g. AAC stereo vs Dolby AC-3 / EC-3), prefer universally
                // playable AAC (`mp4a`) first, breaking ties by higher bandwidth.
                let newCodecRank = audioCodecCompatibilityRank(variant.codecs)
                let oldCodecRank = audioCodecCompatibilityRank(existing.codecs)
                if newCodecRank > oldCodecRank
                    || (newCodecRank == oldCodecRank && (variant.bandwidth ?? 0) > (existing.bandwidth ?? 0))
                {
                    variantsByID[variant.id] = variant
                }
            }
        }

        var variants = orderedIDs.compactMap { variantsByID[$0] }
        variants.sort { lhs, rhs in
            let lhsPixels = Int64(lhs.width ?? 0) * Int64(lhs.height ?? 0)
            let rhsPixels = Int64(rhs.width ?? 0) * Int64(rhs.height ?? 0)
            if lhsPixels != rhsPixels { return lhsPixels > rhsPixels }

            let lhsHeight = lhs.height ?? 0
            let rhsHeight = rhs.height ?? 0
            if lhsHeight != rhsHeight { return lhsHeight > rhsHeight }

            let lhsBandwidth = lhs.bandwidth ?? lhs.averageBandwidth ?? 0
            let rhsBandwidth = rhs.bandwidth ?? rhs.averageBandwidth ?? 0
            if lhsBandwidth != rhsBandwidth { return lhsBandwidth > rhsBandwidth }

            return lhs.id < rhs.id
        }

        return CuriumHLSMasterInspection(
            sourceURL: baseURL,
            isMasterPlaylist: true,
            variants: variants,
            directSegmentCount: 0,
            estimatedDurationSeconds: nil,
            isLiveStream: false,
            isFMP4: false,
            encryption: masterEncryption,
            referencedPlaylistURLs: referencedPlaylistURLs
        )
    }

    private static func audioCodecCompatibilityRank(_ codecs: String?) -> Int {
        guard let lowered = codecs?.lowercased(), !lowered.isEmpty else { return 0 }
        let tokens = lowered
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if tokens.contains(where: { $0.hasPrefix("mp4a") }) {
            return 2
        }
        if tokens.contains(where: { $0.hasPrefix("ac-3") || $0.hasPrefix("ec-3") }) {
            return 1
        }
        return 0
    }

    // MARK: - Media Playlist Parsing

    private static func parseMediaPlaylist(
        lines: [String],
        baseURL: URL
    ) throws -> CuriumHLSMediaPlaylist {
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) {
            throw CuriumHLSParserError.invalidPlaylist("Expected a media playlist, but received a master playlist.")
        }

        var mediaSequence = 0
        var targetDuration: Double?
        var isEndList = false
        var playlistType: String?
        var hasMapTag = false
        var hasFMP4SegmentExtension = false

        var currentEncryption: CuriumHLSEncryptionKind = .none
        var encryptionSummary: CuriumHLSEncryptionKind = .none
        var currentMapURL: URL?
        var currentMapByteRange: (length: Int, offset: Int?)?
        var currentMapEncryption: CuriumHLSEncryptionKind = .none

        var pendingDuration: Double?
        var pendingByteRange: (length: Int, offset: Int?)?
        var lastByteRangeURL: URL?
        var lastByteRangeEnd: Int?

        var segments: [CuriumHLSSegment] = []

        for line in lines {
            if line.isEmpty {
                continue
            }

            if line.hasPrefix("#") {
                if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                    let raw = line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)
                        .trimmingCharacters(in: .whitespaces)
                    if let parsed = Int(raw), parsed >= 0 {
                        mediaSequence = parsed
                    }
                } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                    let raw = line.dropFirst("#EXT-X-TARGETDURATION:".count)
                        .trimmingCharacters(in: .whitespaces)
                    if let parsed = Double(raw), parsed.isFinite, parsed >= 0 {
                        targetDuration = parsed
                    }
                } else if line == "#EXT-X-ENDLIST" {
                    isEndList = true
                } else if line.hasPrefix("#EXT-X-PLAYLIST-TYPE:") {
                    let raw = line.dropFirst("#EXT-X-PLAYLIST-TYPE:".count)
                        .trimmingCharacters(in: .whitespaces)
                    if !raw.isEmpty {
                        playlistType = raw.uppercased()
                    }
                } else if line.hasPrefix("#EXT-X-KEY:") {
                    let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-KEY:".count)))
                    currentEncryption = try parseEncryption(attrs: attrs, baseURL: baseURL)
                    encryptionSummary = mergeEncryptionSummary(existing: encryptionSummary, incoming: currentEncryption)
                } else if line.hasPrefix("#EXT-X-MAP:") {
                    let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-MAP:".count)))
                    guard let rawURI = attrs["URI"], !rawURI.isEmpty else {
                        throw CuriumHLSParserError.invalidPlaylist("#EXT-X-MAP tag is missing URI.")
                    }
                    currentMapURL = try resolveAllowedURL(rawURI, relativeTo: baseURL)
                    if let rawRange = attrs["BYTERANGE"] {
                        currentMapByteRange = try parseByteRange(rawRange)
                    } else {
                        currentMapByteRange = nil
                    }
                    // RFC 8216 §4.3.2.5: any #EXT-X-KEY in effect at #EXT-X-MAP encrypts the init section.
                    currentMapEncryption = currentEncryption
                    hasMapTag = true
                } else if line.hasPrefix("#EXTINF:") {
                    let payload = line.dropFirst("#EXTINF:".count)
                    let durationPart = payload.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                    let trimmed = durationPart.trimmingCharacters(in: .whitespaces)
                    guard let duration = Double(trimmed), duration.isFinite, duration >= 0 else {
                        throw CuriumHLSParserError.invalidPlaylist("Malformed #EXTINF duration: \(line)")
                    }
                    pendingDuration = duration
                } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                    let raw = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
                    pendingByteRange = try parseByteRange(raw)
                }
                continue
            }

            guard let duration = pendingDuration else {
                continue
            }
            pendingDuration = nil

            let nextCount = segments.count + 1
            guard nextCount <= maxSegments else {
                throw CuriumHLSParserError.tooManySegments(nextCount)
            }

            let segmentURL = try resolveAllowedURL(line, relativeTo: baseURL)
            if fmp4Extensions.contains(segmentURL.pathExtension.lowercased()) {
                hasFMP4SegmentExtension = true
            }

            let resolvedByteRange: (length: Int, offset: Int?)?
            if let rawRange = pendingByteRange {
                if let explicitOffset = rawRange.offset {
                    let (nextEnd, overflow) = explicitOffset.addingReportingOverflow(rawRange.length)
                    guard !overflow else {
                        throw CuriumHLSParserError.invalidPlaylist("BYTERANGE offset + length overflow.")
                    }
                    resolvedByteRange = (length: rawRange.length, offset: explicitOffset)
                    lastByteRangeURL = segmentURL
                    lastByteRangeEnd = nextEnd
                } else if lastByteRangeURL == segmentURL, let previousEnd = lastByteRangeEnd {
                    let (nextEnd, overflow) = previousEnd.addingReportingOverflow(rawRange.length)
                    guard !overflow else {
                        throw CuriumHLSParserError.invalidPlaylist("Chained BYTERANGE offset + length overflow.")
                    }
                    resolvedByteRange = (length: rawRange.length, offset: previousEnd)
                    lastByteRangeEnd = nextEnd
                } else {
                    resolvedByteRange = (length: rawRange.length, offset: nil)
                    lastByteRangeURL = segmentURL
                    lastByteRangeEnd = rawRange.length
                }
            } else {
                resolvedByteRange = nil
                lastByteRangeURL = nil
                lastByteRangeEnd = nil
            }
            pendingByteRange = nil

            let index = segments.count
            let (segmentSequence, seqOverflow) = mediaSequence.addingReportingOverflow(index)
            guard !seqOverflow else {
                throw CuriumHLSParserError.invalidPlaylist("MEDIA-SEQUENCE overflow.")
            }
            let segment = CuriumHLSSegment(
                index: index,
                mediaSequence: segmentSequence,
                url: segmentURL,
                duration: duration,
                byteRange: resolvedByteRange,
                encryption: currentEncryption,
                mapURL: currentMapURL,
                mapByteRange: currentMapByteRange,
                mapEncryption: currentMapURL != nil ? currentMapEncryption : .none
            )
            encryptionSummary = mergeEncryptionSummary(existing: encryptionSummary, incoming: currentEncryption)
            segments.append(segment)
        }

        return CuriumHLSMediaPlaylist(
            sourceURL: baseURL,
            mediaSequence: mediaSequence,
            targetDuration: targetDuration,
            isEndList: isEndList,
            playlistType: playlistType,
            isFMP4: hasMapTag || hasFMP4SegmentExtension,
            segments: segments,
            encryptionSummary: encryptionSummary
        )
    }

    // MARK: - Helpers

    private static func validatedPlaylistLines(text: String, baseURL: URL) throws -> [String] {
        guard isAllowedHTTPURL(baseURL) else {
            throw CuriumHLSParserError.disallowedURLScheme(baseURL.scheme ?? "unknown")
        }
        let byteCount = text.utf8.count
        guard byteCount <= maxPlaylistBytes else {
            throw CuriumHLSParserError.playlistTooLarge(bytes: byteCount)
        }

        var normalized = text
        if normalized.hasPrefix("\u{FEFF}") {
            normalized.removeFirst()
        }
        normalized = normalized
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard let firstNonEmpty = lines.first(where: { !$0.isEmpty }),
              firstNonEmpty == "#EXTM3U" else {
            throw CuriumHLSParserError.invalidPlaylist("Missing #EXTM3U header.")
        }
        return lines
    }

    private static func resolveAllowedURL(_ rawURI: String, relativeTo baseURL: URL) throws -> URL {
        let trimmed = rawURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL else {
            throw CuriumHLSParserError.invalidPlaylist("Malformed URI reference.")
        }
        guard isAllowedHTTPURL(resolved) else {
            throw CuriumHLSParserError.disallowedURLScheme(resolved.scheme ?? "unknown")
        }
        guard isAllowedTargetURL(resolved, originatingURL: baseURL) else {
            throw CuriumHLSParserError.blockedPrivateNetworkHost(resolved.host ?? "private")
        }
        return resolved
    }

    private static func parseEncryption(
        attrs: [String: String],
        baseURL: URL
    ) throws -> CuriumHLSEncryptionKind {
        guard let methodRaw = attrs["METHOD"]?.uppercased(), !methodRaw.isEmpty else {
            throw CuriumHLSParserError.invalidPlaylist("#EXT-X-KEY missing METHOD attribute.")
        }
        switch methodRaw {
        case "NONE":
            return .none
        case "AES-128":
            guard let rawURI = attrs["URI"], !rawURI.isEmpty else {
                throw CuriumHLSParserError.invalidPlaylist("AES-128 #EXT-X-KEY missing URI attribute.")
            }
            let keyURL = try resolveAllowedURL(rawURI, relativeTo: baseURL)
            let iv: Data?
            if let rawIV = attrs["IV"], !rawIV.isEmpty {
                iv = try parseHexIV(rawIV)
            } else {
                iv = nil
            }
            return .aes128(keyURL: keyURL, iv: iv)
        default:
            // Preserve DRM methods (e.g. SAMPLE-AES, SAMPLE-AES-CTR, FairPlay skd://)
            // without rejecting their non-HTTP DRM key URIs so UI can surface an honest reason.
            return .unsupportedDRM(method: methodRaw)
        }
    }

    private static func mergeEncryptionSummary(
        existing: CuriumHLSEncryptionKind,
        incoming: CuriumHLSEncryptionKind
    ) -> CuriumHLSEncryptionKind {
        switch (existing, incoming) {
        case (.unsupportedDRM, _):
            return existing
        case (_, .unsupportedDRM):
            return incoming
        case (.aes128, _):
            return existing
        case (.none, .aes128):
            return incoming
        case (.none, .none):
            return .none
        }
    }

    private static func parseHexIV(_ raw: String) throws -> Data {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") else {
            throw CuriumHLSParserError.invalidPlaylist("Malformed AES-128 IV (expected 0x prefix).")
        }
        let hexBody = String(trimmed.dropFirst(2))
        guard !hexBody.isEmpty, hexBody.count <= 32 else {
            throw CuriumHLSParserError.invalidPlaylist("AES-128 IV must be 1–32 hex characters.")
        }
        let padded = String(repeating: "0", count: 32 - hexBody.count) + hexBody
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)

        var idx = padded.startIndex
        while idx < padded.endIndex {
            let nextIdx = padded.index(idx, offsetBy: 2)
            guard let value = UInt8(padded[idx..<nextIdx], radix: 16) else {
                throw CuriumHLSParserError.invalidPlaylist("AES-128 IV contains non-hex characters.")
            }
            bytes.append(value)
            idx = nextIdx
        }
        return Data(bytes)
    }

    private static let maxSupportedResolutionDimension = 65_536

    private static func parseByteRange(_ raw: String) throws -> (length: Int, offset: Int?) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard let lengthStr = parts.first,
              let length = Int(lengthStr),
              length > 0 else {
            throw CuriumHLSParserError.invalidPlaylist("Malformed BYTERANGE length: \(trimmed)")
        }
        if parts.count == 2 {
            guard let offset = Int(parts[1]), offset >= 0 else {
                throw CuriumHLSParserError.invalidPlaylist("Malformed BYTERANGE offset: \(trimmed)")
            }
            guard !offset.addingReportingOverflow(length).overflow else {
                throw CuriumHLSParserError.invalidPlaylist("BYTERANGE offset + length overflow: \(trimmed)")
            }
            return (length: length, offset: offset)
        }
        return (length: length, offset: nil)
    }

    private static func parseResolution(_ raw: String?) -> (width: Int?, height: Int?) {
        guard let raw else { return (nil, nil) }
        let parts = raw.lowercased().split(separator: "x", maxSplits: 1)
        guard parts.count == 2,
              let width = Int(parts[0]), (1...maxSupportedResolutionDimension).contains(width),
              let height = Int(parts[1]), (1...maxSupportedResolutionDimension).contains(height) else {
            return (nil, nil)
        }
        return (width, height)
    }

    /// Parses an RFC 8216 §4.2 attribute list (`KEY=VALUE,...`) while preserving commas
    /// inside double-quoted strings (such as `CODECS="avc1.640028,mp4a.40.2"`).
    private static func parseAttributeList(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        var idx = raw.startIndex
        let end = raw.endIndex

        while idx < end {
            while idx < end && (raw[idx] == "," || raw[idx] == " " || raw[idx] == "\t") {
                idx = raw.index(after: idx)
            }
            guard idx < end else { break }

            let keyStart = idx
            while idx < end && raw[idx] != "=" && raw[idx] != "," {
                idx = raw.index(after: idx)
            }
            let key = raw[keyStart..<idx].trimmingCharacters(in: .whitespaces).uppercased()
            guard idx < end, raw[idx] == "=" else {
                while idx < end && raw[idx] != "," {
                    idx = raw.index(after: idx)
                }
                continue
            }
            idx = raw.index(after: idx) // skip '='

            let value: String
            if idx < end && raw[idx] == "\"" {
                idx = raw.index(after: idx) // skip opening quote
                let valStart = idx
                while idx < end && raw[idx] != "\"" {
                    idx = raw.index(after: idx)
                }
                value = String(raw[valStart..<idx])
                if idx < end && raw[idx] == "\"" {
                    idx = raw.index(after: idx)
                }
                while idx < end && raw[idx] != "," {
                    idx = raw.index(after: idx)
                }
            } else {
                let valStart = idx
                while idx < end && raw[idx] != "," {
                    idx = raw.index(after: idx)
                }
                value = raw[valStart..<idx].trimmingCharacters(in: .whitespaces)
            }

            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }
}
