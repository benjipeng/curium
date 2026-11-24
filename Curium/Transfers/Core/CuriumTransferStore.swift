import Darwin
import Foundation
import OSLog
import SQLite3
import UIKit

/// Errors thrown when initializing or writing to `CuriumTransferStore`.
enum CuriumTransferStoreError: LocalizedError, Sendable {
    case openFailed(code: Int32, message: String)
    case statementFailed(code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let code, let message):
            return "Failed to open transfer database (SQLite \(code)): \(message)"
        case .statementFailed(let code, let message):
            return "Transfer database operation failed (SQLite \(code)): \(message)"
        }
    }
}

/// Durable SQLite3 WAL transfer store at `<PersistentSupportRoot>/Transfers/transfers.sqlite3`.
/// Hardened against iOS/LiveContainer `0xdead10cc` via inode-tracked
/// `com.apple.runningboard.can-suspend-locked` xattr stamping and background
/// `SQLITE_CHECKPOINT_TRUNCATE` flushes.
actor CuriumTransferStore {
    static let defaultPersistThrottleInterval: Duration = .seconds(3)
    private static let suspendLockedXattrName = "com.apple.runningboard.can-suspend-locked"
    private static let log = Logger(subsystem: "com.appautomaton.curium", category: "transfers.store")

    nonisolated(unsafe) private let db: OpaquePointer?
    nonisolated(unsafe) private var upsertStmt: OpaquePointer?
    nonisolated(unsafe) private var lifecycleObserverTokens: [NSObjectProtocol] = []

    let databaseURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var protectedInodes: [String: UInt64] = [:]
    private var lastPersistedAtByID: [String: ContinuousClock.Instant] = [:]
    private var lastPersistedPhaseByID: [String: CuriumTransferPhase] = [:]

    /// Default persistent SQLite database path under Curium's LiveContainer-safe Application Support root.
    nonisolated static func defaultDatabaseURL() throws -> URL {
        let supportRoot = try CuriumLibraryLocation.supportRootDirectory()
        return supportRoot
            .appending(path: "Transfers", directoryHint: .isDirectory)
            .appending(path: "transfers.sqlite3", directoryHint: .notDirectory)
    }

    /// Durable staging directory (`<SupportRoot>/Transfers/Staging/`) excluded from iCloud/iTunes backup
    /// and immune to iOS `Caches/` purging.
    nonisolated static func defaultStagingRootURL() throws -> URL {
        let supportRoot = try CuriumLibraryLocation.supportRootDirectory()
        let transfersDir = supportRoot.appending(path: "Transfers", directoryHint: .isDirectory)
        let stagingRoot = transfersDir.appending(path: "Staging", directoryHint: .isDirectory)
        try ensureProtectedDirectory(at: transfersDir)
        try ensureProtectedDirectory(at: stagingRoot)
        var mutableStaging = stagingRoot
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableStaging.setResourceValues(values)
        return stagingRoot
    }

    /// Ensures a directory exists with Class C (`completeUntilFirstUserAuthentication`) data protection
    /// so background transfers and WAL writes remain accessible after screen lock.
    private nonisolated static func ensureProtectedDirectory(at url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try? fm.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    /// Stamps `com.apple.runningboard.can-suspend-locked` on a single file path so `runningboardd`
    /// will not terminate a suspended app with `0xdead10cc` while holding open descriptors or locks.
    nonisolated static func applySuspendLockedProtection(at path: String) {
        var flag: UInt8 = 1
        _ = path.withCString { cPath in
            setxattr(cPath, suspendLockedXattrName, &flag, MemoryLayout<UInt8>.size, 0, 0)
        }
    }

    init(
        databaseURL: URL? = nil,
        installLifecycleObservers: Bool = true
    ) throws {
        let resolvedURL = try (databaseURL ?? Self.defaultDatabaseURL()).standardizedFileURL
        self.databaseURL = resolvedURL

        try Self.ensureProtectedDirectory(at: resolvedURL.deletingLastPathComponent())

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = dec

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE
            | SQLITE_OPEN_READWRITE
            | SQLITE_OPEN_FULLMUTEX
            | SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION
        let rc = sqlite3_open_v2(resolvedURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            if let handle { sqlite3_close(handle) }
            throw CuriumTransferStoreError.openFailed(code: rc, message: msg)
        }
        self.db = handle

        _ = Self.stampWALSidecarAttributes(at: resolvedURL.path, existingInodes: [:], force: true)
        try Self.exec(handle, sql: "PRAGMA journal_mode = WAL;")
        try Self.exec(handle, sql: "PRAGMA auto_vacuum = INCREMENTAL;")
        try Self.exec(handle, sql: "PRAGMA synchronous = NORMAL;")
        try Self.exec(handle, sql: "PRAGMA busy_timeout = 5000;")
        try Self.exec(handle, sql: "PRAGMA journal_size_limit = 8388608;")
        try Self.migrateSchemaIfNeeded(handle)

        let upsertSQL = """
            INSERT INTO curium_transfers (
                id,
                source_profile_id,
                phase,
                transport_kind,
                source,
                filename,
                received_bytes,
                total_bytes,
                created_at,
                updated_at,
                completed_at,
                slices_json,
                hls_checkpoint_json,
                record_json
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
            ON CONFLICT(id) DO UPDATE SET
                source_profile_id = excluded.source_profile_id,
                phase = excluded.phase,
                transport_kind = excluded.transport_kind,
                source = excluded.source,
                filename = excluded.filename,
                received_bytes = excluded.received_bytes,
                total_bytes = excluded.total_bytes,
                updated_at = excluded.updated_at,
                completed_at = excluded.completed_at,
                slices_json = excluded.slices_json,
                hls_checkpoint_json = excluded.hls_checkpoint_json,
                record_json = excluded.record_json;
            """
        var prepared: OpaquePointer?
        let prepRC = sqlite3_prepare_v2(handle, upsertSQL, -1, &prepared, nil)
        guard prepRC == SQLITE_OK, let prepared else {
            let msg = String(cString: sqlite3_errmsg(handle))
            sqlite3_close_v2(handle)
            throw CuriumTransferStoreError.statementFailed(code: prepRC, message: msg)
        }
        self.upsertStmt = prepared

        self.protectedInodes = Self.stampWALSidecarAttributes(at: resolvedURL.path, existingInodes: [:], force: true)
        if installLifecycleObservers {
            self.lifecycleObserverTokens = Self.installObservers(for: self)
        }
    }

    deinit {
        for token in lifecycleObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        if let upsertStmt {
            sqlite3_finalize(upsertStmt)
        }
        if let db {
            _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
            sqlite3_close_v2(db)
        }
    }

    // MARK: - CRUD & Launch Recovery

    /// Loads all persisted transfer records ordered by most recently updated first (`updated_at DESC`).
    func loadAll() -> [CuriumTransferRecord] {
        guard let db else { return [] }
        let sql = """
            SELECT record_json, slices_json, hls_checkpoint_json
            FROM curium_transfers
            ORDER BY updated_at DESC, created_at DESC;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var records: [CuriumTransferRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let decoded = decodeRow(stmt) {
                records.append(decoded)
            }
        }
        return records
    }

    /// Loads a single persisted transfer record by identifier.
    func record(id: String) -> CuriumTransferRecord? {
        guard let db else { return nil }
        let sql = """
            SELECT record_json, slices_json, hls_checkpoint_json
            FROM curium_transfers
            WHERE id = ?1;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id, -1, Self.sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return decodeRow(stmt)
    }

    /// Immediately persists or updates a transfer record in SQLite WAL.
    func upsert(_ record: CuriumTransferRecord) {
        let normalized = record.normalizedForPersistence()
        guard let stmt = upsertStmt else { return }
        guard let encoded = encodeRecordComponents(normalized) else { return }

        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }

        bindUpsertStatement(stmt, record: normalized, encoded: encoded)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE, let db {
            let msg = String(cString: sqlite3_errmsg(db))
            Self.log.error("Transfer upsert failed (SQLite \(rc)): \(msg, privacy: .public)")
        }

        lastPersistedPhaseByID[normalized.id] = normalized.phase
        ensureWALSidecarProtection(force: false)
    }

    /// Persists immediately on phase transitions or terminal/non-active states, and throttles
    /// active progress ticks to `minInterval` (default `3.0s`). Returns `true` when written.
    @discardableResult
    func upsertThrottled(
        _ record: CuriumTransferRecord,
        minInterval: Duration = CuriumTransferStore.defaultPersistThrottleInterval,
        now: ContinuousClock.Instant = .now,
        force: Bool = false
    ) -> Bool {
        let normalized = record.normalizedForPersistence()
        let previousPhase = lastPersistedPhaseByID[normalized.id]
        let isPhaseTransition = previousPhase != normalized.phase
        let isIntervalDue: Bool
        if let lastWritten = lastPersistedAtByID[normalized.id] {
            isIntervalDue = lastWritten.duration(to: now) >= minInterval
        } else {
            isIntervalDue = true
        }

        guard force || !normalized.phase.isActive || isPhaseTransition || isIntervalDue else {
            return false
        }

        upsert(normalized)
        lastPersistedAtByID[normalized.id] = now
        lastPersistedPhaseByID[normalized.id] = normalized.phase
        return true
    }

    /// Deletes a transfer record from SQLite.
    func delete(id: String) {
        guard let db else { return }
        let sql = "DELETE FROM curium_transfers WHERE id = ?1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id, -1, Self.sqliteTransient)
        _ = sqlite3_step(stmt)
        lastPersistedAtByID.removeValue(forKey: id)
        lastPersistedPhaseByID.removeValue(forKey: id)
        ensureWALSidecarProtection(force: false)
    }

    /// Transitions any interrupted `.probing`, `.downloading`, `.remuxing`, `.saving`, or `.queued`
    /// transfer left over from a prior process cleanly to `.paused` with `activeLanes = 0`,
    /// preserving exact byte-range `slices` and `hlsCheckpoint` progress.
    /// Returns the number of records transitioned to `.paused`.
    @discardableResult
    func markInterruptedTransfersPausedOnLaunch() -> Int {
        guard let db else { return 0 }
        let all = loadAll()
        var updates: [CuriumTransferRecord] = []

        for var record in all where record.phase.pausesOnColdLaunch {
            record.phase = .paused
            record.activeLanes = 0
            for idx in record.slices.indices {
                record.slices[idx].isActiveLane = false
            }
            updates.append(record)
        }

        guard !updates.isEmpty else {
            ensureWALSidecarProtection(force: false)
            return 0
        }

        _ = try? Self.exec(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        if let stmt = upsertStmt {
            for updated in updates {
                guard let encoded = encodeRecordComponents(updated) else { continue }
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindUpsertStatement(stmt, record: updated, encoded: encoded)
                _ = sqlite3_step(stmt)
                lastPersistedPhaseByID[updated.id] = .paused
            }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        _ = try? Self.exec(db, sql: "COMMIT;")
        ensureWALSidecarProtection(force: false)
        return updates.count
    }

    /// Truncates the SQLite WAL cleanly into the main database file and re-stamps
    /// `com.apple.runningboard.can-suspend-locked` on `.sqlite3`, `-wal`, and `-shm`.
    @discardableResult
    func checkpointTruncate() -> Bool {
        guard let db else { return false }
        if let upsertStmt {
            sqlite3_reset(upsertStmt)
            sqlite3_clear_bindings(upsertStmt)
        }
        var logFrames: Int32 = 0
        var checkpointedFrames: Int32 = 0
        let rc = sqlite3_wal_checkpoint_v2(
            db,
            nil,
            SQLITE_CHECKPOINT_TRUNCATE,
            &logFrames,
            &checkpointedFrames
        )
        if rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
            _ = sqlite3_wal_checkpoint_v2(
                db,
                nil,
                SQLITE_CHECKPOINT_PASSIVE,
                &logFrames,
                &checkpointedFrames
            )
        }
        ensureWALSidecarProtection(force: true)
        return rc == SQLITE_OK
    }

    // MARK: - Private SQLite Helpers

    private struct EncodedRecord {
        let recordJSON: Data
        let slicesJSON: Data
        let hlsCheckpointJSON: Data?
    }

    private func encodeRecordComponents(_ record: CuriumTransferRecord) -> EncodedRecord? {
        guard let slicesJSON = try? encoder.encode(record.slices) else { return nil }
        let hlsJSON: Data?
        if let checkpoint = record.hlsCheckpoint {
            guard let encodedCheckpoint = try? encoder.encode(checkpoint) else { return nil }
            hlsJSON = encodedCheckpoint
        } else {
            hlsJSON = nil
        }

        // Store slices and hlsCheckpoint exclusively in their dedicated columns to avoid doubling blob size.
        var shell = record
        shell.slices = []
        shell.hlsCheckpoint = nil
        guard let recordJSON = try? encoder.encode(shell) else { return nil }

        return EncodedRecord(
            recordJSON: recordJSON,
            slicesJSON: slicesJSON,
            hlsCheckpointJSON: hlsJSON
        )
    }

    private func decodeRow(_ stmt: OpaquePointer) -> CuriumTransferRecord? {
        let recordBytes = Int(sqlite3_column_bytes(stmt, 0))
        guard recordBytes > 0, let recordPtr = sqlite3_column_blob(stmt, 0) else { return nil }
        let recordData = Data(bytes: recordPtr, count: recordBytes)
        guard var record = try? decoder.decode(CuriumTransferRecord.self, from: recordData) else {
            return nil
        }

        let slicesBytes = Int(sqlite3_column_bytes(stmt, 1))
        if slicesBytes > 0, let slicesPtr = sqlite3_column_blob(stmt, 1) {
            let slicesData = Data(bytes: slicesPtr, count: slicesBytes)
            if let slices = try? decoder.decode([CuriumByteRangeSlice].self, from: slicesData) {
                record.slices = slices
            }
        }

        if sqlite3_column_type(stmt, 2) != SQLITE_NULL {
            let hlsBytes = Int(sqlite3_column_bytes(stmt, 2))
            if hlsBytes > 0, let hlsPtr = sqlite3_column_blob(stmt, 2) {
                let hlsData = Data(bytes: hlsPtr, count: hlsBytes)
                record.hlsCheckpoint = try? decoder.decode(CuriumHLSCheckpoint.self, from: hlsData)
            }
        }

        return record
    }

    private func bindUpsertStatement(
        _ stmt: OpaquePointer,
        record: CuriumTransferRecord,
        encoded: EncodedRecord
    ) {
        sqlite3_bind_text(stmt, 1, record.id, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 2, record.sourceProfileID, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 3, record.phase.rawValue, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 4, record.transportKind.rawValue, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 5, record.source.rawValue, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 6, record.filename, -1, Self.sqliteTransient)
        sqlite3_bind_int64(stmt, 7, record.receivedBytes)

        if let totalBytes = record.totalBytes {
            sqlite3_bind_int64(stmt, 8, totalBytes)
        } else {
            sqlite3_bind_null(stmt, 8)
        }

        sqlite3_bind_double(stmt, 9, record.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 10, record.updatedAt.timeIntervalSince1970)

        if let completedAt = record.completedAt {
            sqlite3_bind_double(stmt, 11, completedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 11)
        }

        Self.bindBlob(encoded.slicesJSON, to: stmt, index: 12)
        if let hlsJSON = encoded.hlsCheckpointJSON {
            Self.bindBlob(hlsJSON, to: stmt, index: 13)
        } else {
            sqlite3_bind_null(stmt, 13)
        }
        Self.bindBlob(encoded.recordJSON, to: stmt, index: 14)
    }

    private static func bindBlob(_ data: Data, to stmt: OpaquePointer, index: Int32) {
        if data.isEmpty {
            sqlite3_bind_zeroblob(stmt, index, 0)
            return
        }
        _ = data.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(stmt, index, rawBuffer.baseAddress, Int32(rawBuffer.count), sqliteTransient)
        }
    }

    private static var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private static func migrateSchemaIfNeeded(_ db: OpaquePointer) throws {
        var version: Int32 = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK,
           let stmt,
           sqlite3_step(stmt) == SQLITE_ROW {
            version = sqlite3_column_int(stmt, 0)
        }
        sqlite3_finalize(stmt)

        if version < 1 {
            try exec(db, sql: """
                BEGIN IMMEDIATE TRANSACTION;
                CREATE TABLE IF NOT EXISTS curium_transfers (
                    id TEXT PRIMARY KEY NOT NULL,
                    source_profile_id TEXT NOT NULL,
                    phase TEXT NOT NULL,
                    transport_kind TEXT NOT NULL,
                    source TEXT NOT NULL,
                    filename TEXT NOT NULL,
                    received_bytes INTEGER NOT NULL,
                    total_bytes INTEGER,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    completed_at REAL,
                    slices_json BLOB NOT NULL,
                    hls_checkpoint_json BLOB,
                    record_json BLOB NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_curium_transfers_updated
                    ON curium_transfers(updated_at DESC);
                PRAGMA user_version = 1;
                COMMIT;
                """)
        }
    }

    private func ensureWALSidecarProtection(force: Bool) {
        protectedInodes = Self.stampWALSidecarAttributes(
            at: databaseURL.path,
            existingInodes: protectedInodes,
            force: force
        )
    }

    private static func stampWALSidecarAttributes(
        at databasePath: String,
        existingInodes: [String: UInt64],
        force: Bool
    ) -> [String: UInt64] {
        var updated = existingInodes
        let candidates = [databasePath, databasePath + "-wal", databasePath + "-shm"]
        var flag: UInt8 = 1

        for candidate in candidates {
            var st = Darwin.stat()
            let exists = candidate.withCString { Darwin.lstat($0, &st) == 0 }
            guard exists else {
                updated.removeValue(forKey: candidate)
                continue
            }
            let inode = UInt64(st.st_ino)
            if force || updated[candidate] != inode {
                _ = candidate.withCString { cPath in
                    setxattr(cPath, suspendLockedXattrName, &flag, MemoryLayout<UInt8>.size, 0, 0)
                }
                updated[candidate] = inode
            }
        }
        return updated
    }

    private static func exec(_ db: OpaquePointer, sql: String) throws {
        var errPtr: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errPtr)
        if rc != SQLITE_OK {
            let msg = errPtr.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let errPtr { sqlite3_free(errPtr) }
            throw CuriumTransferStoreError.statementFailed(code: rc, message: msg)
        }
    }

    private static func installObservers(for store: CuriumTransferStore) -> [NSObjectProtocol] {
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
        ]
        return names.map { name in
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak store] _ in
                guard let store else { return }
                MainActor.assumeIsolated {
                    let bgGuard = CuriumTransferStoreBackgroundGuard(name: "Curium.TransferStore.WALCheckpoint")
                    Task.detached(priority: .userInitiated) {
                        await store.checkpointTruncate()
                        await bgGuard.end()
                    }
                }
            }
        }
    }
}

@MainActor
private final class CuriumTransferStoreBackgroundGuard {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.end()
                }
            } else {
                Task { @MainActor in
                    self?.end()
                }
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        let id = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }
}
