import AVFoundation
import CoreMedia
import Foundation

public enum CuriumMediaMuxError: LocalizedError, Equatable, Sendable {
    case unableToCreatePassthroughExporter
    case noPlayableTracks
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unableToCreatePassthroughExporter:
            return "Unable to create AVAssetExportSession passthrough muxer."
        case .noPlayableTracks:
            return "No playable video or audio tracks were found for muxing."
        case .exportFailed(let reason):
            return "MP4 passthrough muxing failed: \(reason)"
        }
    }
}

/// Serialized pure-native media post-processing actor.
///
/// Handles all lossless MP4 packaging paths with zero external binaries:
/// - Single-track ISO-BMFF fMP4 -> fast atomic move to `.mp4`
/// - Single-track MPEG-TS -> 2-pass zero-copy mmap `CuriumNativeMP4Remuxer` -> `.mp4`
/// - Split video + separate audio (fMP4, MPEG-TS, or raw ADTS AAC) -> pre-remuxing TS tracks
///   via `CuriumNativeMP4Remuxer` when needed, then lossless `AVMutableComposition` +
///   `AVAssetExportSession(presetName: AVAssetExportPresetPassthrough)` -> `.mp4`.
public actor CuriumMediaMuxActor {
    public static let shared = CuriumMediaMuxActor()

    public init() {}

    /// Losslessly converts a single staged media stream (`fMP4` or `MPEG-TS`) into a playable `.mp4`
    /// at `destinationURL`.
    ///
    /// - Returns: `true` if the stream required MPEG-TS -> MP4 remuxing, or `false` if it was
    ///   already an ISO-BMFF container and fast-moved in place.
    @discardableResult
    public func remuxSingleStreamToMP4(sourceURL: URL, destinationURL: URL) async throws -> Bool {
        try Task.checkCancellation()

        let fm = FileManager.default
        let destinationDir = destinationURL.deletingLastPathComponent()
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        if CuriumNativeMP4Remuxer.isISOBaseMediaFile(at: sourceURL) {
            if sourceURL.standardizedFileURL != destinationURL.standardizedFileURL {
                try? fm.removeItem(at: destinationURL)
                try fm.moveItem(at: sourceURL, to: destinationURL)
            }
            return false
        }

        let tempOutputURL = destinationDir.appending(
            path: ".curium-remux-\(UUID().uuidString).mp4",
            directoryHint: .notDirectory
        )
        defer { try? fm.removeItem(at: tempOutputURL) }

        try await CuriumNativeMP4Remuxer.remuxMPEGTS(from: sourceURL, to: tempOutputURL)
        try Task.checkCancellation()

        try? fm.removeItem(at: destinationURL)
        try fm.moveItem(at: tempOutputURL, to: destinationURL)
        return true
    }

    /// Losslessly muxes separate video and audio track files into a unified fast-start `.mp4`
    /// container without re-encoding.
    ///
    /// Automatically pre-remuxes MPEG-TS inputs via `CuriumNativeMP4Remuxer` and normalizes
    /// staging file extensions (such as `.part`) via hard links so `AVURLAsset` and
    /// `AVMutableComposition` always recognize the container format.
    public func remux(videoURL: URL, audioURL: URL, destinationURL: URL) async throws {
        try Task.checkCancellation()

        let fm = FileManager.default
        let destinationDir = destinationURL.deletingLastPathComponent()
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let scratchDir = destinationDir.appending(
            path: ".curium-mux-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fm.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratchDir) }

        let preparedVideoURL = try await prepareCompositionInput(
            sourceURL: videoURL,
            role: .video,
            scratchDir: scratchDir
        )
        try Task.checkCancellation()

        let preparedAudioURL = try await prepareCompositionInput(
            sourceURL: audioURL,
            role: .audio,
            scratchDir: scratchDir
        )
        try Task.checkCancellation()

        let tempOutputURL = scratchDir.appending(path: "muxed.mp4", directoryHint: .notDirectory)
        try await passthroughAVFoundationMux(
            videoURL: preparedVideoURL,
            audioURL: preparedAudioURL,
            destinationURL: tempOutputURL
        )
        try Task.checkCancellation()

        try? fm.removeItem(at: destinationURL)
        try fm.moveItem(at: tempOutputURL, to: destinationURL)
    }

    // MARK: - Internal Helpers

    private enum TrackRole {
        case video
        case audio
    }

    private func prepareCompositionInput(
        sourceURL: URL,
        role: TrackRole,
        scratchDir: URL
    ) async throws -> URL {
        let fm = FileManager.default

        if CuriumNativeMP4Remuxer.isISOBaseMediaFile(at: sourceURL) {
            let ext = sourceURL.pathExtension.lowercased()
            let acceptedExts: Set<String> = role == .video ? ["mp4", "m4v", "mov"] : ["mp4", "m4a", "mov"]
            if acceptedExts.contains(ext) {
                return sourceURL
            }
            let aliasExt = role == .video ? "mp4" : "m4a"
            let aliasURL = scratchDir.appending(path: "\(role)-input.\(aliasExt)", directoryHint: .notDirectory)
            try linkOrCopy(from: sourceURL, to: aliasURL, fileManager: fm)
            return aliasURL
        }

        if CuriumNativeMP4Remuxer.isTransportStreamFile(at: sourceURL) {
            let remuxedURL = scratchDir.appending(path: "\(role)-remuxed.mp4", directoryHint: .notDirectory)
            try await CuriumNativeMP4Remuxer.remuxMPEGTS(from: sourceURL, to: remuxedURL)
            return remuxedURL
        }

        // Raw ADTS AAC / ID3-prefixed AAC audio renditions (common in HLS audio-only playlists)
        if role == .audio, Self.looksLikeADTSOrID3Audio(at: sourceURL) {
            if sourceURL.pathExtension.lowercased() == "aac" {
                return sourceURL
            }
            let aliasURL = scratchDir.appending(path: "audio-input.aac", directoryHint: .notDirectory)
            try linkOrCopy(from: sourceURL, to: aliasURL, fileManager: fm)
            return aliasURL
        }

        // Fallback: try MPEG-TS remuxer first if container is unrecognized, otherwise let AVURLAsset inspect it.
        if sourceURL.pathExtension.lowercased() == "ts" {
            let remuxedURL = scratchDir.appending(path: "\(role)-remuxed.mp4", directoryHint: .notDirectory)
            try await CuriumNativeMP4Remuxer.remuxMPEGTS(from: sourceURL, to: remuxedURL)
            return remuxedURL
        }
        return sourceURL
    }

    private func linkOrCopy(from sourceURL: URL, to destinationURL: URL, fileManager: FileManager) throws {
        try? fileManager.removeItem(at: destinationURL)
        do {
            try fileManager.linkItem(at: sourceURL, to: destinationURL)
        } catch {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
    }

    private static func looksLikeADTSOrID3Audio(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 16), header.count >= 3 else {
            return false
        }
        if header[0] == 0x49 && header[1] == 0x44 && header[2] == 0x33 {
            return true // "ID3"
        }
        if header[0] == 0xFF && (header[1] & 0xF0) == 0xF0 {
            return true // ADTS syncword
        }
        return false
    }

    private func passthroughAVFoundationMux(
        videoURL: URL,
        audioURL: URL,
        destinationURL: URL
    ) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)

        let effectiveDuration: CMTime = {
            let videoValid = videoDuration.isNumeric && videoDuration.seconds > 0
            let audioValid = audioDuration.isNumeric && audioDuration.seconds > 0
            if videoValid && audioValid {
                return CMTimeMinimum(videoDuration, audioDuration)
            }
            if videoValid {
                return videoDuration
            }
            return audioDuration
        }()

        var insertedTrackCount = 0

        if let srcVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
           let compVideo = composition.addMutableTrack(
               withMediaType: .video,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let trackDuration = (effectiveDuration.isNumeric && effectiveDuration.seconds > 0)
                ? effectiveDuration
                : videoDuration
            try compVideo.insertTimeRange(
                CMTimeRange(start: .zero, duration: trackDuration),
                of: srcVideo,
                at: .zero
            )
            compVideo.preferredTransform = try await srcVideo.load(.preferredTransform)
            insertedTrackCount += 1
        }

        if let srcAudio = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let compAudio = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let trackDuration = (effectiveDuration.isNumeric && effectiveDuration.seconds > 0)
                ? effectiveDuration
                : audioDuration
            try compAudio.insertTimeRange(
                CMTimeRange(start: .zero, duration: trackDuration),
                of: srcAudio,
                at: .zero
            )
            insertedTrackCount += 1
        }

        guard insertedTrackCount > 0 else {
            throw CuriumMediaMuxError.noPlayableTracks
        }

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw CuriumMediaMuxError.unableToCreatePassthroughExporter
        }
        exporter.shouldOptimizeForNetworkUse = true

        do {
            try await exporter.export(to: destinationURL, as: .mp4)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CuriumMediaMuxError.exportFailed(error.localizedDescription)
        }
    }
}
