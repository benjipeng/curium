import AudioToolbox
import AVFoundation
import CommonCrypto
import CoreMedia
import CoreVideo
import Foundation
import Network
import Testing

@Suite("HLS Engine & Native MP4 Remux")
struct CuriumHLSRemuxTests {

    // MARK: - 1. Fake-PNG Stripping, Discontinuity Ad-Pod Filtering & AIMD Concurrency Gate

    @Test("sanitizeMPEGTSPayload strips fake PNG and JPEG headers while leaving clean TS untouched")
    func sanitizeMPEGTSPayloadStripsDisguisedImageHeaders() {
        var cleanTS = Data()
        for packetIdx in 0..<4 {
            var pkt = Data(repeating: UInt8(packetIdx + 1), count: 188)
            pkt[0] = 0x47
            cleanTS.append(pkt)
        }

        // Fast O(1) path on clean MPEG-TS
        #expect(CuriumHLSTransferEngine.sanitizeMPEGTSPayload(cleanTS) == cleanTS)

        // Fake 72-byte PNG header prepended before 4 genuine 188-byte 0x47 TS packets
        var poisonedPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        poisonedPNG.append(Data(repeating: 0xAA, count: 64))
        poisonedPNG.append(cleanTS)

        let sanitizedPNG = CuriumHLSTransferEngine.sanitizeMPEGTSPayload(poisonedPNG)
        #expect(sanitizedPNG.count == cleanTS.count)
        #expect(sanitizedPNG == cleanTS)

        // Larger fake 4 KiB JPEG header prepended before TS packets
        var poisonedJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0])
        poisonedJPEG.append(Data(repeating: 0x55, count: 4_092))
        poisonedJPEG.append(cleanTS)

        let sanitizedJPEG = CuriumHLSTransferEngine.sanitizeMPEGTSPayload(poisonedJPEG)
        #expect(sanitizedJPEG == cleanTS)

        // Short/non-TS buffer returns safely untouched with zero OOB reads
        let tiny = Data([0x01, 0x02, 0x03, 0x04])
        #expect(CuriumHLSTransferEngine.sanitizeMPEGTSPayload(tiny) == tiny)
    }

    @Test("filterInjectedAdDiscontinuities strips minority cross-origin ad pods while preserving mediaSequence")
    func filterInjectedAdDiscontinuitiesStripsMinorityAdPods() throws {
        let hostileManifest = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:50
        #EXTINF:6.0,
        https://cdn-main.stream-host.example/vod/seg_000.jpg
        #EXTINF:6.0,
        https://cdn-main.stream-host.example/vod/seg_001.jpg
        #EXTINF:6.0,
        https://cdn-main.stream-host.example/vod/seg_002.jpg
        #EXTINF:6.0,
        https://cdn-main.stream-host.example/vod/seg_003.jpg
        #EXT-X-DISCONTINUITY
        #EXTINF:5.0,
        https://ad-pod.promo.example/preroll/ad_0.ts
        #EXTINF:5.0,
        https://ad-pod.promo.example/preroll/ad_1.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:6.0,
        https://cdn-main.stream-host.example/vod/seg_004.jpg
        #EXTINF:6.0,
        https://cdn-main.stream-host.example/vod/seg_005.jpg
        #EXTINF:6.0,
        https://cdn-main.stream-host.example/vod/seg_006.jpg
        #EXTINF:6.0,
        https://cdn-main.stream-host.example/vod/seg_007.jpg
        """

        let parsed = try CuriumHLSTransferEngine.parseMediaPlaylist(
            manifestText: hostileManifest,
            baseURL: URL(string: "https://cdn-main.stream-host.example/vod/index.m3u8")!
        )

        #expect(parsed.strippedAdSegmentsCount == 2)
        #expect(parsed.segments.count == 8)
        #expect(parsed.segments.allSatisfy { $0.url.host() == "cdn-main.stream-host.example" })
        #expect(parsed.segments.map(\.sequenceIndex) == Array(0..<8))
        // Original mediaSequence values are preserved across stripped indices so AES-128 IV derivation stays exact.
        #expect(parsed.segments[0].mediaSequence == 50)
        #expect(parsed.segments[3].mediaSequence == 53)
        #expect(parsed.segments[4].mediaSequence == 56)
        #expect(parsed.segments[7].mediaSequence == 59)
    }

    @Test("AIMDConcurrencyGate performs additive increase per 6 clean segments and multiplicative decrease to min 2")
    func aimdConcurrencyGateAdditiveIncreaseAndMultiplicativeDecrease() async {
        let gate = AIMDConcurrencyGate(initialLimit: 6, maxLimit: 12)
        #expect(await gate.currentLimit == 6)

        // 5 clean segments: still 6
        for _ in 0..<5 {
            await gate.recordSuccess()
        }
        #expect(await gate.currentLimit == 6)

        // 6th clean segment: +1 -> 7
        await gate.recordSuccess()
        #expect(await gate.currentLimit == 7)

        // Another 6 clean segments: +1 -> 8
        for _ in 0..<6 {
            await gate.recordSuccess()
        }
        #expect(await gate.currentLimit == 8)

        // Congestion halves: 8 -> 4 and resets clean streak
        await gate.recordCongestion()
        #expect(await gate.currentLimit == 4)

        // Repeated congestion clamps at min 2: 4 -> 2 -> 2
        await gate.recordCongestion()
        #expect(await gate.currentLimit == 2)
        await gate.recordCongestion()
        #expect(await gate.currentLimit == 2)

        // Ceiling clamps at max 20
        let highGate = AIMDConcurrencyGate(initialLimit: 18, maxLimit: 64)
        #expect(highGate.maxLimit == 20)
        for _ in 0..<24 {
            await highGate.recordSuccess()
        }
        #expect(await highGate.currentLimit == 20)
    }

    @Test("Playlist parser fast-fails on SAMPLE-AES DRM, blocks SSRF, and resolves #EXT-X-MAP BYTERANGE")
    func playlistParserSecurityDRMAndByteRange() throws {
        let baseURL = URL(string: "https://cdn.example.com/hls/variant.m3u8")!

        // 1. SAMPLE-AES DRM must fast-fail with drmUnsupported
        let drmPlaylist = """
        #EXTM3U
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://fairplay.example/key"
        #EXTINF:4.0,
        seg0.ts
        """
        #expect(throws: CuriumHLSError.drmUnsupported(method: "SAMPLE-AES")) {
            _ = try CuriumHLSTransferEngine.parseMediaPlaylist(manifestText: drmPlaylist, baseURL: baseURL)
        }

        // 2. Public manifest referencing private loopback key/segment must be blocked (SSRF)
        let ssrfPlaylist = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="http://127.0.0.1:8080/key"
        #EXTINF:4.0,
        seg0.ts
        """
        #expect(throws: CuriumHLSError.blockedPrivateNetworkHost("127.0.0.1")) {
            _ = try CuriumHLSTransferEngine.parseMediaPlaylist(manifestText: ssrfPlaylist, baseURL: baseURL)
        }

        // 3. #EXT-X-MAP BYTERANGE without @offset defaults to offset 0, and chained segment BYTERANGE chains cleanly
        let byteRangePlaylist = """
        #EXTM3U
        #EXT-X-MAP:URI="combined.mp4",BYTERANGE="720"
        #EXTINF:4.0,
        #EXT-X-BYTERANGE:1000@720
        combined.mp4
        #EXTINF:4.0,
        #EXT-X-BYTERANGE:1500
        combined.mp4
        """
        let parsed = try CuriumHLSTransferEngine.parseMediaPlaylist(manifestText: byteRangePlaylist, baseURL: baseURL)
        #expect(parsed.isFragmentedMP4)
        #expect(parsed.initializationByteRange == .init(offset: 0, length: 720))
        #expect(parsed.initializationByteRange?.headerValue == "bytes=0-719")
        #expect(parsed.segments.count == 2)
        #expect(parsed.segments[0].byteRange == .init(offset: 720, length: 1000))
        #expect(parsed.segments[1].byteRange == .init(offset: 1720, length: 1500))

        // 4. Master playlist selects highest bandwidth variant and default audio rendition
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",DEFAULT=YES,AUTOSELECT=YES,URI="audio/en.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Commentary",DEFAULT=NO,URI="audio/comm.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=1280x720,AUDIO="aud"
        720p/prog.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=6400000,RESOLUTION=1920x1080,AUDIO="aud"
        1080p/prog.m3u8
        """
        let selected = try #require(
            try CuriumHLSTransferEngine.selectBestVariant(
                manifestText: master,
                baseURL: URL(string: "https://cdn.example.com/hls/master.m3u8")!
            )
        )
        #expect(selected.playlistURL.absoluteString == "https://cdn.example.com/hls/1080p/prog.m3u8")
        #expect(selected.audioPlaylistURL?.absoluteString == "https://cdn.example.com/hls/audio/en.m3u8")
    }

    // MARK: - 2. Loopback HTTP AES-128 Concurrent Download + Pause/Resume + Monotonic Telemetry

    @Test("Loopback AES-128 HLS download supports pause/resume without re-fetching completed segments and emits monotonic bytes")
    func loopbackAES128DownloadPauseResumeAndMonotonicTelemetry() async throws {
        let totalSegments = 10
        let mediaSequenceBase: UInt64 = 100
        let aesKey = Data((0..<16).map { UInt8(0xA0 + $0) })

        // Valid ISO-BMFF `ftyp` header + deterministic payload so single-track fMP4 fast-moves bit-exact.
        var initPlain = Data([
            0x00, 0x00, 0x00, 0x18,
            0x66, 0x74, 0x79, 0x70, // "ftyp"
            0x69, 0x73, 0x6F, 0x6D, // "isom"
            0x00, 0x00, 0x02, 0x00,
            0x69, 0x73, 0x6F, 0x6D,
            0x69, 0x73, 0x6F, 0x36
        ])
        initPlain.append(Self.deterministicBytes(seed: 0x10, count: 4096))

        var segmentPlaintexts: [Data] = []
        var segmentCiphertexts: [Data] = []
        for idx in 0..<totalSegments {
            let size = 16_384 + (idx * 3_117)
            let plain = Self.deterministicBytes(seed: UInt8(0x20 + idx), count: size)
            let iv = CuriumHLSTransferEngine.resolveIV(explicitIV: nil, mediaSequence: mediaSequenceBase + UInt64(idx))
            let cipher = try Self.encryptAES128CBC(plaintext: plain, key: aesKey, iv: iv)
            segmentPlaintexts.append(plain)
            segmentCiphertexts.append(cipher)
        }

        let masterText = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=1280x720
        variant.m3u8
        """
        var variantLines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:4",
            "#EXT-X-MEDIA-SEQUENCE:\(mediaSequenceBase)",
            "#EXT-X-MAP:URI=\"init.mp4\"",
            "#EXT-X-KEY:METHOD=AES-128,URI=\"enc.key\""
        ]
        for idx in 0..<totalSegments {
            variantLines.append("#EXTINF:4.0,")
            variantLines.append("seg\(idx).m4s")
        }
        variantLines.append("#EXT-X-ENDLIST")
        let variantText = variantLines.joined(separator: "\n")

        let initBytes = initPlain
        let encryptedSegments = segmentCiphertexts
        let serverState = LoopbackHLSServerState()
        let seg5TransientFailed = AtomicFlag()
        let server = try LoopbackHTTPServer { request in
            serverState.record(request: request)
            switch request.path {
            case "/stream/master.m3u8":
                return .ok(Data(masterText.utf8), contentType: "application/vnd.apple.mpegurl")
            case "/stream/variant.m3u8":
                return .ok(Data(variantText.utf8), contentType: "application/vnd.apple.mpegurl")
            case "/stream/enc.key":
                return .ok(aesKey, contentType: "application/octet-stream")
            case "/stream/init.mp4":
                return .ok(initBytes, contentType: "video/mp4")
            default:
                if request.path.hasPrefix("/stream/seg"), request.path.hasSuffix(".m4s") {
                    let numStr = request.path
                        .replacingOccurrences(of: "/stream/seg", with: "")
                        .replacingOccurrences(of: ".m4s", with: "")
                    if let idx = Int(numStr), idx >= 0, idx < totalSegments {
                        // Gate segments >= 4 during Run 1 so Run 1 deterministically completes 0..<4 then pauses.
                        if idx >= 4 && serverState.isGateClosed {
                            await serverState.waitUntilGateOpens()
                        }
                        // Simulate a transient 503 with Retry-After: 0 on seg5 once to verify retry recovery.
                        if idx == 5 && seg5TransientFailed.setIfFalse() {
                            return LoopbackHTTPResponse(
                                statusCode: 503,
                                reason: "Service Unavailable",
                                headers: ["Retry-After": "0"],
                                body: Data()
                            )
                        }
                        return .ok(encryptedSegments[idx], contentType: "video/iso.segment")
                    }
                }
                return LoopbackHTTPResponse(statusCode: 404, reason: "Not Found", body: Data())
            }
        }
        defer {
            serverState.openGate()
            server.stop()
        }
        serverState.closeGate()

        let tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "curium-hls-resume-\(UUID().uuidString)", directoryHint: .isDirectory)
        let stagingDir = tempRoot.appending(path: "staging", directoryHint: .isDirectory)
        let destinationURL = tempRoot.appending(path: "output.mp4", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let manifestURL = URL(string: "http://127.0.0.1:\(server.port)/stream/master.m3u8")!
        let requestConfig = CuriumHLSRequestConfig(
            userAgent: "CuriumTestAgent/1.0",
            cookieResolver: { _ in "session=curium_test_cookie" }
        )
        let engine = CuriumHLSTransferEngine()

        // --- Run 1: Download until >= 3 segments are checkpointed, then cancel (Pause) ---
        let run1Updates = LockedBox<[CuriumHLSProgressUpdate]>([])
        let pauseTrigger = AsyncSignal()

        let run1Task = Task<CuriumHLSDownloadResult, Error> {
            try await engine.download(
                manifestURL: manifestURL,
                stagingDirectoryURL: stagingDir,
                destinationURL: destinationURL,
                requestConfig: requestConfig,
                concurrency: 6
            ) { update in
                run1Updates.withLock { $0.append(update) }
                if update.phase == .downloadingSegments && update.resumeState.completedSegments >= 3 {
                    pauseTrigger.signal()
                }
            }
        }

        await pauseTrigger.wait()
        run1Task.cancel()
        // Release gate immediately after cancel so any server handler waiting on seg4 exits cleanly.
        serverState.openGate()

        var didThrowCancellation = false
        do {
            _ = try await run1Task.value
        } catch is CancellationError {
            didThrowCancellation = true
        }
        #expect(didThrowCancellation, "Pausing an HLS download must throw CancellationError")

        let updates1 = run1Updates.value
        let pausedUpdate = try #require(updates1.last)
        let savedResumeState = pausedUpdate.resumeState
        #expect(savedResumeState.completedSegments >= 3)
        #expect(savedResumeState.completedSegments < totalSegments)
        #expect(savedResumeState.contiguousByteOffset > Int64(initPlain.count))
        #expect(savedResumeState.isFMP4)

        // Verify staging `video.part` survived cancellation intact!
        let videoPartURL = stagingDir.appending(path: "video.part", directoryHint: .notDirectory)
        #expect(FileManager.default.fileExists(atPath: videoPartURL.path))
        let stagedSize = try FileManager.default.attributesOfItem(atPath: videoPartURL.path)[.size] as? NSNumber
        #expect((stagedSize?.int64Value ?? 0) >= savedResumeState.contiguousByteOffset)

        // Verify cookieResolver header reached the server and AES key fetch was deduplicated.
        let run1Requests = serverState.snapshotAndResetRequests()
        #expect(run1Requests.contains(where: { $0.headers["cookie"] == "session=curium_test_cookie" }))
        let keyFetchesRun1 = run1Requests.filter { $0.path == "/stream/enc.key" }.count
        #expect(keyFetchesRun1 == 1, "AESKeyCache must deduplicate concurrent key requests")

        // Append trailing uncommitted garbage past `contiguousByteOffset` to prove resume `ftruncate`s cleanly!
        let handle = try FileHandle(forUpdating: videoPartURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0xDE, count: 4096))
        try handle.close()

        // --- Run 2: Resume from savedResumeState ---
        let run2Updates = LockedBox<[CuriumHLSProgressUpdate]>([])
        let result = try await engine.download(
            manifestURL: manifestURL,
            stagingDirectoryURL: stagingDir,
            destinationURL: destinationURL,
            requestConfig: requestConfig,
            concurrency: 6,
            resumeState: savedResumeState
        ) { update in
            run2Updates.withLock { $0.append(update) }
        }

        let run2Requests = serverState.snapshotAndResetRequests()
        let run2Paths = run2Requests.map(\.path)

        // Must NEVER re-fetch init.mp4 or already-checkpointed segments 0..<k!
        #expect(!run2Paths.contains("/stream/init.mp4"))
        for skippedIdx in 0..<savedResumeState.completedSegments {
            #expect(
                !run2Paths.contains("/stream/seg\(skippedIdx).m4s"),
                "Resumed HLS transfer must not re-fetch completed segment \(skippedIdx)"
            )
        }
        for remainingIdx in savedResumeState.completedSegments..<totalSegments {
            #expect(run2Paths.contains("/stream/seg\(remainingIdx).m4s"))
        }

        // Verify monotonic telemetry invariants across Run 1 and Run 2!
        let allUpdates = updates1 + run2Updates.value
        Self.assertMonotonicTelemetry(updates1, totalSegments: totalSegments)
        Self.assertMonotonicTelemetry(run2Updates.value, totalSegments: totalSegments)
        #expect(allUpdates.contains(where: { $0.phase == .fetchingPlaylist }))
        #expect(allUpdates.contains(where: { $0.phase == .downloadingSegments }))
        #expect(allUpdates.contains(where: { $0.phase == .remuxing }))

        // Verify final reconstructed file is 100% BIT-EXACT!
        var expectedOutput = initPlain
        for plain in segmentPlaintexts {
            expectedOutput.append(plain)
        }
        let actualOutput = try Data(contentsOf: result.outputFileURL)
        #expect(result.outputFileURL == destinationURL)
        #expect(result.completedSegments == totalSegments)
        #expect(result.totalBytes == Int64(expectedOutput.count))
        #expect(!result.wasRemuxedToMP4)
        #expect(actualOutput == expectedOutput)
    }

    @Test("Permanent HTTP 404 on manifest fails fast after a single attempt without retrying")
    func permanent404FailsFastWithoutRetrying() async throws {
        let serverState = LoopbackHLSServerState()
        let server = try LoopbackHTTPServer { request in
            serverState.record(request: request)
            return LoopbackHTTPResponse(statusCode: 404, reason: "Not Found", body: Data())
        }
        defer { server.stop() }

        let engine = CuriumHLSTransferEngine()
        let missingURL = URL(string: "http://127.0.0.1:\(server.port)/missing/master.m3u8")!

        var caughtCode: Int?
        do {
            _ = try await engine.resolveMediaPlaylist(from: missingURL)
        } catch let err as CuriumHLSError {
            if case .httpStatusError(let code, _) = err {
                caughtCode = code
            }
        }
        #expect(caughtCode == 404)
        #expect(serverState.snapshotAndResetRequests().count == 1)
    }

    @Test("Blocked 3xx SSRF and disallowed-scheme redirects throw security errors instead of CancellationError")
    func blocked3xxRedirectsFailFastWithSecurityErrorInsteadOfCancellation() async throws {
        // 1. Real loopback HTTP 302 -> ftp://blocked.example/secret.m3u8 with a large body must
        //    cancel immediately in HLSRedirectSecurityDelegate and surface
        //    CuriumHLSError.disallowedURLScheme("ftp"), never CancellationError.
        let serverState = LoopbackHLSServerState()
        let largeBody = Data(repeating: 0x41, count: 65_536)
        let server = try LoopbackHTTPServer { request in
            serverState.record(request: request)
            return LoopbackHTTPResponse(
                statusCode: 302,
                reason: "Found",
                headers: ["Location": "ftp://blocked.example/secret.m3u8"],
                body: largeBody
            )
        }
        defer { server.stop() }

        let engine = CuriumHLSTransferEngine()
        let schemeRedirectURL = URL(string: "http://127.0.0.1:\(server.port)/redirect-scheme/master.m3u8")!
        var caughtSchemeError: CuriumHLSError?
        do {
            _ = try await engine.resolveMediaPlaylist(from: schemeRedirectURL)
        } catch let err as CuriumHLSError {
            caughtSchemeError = err
        }
        #expect(caughtSchemeError == .disallowedURLScheme("ftp"))
        #expect(serverState.snapshotAndResetRequests().count == 1)

        // 2. Public HTTPS origin 302 -> http://127.0.0.1:8080/internal.m3u8 must fail fast with
        //    CuriumHLSError.blockedPrivateNetworkHost("127.0.0.1") without ever touching 127.0.0.1.
        HLSBlockedRedirectURLProtocol.privateTargetHits.withLock { $0 = 0 }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [HLSBlockedRedirectURLProtocol.self]
        let mockSession = URLSession(configuration: cfg)
        defer { mockSession.finishTasksAndInvalidate() }

        let publicOrigin = URL(string: "https://public-cdn.example/watch")!
        let publicManifest = URL(string: "https://public-cdn.example/hls/master.m3u8")!
        let requestConfig = CuriumHLSRequestConfig(
            originatingURL: publicOrigin,
            sessionFactory: { mockSession }
        )

        var caughtSSRFError: CuriumHLSError?
        do {
            _ = try await engine.resolveMediaPlaylist(from: publicManifest, requestConfig: requestConfig)
        } catch let err as CuriumHLSError {
            caughtSSRFError = err
        }
        #expect(caughtSSRFError == .blockedPrivateNetworkHost("127.0.0.1"))
        #expect(HLSBlockedRedirectURLProtocol.privateTargetHits.value == 0)
    }

    // MARK: - 3. CuriumNativeMP4Remuxer & CuriumMediaMuxActor Verification with Real AVURLAsset

    @Test("CuriumNativeMP4Remuxer and CuriumMediaMuxActor remux synthetic H.264+AAC MPEG-TS into playable MP4")
    func nativeMPEGTSRemuxAndMediaMuxActorProducePlayableMP4() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "curium-remux-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // 1. Synthesize genuine H.264 + AAC MPEG-TS streams purely offline via AVFoundation.
        let fixtures = try await SyntheticMPEGTSFactory.makeFixtures(in: tempRoot)

        // 2. Test direct CuriumNativeMP4Remuxer on a fake-PNG-poisoned muxed H.264+AAC MPEG-TS file.
        var poisonedTS = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        poisonedTS.append(Data(repeating: 0x33, count: 64))
        poisonedTS.append(fixtures.muxedTSData)

        let cleanTS = CuriumHLSTransferEngine.sanitizeMPEGTSPayload(poisonedTS)
        #expect(cleanTS == fixtures.muxedTSData)

        let tsFile = tempRoot.appending(path: "muxed.ts", directoryHint: .notDirectory)
        let directMP4 = tempRoot.appending(path: "direct-remux.mp4", directoryHint: .notDirectory)
        try cleanTS.write(to: tsFile)
        #expect(!CuriumNativeMP4Remuxer.isISOBaseMediaFile(at: tsFile))
        #expect(CuriumNativeMP4Remuxer.isTransportStreamFile(at: tsFile))

        try await CuriumNativeMP4Remuxer.remuxMPEGTS(from: tsFile, to: directMP4)
        #expect(CuriumNativeMP4Remuxer.isISOBaseMediaFile(at: directMP4))

        let directAsset = AVURLAsset(url: directMP4)
        let directPlayable = try await directAsset.load(.isPlayable)
        let directDuration = try await directAsset.load(.duration)
        let directVideoTracks = try await directAsset.loadTracks(withMediaType: .video)
        let directAudioTracks = try await directAsset.loadTracks(withMediaType: .audio)
        #expect(directPlayable)
        #expect(directVideoTracks.count == 1)
        #expect(directAudioTracks.count == 1)
        #expect(directDuration.seconds > 0.25)

        // 3. Test CuriumMediaMuxActor with split `.ts` tracks named `video.part` + `audio.part`
        // (proving TS pre-remuxing prevents AVMutableComposition from failing on `.ts` / `.part` inputs).
        let splitVideoPart = tempRoot.appending(path: "video.part", directoryHint: .notDirectory)
        let splitAudioPart = tempRoot.appending(path: "audio.part", directoryHint: .notDirectory)
        let splitMuxedMP4 = tempRoot.appending(path: "split-muxed.mp4", directoryHint: .notDirectory)
        try fixtures.videoOnlyTSData.write(to: splitVideoPart)
        try fixtures.audioOnlyTSData.write(to: splitAudioPart)

        try await CuriumMediaMuxActor.shared.remux(
            videoURL: splitVideoPart,
            audioURL: splitAudioPart,
            destinationURL: splitMuxedMP4
        )
        #expect(CuriumNativeMP4Remuxer.isISOBaseMediaFile(at: splitMuxedMP4))

        let splitAsset = AVURLAsset(url: splitMuxedMP4)
        #expect(try await splitAsset.load(.isPlayable))
        #expect((try await splitAsset.loadTracks(withMediaType: .video)).count == 1)
        #expect((try await splitAsset.loadTracks(withMediaType: .audio)).count == 1)
        #expect((try await splitAsset.load(.duration)).seconds > 0.25)

        // 4. End-to-end CuriumHLSTransferEngine over loopback HTTP serving fake-PNG-prefixed TS segments -> .mp4!
        let packetCount = fixtures.muxedTSData.count / 188
        let split1 = (packetCount / 3) * 188
        let split2 = ((packetCount * 2) / 3) * 188
        let rawChunks: [Data] = [
            fixtures.muxedTSData.subdata(in: 0..<split1),
            fixtures.muxedTSData.subdata(in: split1..<split2),
            fixtures.muxedTSData.subdata(in: split2..<fixtures.muxedTSData.count)
        ]
        let disguisedChunks: [Data] = rawChunks.map { chunk in
            var wrapped = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            wrapped.append(Data(repeating: 0xCC, count: 56))
            wrapped.append(chunk)
            return wrapped
        }
        let tsPlaylist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:2
        #EXTINF:1.0,
        chunk0.jpg
        #EXTINF:1.0,
        chunk1.jpg
        #EXTINF:1.0,
        chunk2.jpg
        #EXT-X-ENDLIST
        """

        let server = try LoopbackHTTPServer { req in
            switch req.path {
            case "/ts/index.m3u8":
                return .ok(Data(tsPlaylist.utf8), contentType: "application/vnd.apple.mpegurl")
            case "/ts/chunk0.jpg":
                return .ok(disguisedChunks[0], contentType: "image/jpeg")
            case "/ts/chunk1.jpg":
                return .ok(disguisedChunks[1], contentType: "image/jpeg")
            case "/ts/chunk2.jpg":
                return .ok(disguisedChunks[2], contentType: "image/jpeg")
            default:
                return LoopbackHTTPResponse(statusCode: 404, reason: "Not Found", body: Data())
            }
        }
        defer { server.stop() }

        let e2eStaging = tempRoot.appending(path: "e2e-staging", directoryHint: .isDirectory)
        let e2eOutput = tempRoot.appending(path: "e2e-output.mp4", directoryHint: .notDirectory)
        let engine = CuriumHLSTransferEngine()
        let e2eResult = try await engine.download(
            manifestURL: URL(string: "http://127.0.0.1:\(server.port)/ts/index.m3u8")!,
            stagingDirectoryURL: e2eStaging,
            destinationURL: e2eOutput,
            concurrency: 3
        ) { _ in }

        #expect(e2eResult.wasRemuxedToMP4)
        #expect(e2eResult.completedSegments == 3)
        #expect(e2eResult.totalBytes > 0)
        #expect(CuriumNativeMP4Remuxer.isISOBaseMediaFile(at: e2eOutput))

        let e2eAsset = AVURLAsset(url: e2eOutput)
        #expect(try await e2eAsset.load(.isPlayable))
        #expect((try await e2eAsset.loadTracks(withMediaType: .video)).count == 1)
        #expect((try await e2eAsset.loadTracks(withMediaType: .audio)).count == 1)
    }

    // MARK: - Telemetry & Crypto Test Helpers

    private static func assertMonotonicTelemetry(
        _ updates: [CuriumHLSProgressUpdate],
        totalSegments: Int
    ) {
        var prevCompleted = -1
        var prevReceived: Int64 = -1
        var prevEstimate: Int64?

        for update in updates {
            #expect(update.completedSegments >= prevCompleted, "completedSegments must be monotonic")
            #expect(update.receivedBytes >= prevReceived, "receivedBytes must be monotonic")

            if update.phase == .downloadingSegments {
                #expect(update.totalSegments == totalSegments)
                // NEVER report segment count as byte estimate!
                if update.completedSegments < 2 {
                    #expect(
                        update.estimatedTotalBytes == nil,
                        "estimatedTotalBytes must be nil until >= 2 segments complete"
                    )
                } else if let est = update.estimatedTotalBytes {
                    #expect(est >= update.receivedBytes)
                    #expect(est != Int64(totalSegments), "estimatedTotalBytes must never be segment count")
                    if let prev = prevEstimate {
                        #expect(est >= prev, "estimatedTotalBytes must be monotonically non-decreasing")
                    }
                    prevEstimate = est
                }
            }
            prevCompleted = update.completedSegments
            prevReceived = update.receivedBytes
        }
    }

    private static func deterministicBytes(seed: UInt8, count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var state = UInt64(seed) &+ 0x9E37_79B9_7F4A_7C15
        for i in 0..<count {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            bytes[i] = UInt8(truncatingIfNeeded: state)
        }
        return Data(bytes)
    }

    private static func encryptAES128CBC(plaintext: Data, key: Data, iv: Data) throws -> Data {
        let outCap = plaintext.count + kCCBlockSizeAES128
        var out = Data(count: outCap)
        var outLen = 0
        let status = out.withUnsafeMutableBytes { outBuf in
            plaintext.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, key.count,
                            ivBuf.baseAddress,
                            inBuf.baseAddress, plaintext.count,
                            outBuf.baseAddress, outCap,
                            &outLen
                        )
                    }
                }
            }
        }
        #expect(status == kCCSuccess)
        out.count = outLen
        return out
    }
}

// MARK: - Concurrency Test Primitives

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ initial: T) {
        self.storage = initial
    }

    var value: T {
        lock.withLock { storage }
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.withLock { body(&storage) }
    }
}

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func setIfFalse() -> Bool {
        lock.withLock {
            if flag { return false }
            flag = true
            return true
        }
    }
}

private final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            if signaled { return [] }
            signaled = true
            let list = waiters
            waiters.removeAll()
            return list
        }
        for cont in toResume {
            cont.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { cont in
            let alreadySignaled: Bool = lock.withLock {
                if signaled { return true }
                waiters.append(cont)
                return false
            }
            if alreadySignaled {
                cont.resume()
            }
        }
    }
}

// MARK: - Minimal Loopback HTTP/1.1 Server (NWListener)

private struct LoopbackHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
}

private struct LoopbackHTTPResponse: Sendable {
    let statusCode: Int
    let reason: String
    let headers: [String: String]
    let body: Data

    init(statusCode: Int, reason: String, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.reason = reason
        self.headers = headers
        self.body = body
    }

    static func ok(_ body: Data, contentType: String = "application/octet-stream") -> LoopbackHTTPResponse {
        LoopbackHTTPResponse(
            statusCode: 200,
            reason: "OK",
            headers: ["Content-Type": contentType],
            body: body
        )
    }
}

private final class LoopbackHLSServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [LoopbackHTTPRequest] = []
    private var gateClosed = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    func record(request: LoopbackHTTPRequest) {
        lock.withLock { requests.append(request) }
    }

    func snapshotAndResetRequests() -> [LoopbackHTTPRequest] {
        lock.withLock {
            let copy = requests
            requests.removeAll()
            return copy
        }
    }

    var isGateClosed: Bool {
        lock.withLock { gateClosed }
    }

    func closeGate() {
        lock.withLock { gateClosed = true }
    }

    func openGate() {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            gateClosed = false
            let list = gateWaiters
            gateWaiters.removeAll()
            return list
        }
        for cont in toResume {
            cont.resume()
        }
    }

    func waitUntilGateOpens() async {
        await withCheckedContinuation { cont in
            let shouldWait: Bool = lock.withLock {
                if !gateClosed { return false }
                gateWaiters.append(cont)
                return true
            }
            if !shouldWait {
                cont.resume()
            }
        }
    }
}

private final class HLSBlockedRedirectURLProtocol: URLProtocol, @unchecked Sendable {
    static let privateTargetHits = LockedBox<Int>(0)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if url.host() == "127.0.0.1" {
            Self.privateTargetHits.withLock { $0 += 1 }
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("LEAKED".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let target = URL(string: "http://127.0.0.1:8080/internal.m3u8")!
        let redirectResp = HTTPURLResponse(
            url: url,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": target.absoluteString]
        )!
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: redirectResp)
    }

    override func stopLoading() {}
}

private final class ActiveConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    func add(_ connection: NWConnection) {
        lock.withLock { connections[ObjectIdentifier(connection)] = connection }
    }

    func remove(_ connection: NWConnection) {
        _ = lock.withLock { connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    func cancelAll() {
        let snapshot: [NWConnection] = lock.withLock {
            let all = Array(connections.values)
            connections.removeAll()
            return all
        }
        for connection in snapshot {
            connection.cancel()
        }
    }
}

private final class LoopbackHTTPServer: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener
    private let connectionRegistry: ActiveConnectionRegistry
    private let queue = DispatchQueue(label: "com.appautomaton.curium.test.loopback-http", attributes: .concurrent)

    init(handler: @escaping @Sendable (LoopbackHTTPRequest) async -> LoopbackHTTPResponse) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        let registry = ActiveConnectionRegistry()
        self.listener = listener
        self.connectionRegistry = registry

        let readySem = DispatchSemaphore(value: 0)
        let stateError = LockedBox<Error?>(nil)

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                readySem.signal()
            case .failed(let err):
                stateError.withLock { $0 = err }
                readySem.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [queue] connection in
            registry.add(connection)
            connection.stateUpdateHandler = { state in
                switch state {
                case .cancelled, .failed:
                    registry.remove(connection)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            Self.receiveHTTPRequest(on: connection, registry: registry, accumulated: Data(), handler: handler)
        }

        listener.start(queue: queue)
        let waitResult = readySem.wait(timeout: .now() + 5)
        if let err = stateError.value {
            listener.cancel()
            registry.cancelAll()
            throw err
        }
        guard waitResult == .success, let boundPort = listener.port?.rawValue, boundPort > 0 else {
            listener.cancel()
            registry.cancelAll()
            throw URLError(.cannotConnectToHost)
        }
        self.port = boundPort
    }

    func stop() {
        listener.cancel()
        connectionRegistry.cancelAll()
    }

    private static func receiveHTTPRequest(
        on connection: NWConnection,
        registry: ActiveConnectionRegistry,
        accumulated: Data,
        handler: @escaping @Sendable (LoopbackHTTPRequest) async -> LoopbackHTTPResponse
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if error != nil {
                registry.remove(connection)
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let data {
                buffer.append(data)
            }
            let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
            if let range = buffer.range(of: separator) {
                let headerData = buffer.subdata(in: 0..<range.lowerBound)
                if let parsed = Self.parseRequest(headerData) {
                    Task {
                        let resp = await handler(parsed)
                        let wire = Self.serializeResponse(resp)
                        connection.send(content: wire, completion: .contentProcessed { _ in
                            registry.remove(connection)
                            connection.cancel()
                        })
                    }
                    return
                }
                registry.remove(connection)
                connection.cancel()
                return
            }
            if isComplete {
                registry.remove(connection)
                connection.cancel()
                return
            }
            Self.receiveHTTPRequest(on: connection, registry: registry, accumulated: buffer, handler: handler)
        }
    }

    private static func parseRequest(_ headerData: Data) -> LoopbackHTTPRequest? {
        guard let text = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }
        return LoopbackHTTPRequest(method: method, path: path, headers: headers)
    }

    private static func serializeResponse(_ response: LoopbackHTTPResponse) -> Data {
        var headerLines = [
            "HTTP/1.1 \(response.statusCode) \(response.reason)",
            "Content-Length: \(response.body.count)",
            "Connection: close"
        ]
        for (k, v) in response.headers {
            headerLines.append("\(k): \(v)")
        }
        var data = Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(response.body)
        return data
    }
}

// MARK: - Offline Synthetic H.264 + AAC MPEG-TS Fixture Factory

private enum SyntheticMPEGTSFactory {
    struct Fixtures: Sendable {
        let muxedTSData: Data
        let videoOnlyTSData: Data
        let audioOnlyTSData: Data
    }

    static func makeFixtures(in directory: URL) async throws -> Fixtures {
        let seedMP4 = directory.appending(path: "seed-source.mp4", directoryHint: .notDirectory)
        try await encodeSeedMP4(to: seedMP4)

        let (sps, pps, videoSamples, aacFrames, sampleRate, channelCount) = try await extractElementarySamples(from: seedMP4)
        let muxed = packetizeMPEGTS(
            sps: sps,
            pps: pps,
            videoSamples: videoSamples,
            aacFrames: aacFrames,
            sampleRate: sampleRate,
            channelCount: channelCount,
            includeVideo: true,
            includeAudio: true
        )
        let videoOnly = packetizeMPEGTS(
            sps: sps,
            pps: pps,
            videoSamples: videoSamples,
            aacFrames: [],
            sampleRate: sampleRate,
            channelCount: channelCount,
            includeVideo: true,
            includeAudio: false
        )
        let audioOnly = packetizeMPEGTS(
            sps: Data(),
            pps: Data(),
            videoSamples: [],
            aacFrames: aacFrames,
            sampleRate: sampleRate,
            channelCount: channelCount,
            includeVideo: false,
            includeAudio: true
        )
        return Fixtures(muxedTSData: muxed, videoOnlyTSData: videoOnly, audioOnlyTSData: audioOnly)
    }

    private struct EncodedVideoSample {
        let avccData: Data
        let pts90k: Int64
        let dts90k: Int64
        let isSync: Bool
    }

    private struct EncodedAudioSample {
        let rawAAC: Data
        let pts90k: Int64
    }

    private static func encodeSeedMP4(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let width = 128
        let height = 96
        let fps: Int32 = 15
        let totalFrames = 12 // 0.8 seconds

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 250_000,
                AVVideoMaxKeyFrameIntervalKey: 6,
                AVVideoAllowFrameReorderingKey: false
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        writer.add(videoInput)

        let audioSampleRate = 44_100
        let audioSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw writer.error ?? URLError(.cannotWriteToFile)
        }
        writer.startSession(atSourceTime: .zero)

        // Write 12 video frames
        for frameIdx in 0..<totalFrames {
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                nil,
                &pixelBuffer
            )
            guard status == kCVReturnSuccess, let pb = pixelBuffer else {
                throw URLError(.cannotWriteToFile)
            }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
                memset(base, Int32((frameIdx * 20) & 0xFF), bytesPerRow * height)
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            let pts = CMTime(value: Int64(frameIdx), timescale: fps)
            _ = adaptor.append(pb, withPresentationTime: pts)
        }
        videoInput.markAsFinished()

        // Write 0.8s of PCM audio (35,280 samples in 1024-sample chunks)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(audioSampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var pcmFormatDesc: CMAudioFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &pcmFormatDesc
        )
        guard fmtStatus == noErr, let pcmDesc = pcmFormatDesc else {
            throw URLError(.cannotWriteToFile)
        }

        let framesPerBuffer = 1024
        let totalAudioBuffers = 35 // ~0.81 seconds
        for bufIdx in 0..<totalAudioBuffers {
            while !audioInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            var samples = [Int16](repeating: 0, count: framesPerBuffer)
            let baseSample = bufIdx * framesPerBuffer
            for i in 0..<framesPerBuffer {
                let t = Double(baseSample + i) / Double(audioSampleRate)
                samples[i] = Int16(sin(2.0 * Double.pi * 440.0 * t) * 12_000.0)
            }
            let byteCount = framesPerBuffer * 2
            var block: CMBlockBuffer?
            _ = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
                flags: 0,
                blockBufferOut: &block
            )
            guard let validBlock = block else { continue }
            _ = samples.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(
                    with: raw.baseAddress!,
                    blockBuffer: validBlock,
                    offsetIntoDestination: 0,
                    dataLength: byteCount
                )
            }
            var sbuf: CMSampleBuffer?
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: Int32(audioSampleRate)),
                presentationTimeStamp: CMTime(value: Int64(baseSample), timescale: Int32(audioSampleRate)),
                decodeTimeStamp: .invalid
            )
            var sampleSize = 2
            _ = CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: validBlock,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: pcmDesc,
                sampleCount: framesPerBuffer,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sbuf
            )
            if let sbuf {
                _ = audioInput.append(sbuf)
            }
        }
        audioInput.markAsFinished()

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? URLError(.cannotWriteToFile)
        }
    }

    private static func extractElementarySamples(
        from mp4URL: URL
    ) async throws -> (
        sps: Data,
        pps: Data,
        videoSamples: [EncodedVideoSample],
        aacFrames: [EncodedAudioSample],
        sampleRate: Int,
        channelCount: Int
    ) {
        let asset = AVURLAsset(url: mp4URL)
        let reader = try AVAssetReader(asset: asset)

        let videoTrack = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let audioTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        reader.add(videoOutput)
        reader.add(audioOutput)
        #expect(reader.startReading())

        var sps = Data()
        var pps = Data()
        var videoSamples: [EncodedVideoSample] = []
        while let sbuf = videoOutput.copyNextSampleBuffer() {
            if sps.isEmpty, let desc = CMSampleBufferGetFormatDescription(sbuf) {
                var spsPtr: UnsafePointer<UInt8>?
                var spsSize = 0
                var ppsPtr: UnsafePointer<UInt8>?
                var ppsSize = 0
                _ = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    desc, parameterSetIndex: 0, parameterSetPointerOut: &spsPtr,
                    parameterSetSizeOut: &spsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
                _ = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    desc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPtr,
                    parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
                if let spsPtr, spsSize > 0 { sps = Data(bytes: spsPtr, count: spsSize) }
                if let ppsPtr, ppsSize > 0 { pps = Data(bytes: ppsPtr, count: ppsSize) }
            }
            guard let payload = copyBlockBufferData(from: sbuf), !payload.isEmpty else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sbuf)
            let dts = CMSampleBufferGetDecodeTimeStamp(sbuf)
            let pts90k = CMTimeConvertScale(pts, timescale: 90_000, method: .default).value
            let dts90k = dts.isValid
                ? CMTimeConvertScale(dts, timescale: 90_000, method: .default).value
                : pts90k
            let isSync = !isNotSyncSample(sbuf)
            videoSamples.append(EncodedVideoSample(avccData: payload, pts90k: pts90k, dts90k: dts90k, isSync: isSync))
        }

        var sampleRate = 44_100
        var channelCount = 1
        var aacFrames: [EncodedAudioSample] = []
        while let sbuf = audioOutput.copyNextSampleBuffer() {
            if let desc = CMSampleBufferGetFormatDescription(sbuf),
               let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                sampleRate = Int(asbdPtr.pointee.mSampleRate)
                channelCount = max(1, Int(asbdPtr.pointee.mChannelsPerFrame))
            }
            guard let blockData = copyBlockBufferData(from: sbuf), !blockData.isEmpty else { continue }
            let basePTS = CMTimeConvertScale(
                CMSampleBufferGetPresentationTimeStamp(sbuf),
                timescale: 90_000,
                method: .default
            ).value
            let count = CMSampleBufferGetNumSamples(sbuf)
            var offset = 0
            for idx in 0..<count {
                let frameSize = CMSampleBufferGetSampleSize(sbuf, at: idx)
                guard frameSize > 0, offset + frameSize <= blockData.count else { break }
                let raw = blockData.subdata(in: offset..<(offset + frameSize))
                let framePTS = basePTS + (Int64(idx * 1024) * 90_000) / Int64(sampleRate)
                aacFrames.append(EncodedAudioSample(rawAAC: raw, pts90k: framePTS))
                offset += frameSize
            }
        }

        return (sps, pps, videoSamples, aacFrames, sampleRate, channelCount)
    }

    private static func copyBlockBufferData(from sbuf: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sbuf) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { out in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: out.baseAddress!)
        }
        return status == kCMBlockBufferNoErr ? data : nil
    }

    private static func isNotSyncSample(_ sbuf: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0,
              let rawDict = CFArrayGetValueAtIndex(attachments, 0) else {
            return false
        }
        let dict = unsafeBitCast(rawDict, to: CFDictionary.self)
        return CFDictionaryContainsKey(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
    }

    private static func packetizeMPEGTS(
        sps: Data,
        pps: Data,
        videoSamples: [EncodedVideoSample],
        aacFrames: [EncodedAudioSample],
        sampleRate: Int,
        channelCount: Int,
        includeVideo: Bool,
        includeAudio: Bool
    ) -> Data {
        let pmtPID: UInt16 = 0x1000
        let videoPID: UInt16 = 0x0100
        let audioPID: UInt16 = 0x0101

        var out = Data()
        var cc: [UInt16: UInt8] = [:]

        // 1. PAT packet (PID 0x0000 -> Program 1 on PMT PID 0x1000)
        var patSection = Data([
            0x00, // pointer_field
            0x00, // table_id = PAT
            0xB0, 0x0D, // section_syntax_indicator + section_length = 13
            0x00, 0x01, // transport_stream_id
            0xC1, // version 0, current_next = 1
            0x00, 0x00, // section_number, last_section_number
            0x00, 0x01, // program_number = 1
            UInt8(0xE0 | ((pmtPID >> 8) & 0x1F)),
            UInt8(pmtPID & 0xFF),
            0x00, 0x00, 0x00, 0x00 // placeholder CRC32
        ])
        out.append(makeTSPacket(pid: 0x0000, pusi: true, cc: &cc, payload: &patSection))

        // 2. PMT packet (PID 0x1000 -> H.264 0x1B on 0x0100, AAC 0x0F on 0x0101)
        var esEntries = Data()
        if includeVideo {
            esEntries.append(contentsOf: [0x1B, UInt8(0xE0 | ((videoPID >> 8) & 0x1F)), UInt8(videoPID & 0xFF), 0xF0, 0x00])
        }
        if includeAudio {
            esEntries.append(contentsOf: [0x0F, UInt8(0xE0 | ((audioPID >> 8) & 0x1F)), UInt8(audioPID & 0xFF), 0xF0, 0x00])
        }
        let pmtSectionLen = 9 + esEntries.count + 4
        var pmtSection = Data([
            0x00, // pointer_field
            0x02, // table_id = PMT
            UInt8(0xB0 | ((pmtSectionLen >> 8) & 0x0F)),
            UInt8(pmtSectionLen & 0xFF),
            0x00, 0x01, // program_number = 1
            0xC1,
            0x00, 0x00,
            UInt8(0xE0 | ((videoPID >> 8) & 0x1F)), UInt8(videoPID & 0xFF), // PCR PID
            0xF0, 0x00 // program_info_length = 0
        ])
        pmtSection.append(esEntries)
        pmtSection.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // CRC32
        out.append(makeTSPacket(pid: pmtPID, pusi: true, cc: &cc, payload: &pmtSection))

        // 3. Video PES packets (Annex-B)
        if includeVideo {
            for (idx, sample) in videoSamples.enumerated() {
                var es = Data()
                // AUD
                es.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x09, 0xF0])
                if idx == 0 || sample.isSync {
                    es.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                    es.append(sps)
                    es.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                    es.append(pps)
                }
                // Convert 4-byte length-prefixed AVCC NALUs to Annex-B
                var pos = 0
                while pos + 4 <= sample.avccData.count {
                    let nalLen = (Int(sample.avccData[pos]) << 24)
                        | (Int(sample.avccData[pos + 1]) << 16)
                        | (Int(sample.avccData[pos + 2]) << 8)
                        | Int(sample.avccData[pos + 3])
                    pos += 4
                    guard nalLen > 0, pos + nalLen <= sample.avccData.count else { break }
                    es.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                    es.append(sample.avccData.subdata(in: pos..<(pos + nalLen)))
                    pos += nalLen
                }
                let pes = makePES(streamID: 0xE0, pts90k: sample.pts90k, payload: es)
                appendPESPackets(pes, pid: videoPID, cc: &cc, into: &out)
            }
        }

        // 4. Audio PES packets (ADTS AAC)
        if includeAudio {
            let freqIndex = adtsFrequencyIndex(for: sampleRate)
            for frame in aacFrames {
                let adts = makeADTSFrame(rawAAC: frame.rawAAC, freqIndex: freqIndex, channelConfig: UInt8(channelCount))
                let pes = makePES(streamID: 0xC0, pts90k: frame.pts90k, payload: adts)
                appendPESPackets(pes, pid: audioPID, cc: &cc, into: &out)
            }
        }

        return out
    }

    private static func makePES(streamID: UInt8, pts90k: Int64, payload: Data) -> Data {
        var pes = Data([0x00, 0x00, 0x01, streamID, 0x00, 0x00, 0x80, 0x80, 0x05])
        let pts = UInt64(max(0, pts90k))
        pes.append(UInt8(0x21 | (((pts >> 30) & 0x07) << 1)))
        pes.append(UInt8((pts >> 22) & 0xFF))
        pes.append(UInt8(0x01 | (((pts >> 15) & 0x7F) << 1)))
        pes.append(UInt8((pts >> 7) & 0xFF))
        pes.append(UInt8(0x01 | ((pts & 0x7F) << 1)))
        pes.append(payload)
        return pes
    }

    private static func appendPESPackets(_ pes: Data, pid: UInt16, cc: inout [UInt16: UInt8], into out: inout Data) {
        var offset = 0
        var first = true
        while offset < pes.count {
            let remaining = pes.count - offset
            let chunkLen = min(remaining, 184)
            var slice = pes.subdata(in: offset..<(offset + chunkLen))
            out.append(makeTSPacket(pid: pid, pusi: first, cc: &cc, payload: &slice))
            offset += chunkLen
            first = false
        }
    }

    private static func makeTSPacket(pid: UInt16, pusi: Bool, cc: inout [UInt16: UInt8], payload: inout Data) -> Data {
        let counter = cc[pid, default: 0]
        cc[pid] = (counter + 1) & 0x0F

        var pkt = Data(capacity: 188)
        let b1 = UInt8((pusi ? 0x40 : 0x00) | Int((pid >> 8) & 0x1F))
        let b2 = UInt8(pid & 0xFF)
        let neededStuffing = 184 - payload.count

        if neededStuffing > 0 {
            let b3 = UInt8(0x30 | (counter & 0x0F)) // adaptation + payload
            pkt.append(contentsOf: [0x47, b1, b2, b3])
            let adaptLen = neededStuffing - 1
            pkt.append(UInt8(adaptLen))
            if adaptLen > 0 {
                pkt.append(0x00) // adaptation flags
                if adaptLen > 1 {
                    pkt.append(Data(repeating: 0xFF, count: adaptLen - 1))
                }
            }
            pkt.append(payload)
        } else {
            let b3 = UInt8(0x10 | (counter & 0x0F)) // payload only
            pkt.append(contentsOf: [0x47, b1, b2, b3])
            pkt.append(payload.prefix(184))
        }
        return pkt
    }

    private static func adtsFrequencyIndex(for sampleRate: Int) -> UInt8 {
        let table = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
        return UInt8(table.firstIndex(of: sampleRate) ?? 4)
    }

    private static func makeADTSFrame(rawAAC: Data, freqIndex: UInt8, channelConfig: UInt8) -> Data {
        let frameLen = 7 + rawAAC.count
        let profileMinus1: UInt8 = 1 // AAC-LC (objectType 2 -> profile 1)
        var header = Data(count: 7)
        header[0] = 0xFF
        header[1] = 0xF1 // MPEG-4, Layer 0, protection_absent = 1
        header[2] = (profileMinus1 << 6) | ((freqIndex & 0x0F) << 2) | ((channelConfig >> 2) & 0x01)
        header[3] = ((channelConfig & 0x03) << 6) | UInt8((frameLen >> 11) & 0x03)
        header[4] = UInt8((frameLen >> 3) & 0xFF)
        header[5] = UInt8(((frameLen & 0x07) << 5) | 0x1F)
        header[6] = 0xFC
        header.append(rawAAC)
        return header
    }
}
