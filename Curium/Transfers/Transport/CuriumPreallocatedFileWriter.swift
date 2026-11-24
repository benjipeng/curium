import Darwin
import Foundation

/// Errors thrown by `CuriumPreallocatedFileWriter`.
enum CuriumPreallocatedFileWriterError: LocalizedError, Sendable, Equatable {
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case fileClosed
    case invalidOffset(Int64)
    case invalidLength(Int64)

    var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace(let required, let available):
            let reqStr = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            let availStr = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Not enough free storage space (requires \(reqStr), \(availStr) available)."
        case .fileClosed:
            return "Cannot modify a closed staging file."
        case .invalidOffset(let offset):
            return "Invalid negative file write offset (\(offset))."
        case .invalidLength(let length):
            return "Invalid negative file truncate length (\(length))."
        }
    }
}

/// Thread-safe random-access staging file writer backed by a single POSIX file descriptor.
///
/// Reserves disk blocks with `fcntl(F_PREALLOCATE)` + `ftruncate()`, stamps
/// `com.apple.runningboard.can-suspend-locked` against iOS `0xdead10cc`, and allows
/// lock-free concurrent `Darwin.pwrite` calls across disjoint byte ranges.
final class CuriumPreallocatedFileWriter: @unchecked Sendable {
    static let minimumSafetyHeadroomBytes: Int64 = 16 * 1024 * 1024

    let fileURL: URL
    private let fd: Int32
    private let ioCondition = NSCondition()
    private var isClosingOrClosed = false
    private var didCloseFD = false
    private var activeIOCount = 0

    init(fileURL: URL, preallocateBytes: Int64?, truncateExisting: Bool) throws {
        self.fileURL = fileURL
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )

        if let totalBytes = preallocateBytes, totalBytes > 0 {
            try Self.preflightDiskSpace(
                for: fileURL,
                parentDirectory: parent,
                targetBytes: totalBytes,
                truncateExisting: truncateExisting
            )
        }

        var openFlags = O_CREAT | O_RDWR | O_CLOEXEC
        if truncateExisting {
            openFlags |= O_TRUNC
        }

        let descriptor = fileURL.path.withCString { cPath in
            Darwin.open(cPath, openFlags, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.fd = descriptor

        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
        CuriumTransferStore.applySuspendLockedProtection(at: fileURL.path)

        if let totalBytes = preallocateBytes, totalBytes > 0 {
            var currentStat = stat()
            let existingSize: Int64 = fstat(descriptor, &currentStat) == 0 ? Int64(currentStat.st_size) : 0
            if truncateExisting || existingSize != totalBytes {
                let bytesToReserve = truncateExisting ? totalBytes : max(0, totalBytes - existingSize)
                if bytesToReserve > 0 {
                    var store = fstore_t(
                        fst_flags: UInt32(F_ALLOCATECONTIG | F_ALLOCATEALL),
                        fst_posmode: F_PEOFPOSMODE,
                        fst_offset: 0,
                        fst_length: off_t(bytesToReserve),
                        fst_bytesalloc: 0
                    )
                    if fcntl(descriptor, F_PREALLOCATE, &store) == -1 {
                        store.fst_flags = UInt32(F_ALLOCATEALL)
                        _ = fcntl(descriptor, F_PREALLOCATE, &store)
                    }
                }
                while ftruncate(descriptor, off_t(totalBytes)) == -1 {
                    if errno == EINTR { continue }
                    let err = POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOSPC)
                    try? close()
                    throw err
                }
            }
        }
    }

    deinit {
        try? close()
    }

    /// Acquires an active-I/O guard around `fd` so concurrent `pwrite` calls run unlocked
    /// while guaranteeing `close()` waits for all in-flight syscalls before releasing the FD.
    private func withActiveFD<T>(_ body: (Int32) throws -> T) throws -> T {
        ioCondition.lock()
        guard !isClosingOrClosed else {
            ioCondition.unlock()
            throw CuriumPreallocatedFileWriterError.fileClosed
        }
        activeIOCount += 1
        ioCondition.unlock()

        defer {
            ioCondition.lock()
            activeIOCount -= 1
            if activeIOCount == 0 && isClosingOrClosed {
                ioCondition.broadcast()
            }
            ioCondition.unlock()
        }

        return try body(fd)
    }

    /// Positional write at `offset` (safe for concurrent callers targeting disjoint offsets).
    /// Handles partial POSIX writes and `EINTR`, and fails closed if the writer is closing/closed.
    func write(_ data: Data, at offset: Int64) throws {
        guard offset >= 0 else {
            throw CuriumPreallocatedFileWriterError.invalidOffset(offset)
        }

        try withActiveFD { activeFD in
            guard !data.isEmpty else { return }
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var remaining = rawBuffer.count
                var writtenSoFar = 0
                while remaining > 0 {
                    let ptr = base.advanced(by: writtenSoFar)
                    let rc = Darwin.pwrite(activeFD, ptr, remaining, off_t(offset) + off_t(writtenSoFar))
                    if rc < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    if rc == 0 {
                        throw POSIXError(.EIO)
                    }
                    writtenSoFar += rc
                    remaining -= rc
                }
            }
        }
    }

    /// Truncates or extends the staging file to `length` bytes (e.g., to snap to a clean resume boundary).
    func truncate(to length: Int64) throws {
        guard length >= 0 else {
            throw CuriumPreallocatedFileWriterError.invalidLength(length)
        }
        try withActiveFD { activeFD in
            while ftruncate(activeFD, off_t(length)) == -1 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    /// Returns the current on-disk file length in bytes.
    func currentFileSize() throws -> Int64 {
        try withActiveFD { activeFD in
            var st = stat()
            guard fstat(activeFD, &st) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return Int64(st.st_size)
        }
    }

    /// Flushes dirty kernel page buffers to durable storage (`fsync`).
    func synchronize() throws {
        ioCondition.lock()
        guard !isClosingOrClosed else {
            ioCondition.unlock()
            return
        }
        activeIOCount += 1
        ioCondition.unlock()

        defer {
            ioCondition.lock()
            activeIOCount -= 1
            if activeIOCount == 0 && isClosingOrClosed {
                ioCondition.broadcast()
            }
            ioCondition.unlock()
        }

        while fsync(fd) == -1 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Flushes dirty buffers (`fsync`) and closes the file descriptor.
    func finalize() throws {
        try synchronize()
        try close()
    }

    /// Idempotently closes the underlying file descriptor after draining any active I/O calls.
    func close() throws {
        ioCondition.lock()
        isClosingOrClosed = true
        while activeIOCount > 0 {
            ioCondition.wait()
        }
        guard !didCloseFD else {
            ioCondition.unlock()
            return
        }
        didCloseFD = true
        let descriptorToClose = fd
        ioCondition.unlock()

        if Darwin.close(descriptorToClose) == -1 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func preflightDiskSpace(
        for fileURL: URL,
        parentDirectory: URL,
        targetBytes: Int64,
        truncateExisting: Bool
    ) throws {
        var existingSize: Int64 = 0
        if !truncateExisting,
           let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let sizeNumber = attrs[.size] as? NSNumber {
            existingSize = max(0, sizeNumber.int64Value)
        }
        let additionalNeeded = max(0, targetBytes - existingSize)
        guard additionalNeeded > 0 else { return }

        let availableBytes = availableVolumeCapacityBytes(at: parentDirectory)
        if let available = availableBytes,
           available < additionalNeeded + minimumSafetyHeadroomBytes {
            throw CuriumPreallocatedFileWriterError.insufficientDiskSpace(
                requiredBytes: additionalNeeded,
                availableBytes: available
            )
        }
    }

    private static func availableVolumeCapacityBytes(at directory: URL) -> Int64? {
        if let values = try? directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]) {
            if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
                return important
            }
            if let standard = values.volumeAvailableCapacity, standard > 0 {
                return Int64(standard)
            }
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: directory.path),
           let free = attrs[.systemFreeSize] as? NSNumber,
           free.int64Value > 0 {
            return free.int64Value
        }
        return nil
    }
}
