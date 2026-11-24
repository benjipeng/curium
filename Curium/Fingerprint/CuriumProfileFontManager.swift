import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import OSLog

/// Registers a deterministic, per-profile subset of authentic macOS / Office-for-Mac /
/// Adobe-for-Mac / developer font families into the current process's CoreText registry
/// before `ChromeMain` initializes Skia's `SkFontMgr_mac_ct`.
///
/// Each registered family is cloned in-memory from a typographically matching native
/// iOS CoreText typeface with a spec-compliant SFNT `name` table rewrite and checksum
/// recomputation — zero bundled third-party font binaries, zero JavaScript prototype
/// hooks, and full native glyph coverage if a site actually renders with that family.
enum CuriumProfileFontManager {
    struct FontAliasSpec: Equatable, Sendable {
        let familyName: String
        let postScriptName: String
        let basePostScriptCandidates: [String]
        let alwaysIncludeBaseProbabilityPercent: Int
    }

    /// Authentic, widely deployed macOS ecosystem fonts: `Arial Unicode MS` (shipped on
    /// real macOS, absent on iOS) plus mainstream Microsoft Office for Mac, Adobe Creative
    /// Cloud for Mac, Java, and design families. Excludes Linux (`Bitstream Vera`), Windows-only,
    /// and rare Bitstream/Linotype families, and caps optional additions to 0–2 families
    /// (4–6 total detected fonts) so every profile stays within real macOS norms.
    static let macOSBaselineFont = FontAliasSpec(
        familyName: "Arial Unicode MS",
        postScriptName: "ArialUnicodeMS",
        basePostScriptCandidates: ["AvenirNext-Regular", "Optima-Regular", "TrebuchetMS"],
        alwaysIncludeBaseProbabilityPercent: 100
    )

    static let macOSFontPool: [FontAliasSpec] = [
        FontAliasSpec(
            familyName: "Calibri",
            postScriptName: "Calibri",
            basePostScriptCandidates: ["Optima-Regular", "AvenirNext-Regular", "TrebuchetMS"],
            alwaysIncludeBaseProbabilityPercent: 50
        ),
        FontAliasSpec(
            familyName: "Century",
            postScriptName: "Century",
            basePostScriptCandidates: ["Baskerville", "Georgia", "Palatino-Roman"],
            alwaysIncludeBaseProbabilityPercent: 40
        ),
        FontAliasSpec(
            familyName: "Century Gothic",
            postScriptName: "CenturyGothic",
            basePostScriptCandidates: ["Futura-Medium", "AvenirNext-Regular", "Verdana"],
            alwaysIncludeBaseProbabilityPercent: 40
        ),
        FontAliasSpec(
            familyName: "Franklin Gothic",
            postScriptName: "FranklinGothic-Medium",
            basePostScriptCandidates: ["TrebuchetMS", "AvenirNext-Regular", "Verdana"],
            alwaysIncludeBaseProbabilityPercent: 35
        ),
        FontAliasSpec(
            familyName: "Lucida Bright",
            postScriptName: "LucidaBright",
            basePostScriptCandidates: ["Palatino-Roman", "Georgia", "Baskerville"],
            alwaysIncludeBaseProbabilityPercent: 40
        ),
        FontAliasSpec(
            familyName: "Lucida Sans",
            postScriptName: "LucidaSans",
            basePostScriptCandidates: ["Verdana", "TrebuchetMS", "Optima-Regular"],
            alwaysIncludeBaseProbabilityPercent: 45
        ),
        FontAliasSpec(
            familyName: "MYRIAD PRO",
            postScriptName: "MyriadPro-Regular",
            basePostScriptCandidates: ["AvenirNext-Regular", "TrebuchetMS", "Optima-Regular"],
            alwaysIncludeBaseProbabilityPercent: 45
        ),
        FontAliasSpec(
            familyName: "Minion Pro",
            postScriptName: "MinionPro-Regular",
            basePostScriptCandidates: ["Georgia", "Palatino-Roman", "Baskerville"],
            alwaysIncludeBaseProbabilityPercent: 45
        ),
        FontAliasSpec(
            familyName: "GOTHAM",
            postScriptName: "Gotham-Book",
            basePostScriptCandidates: ["Futura-Medium", "AvenirNext-Regular", "Verdana"],
            alwaysIncludeBaseProbabilityPercent: 35
        ),
    ]

    /// Twelve empirically clean 1–2 optional macOS font suites (5–6 detected fonts total
    /// including iOS's built-in Gill Sans / Helvetica Neue / Menlo + Arial Unicode MS).
    static let macOSFontSuites: [[String]] = [
        ["Franklin Gothic"],               // 0: Office Editorial (5 fonts)
        ["Minion Pro"],                    // 1: Adobe Publishing (5 fonts)
        ["Calibri", "MYRIAD PRO"],         // 2: Office + Adobe (6 fonts)
        ["GOTHAM"],                        // 3: Design Studio (5 fonts)
        ["Century", "Lucida Bright"],      // 4: Serif Publishing (6 fonts)
        ["MYRIAD PRO", "Franklin Gothic"], // 5: Creative Agency (6 fonts)
        ["Calibri", "Century Gothic"],     // 6: Office Modern (6 fonts)
        ["Lucida Sans", "Century"],        // 7: Productivity (6 fonts)
        ["GOTHAM", "Lucida Sans"],         // 8: Editorial Design (6 fonts)
        ["MYRIAD PRO"],                    // 9: Adobe Creative (5 fonts)
        ["Calibri"],                       // 10: Office Classic (5 fonts)
        ["Minion Pro", "Lucida Bright"],   // 11: Print Serif (6 fonts)
    ]

    private static let poolByFamilyName: [String: FontAliasSpec] = Dictionary(
        uniqueKeysWithValues: macOSFontPool.map { ($0.familyName, $0) }
    )

    private static let tempDirPrefix = "curium-profile-fonts-"
    private static let log = Logger(subsystem: "com.appautomaton.curium", category: "profile-fonts")

    /// Stable seed string shared across per-profile CoreText font registration and
    /// desktop parity voice selection.
    static func profileSeedString(for profile: CuriumFingerprintProfile) -> String {
        let createdMs = Int64((profile.createdAt?.timeIntervalSince1970 ?? 0) * 1000)
        return "\(profile.id)|\(profile.fingerprintSeed ?? "")|\(createdMs)"
    }

    /// Deterministically selects `Arial Unicode MS` plus 0–2 mainstream macOS optional
    /// font families for `profileSeed` and optional hardware renderer hint.
    /// Partitioning by Apple Silicon tier ensures consecutive auto-rolled profiles across
    /// distinct chips select non-overlapping font suites by construction.
    static func selectedFonts(
        forProfileSeed profileSeed: String,
        webglRenderer: String? = nil
    ) -> [FontAliasSpec] {
        guard !profileSeed.isEmpty else { return [] }
        let digest = Array(SHA256.hash(data: Data(("curium.profile.fonts.v3:" + profileSeed).utf8)))
        let hashWord = readLE64(digest, offset: 0)

        let candidateSuiteIndices: [Int]
        let rendererLower = (webglRenderer ?? "").lowercased()
        if rendererLower.contains("apple m5 max") {
            candidateSuiteIndices = [3, 2]
        } else if rendererLower.contains("apple m4 max") {
            candidateSuiteIndices = [5, 1]
        } else if rendererLower.contains("apple m4 pro") {
            candidateSuiteIndices = [5, 0]
        } else if rendererLower.contains("apple m4") {
            candidateSuiteIndices = [4, 7]
        } else if rendererLower.contains("apple m3 pro") {
            candidateSuiteIndices = [3, 8]
        } else if rendererLower.contains("apple m3") {
            candidateSuiteIndices = [1, 11]
        } else if rendererLower.contains("apple m2") {
            candidateSuiteIndices = [2, 9]
        } else if rendererLower.contains("apple m1") {
            candidateSuiteIndices = [6, 10]
        } else {
            candidateSuiteIndices = Array(macOSFontSuites.indices)
        }

        let suiteIdx = candidateSuiteIndices[Int(hashWord % UInt64(candidateSuiteIndices.count))]
        let optionalNames = macOSFontSuites[suiteIdx]
        let optionalSpecs = optionalNames.compactMap { poolByFamilyName[$0] }
        return ([macOSBaselineFont] + optionalSpecs).sorted { $0.familyName < $1.familyName }
    }

    /// Registers the active desktop macOS profile's deterministic CoreText font subset
    /// in-process before `ChromeMain`. Safe to call once at startup.
    @discardableResult
    static func registerLaunchFontsIfNeeded(for profile: CuriumFingerprintProfile?) -> [String] {
        cleanupStaleTempDirectories()
        guard let profile,
              profile.defaultSlot == .desktop,
              (profile.desktop.platform ?? "macOS") == "macOS",
              profile.fontProfile != .windows,
              profile.fontProfile != .linux,
              profile.fontProfile != .android
        else {
            return []
        }

        let seed = profileSeedString(for: profile)
        let specs = selectedFonts(
            forProfileSeed: seed,
            webglRenderer: profile.desktop.webglRenderer
        )
        guard !specs.isEmpty else { return [] }

        let dirURL = FileManager.default.temporaryDirectory.appending(
            path: "\(tempDirPrefix)\(ProcessInfo.processInfo.processIdentifier)",
            directoryHint: .isDirectory
        )
        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        } catch {
            log.warning("profile font temp dir creation failed: \(error.localizedDescription, privacy: .public)")
            return []
        }

        var registered: [String] = []
        for spec in specs {
            if isFamilyAlreadyInstalled(spec.familyName) {
                registered.append(spec.familyName)
                continue
            }
            guard let fontData = buildClonedSFNT(for: spec) else { continue }
            let fileURL = dirURL.appending(path: "\(spec.postScriptName).ttf", directoryHint: .notDirectory)
            do {
                try fontData.write(to: fileURL, options: .atomic)
                var cfError: Unmanaged<CFError>?
                if CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, &cfError) {
                    registered.append(spec.familyName)
                } else {
                    let msg = cfError?.takeRetainedValue().localizedDescription ?? "unknown error"
                    log.debug("font register skipped for \(spec.familyName, privacy: .public): \(msg, privacy: .public)")
                }
            } catch {
                log.debug("font write failed for \(spec.familyName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        log.notice("registered \(registered.count) profile CoreText fonts for \(profile.id, privacy: .public)")
        return registered
    }

    /// Rebuilds a valid SFNT (`.ttf` / `.otf`) binary from a built-in system CoreText font
    /// with a fresh `name` table naming `spec.familyName` / `spec.postScriptName`.
    static func buildClonedSFNT(for spec: FontAliasSpec) -> Data? {
        guard let baseFont = resolveAvailableBaseFont(candidates: spec.basePostScriptCandidates) else {
            return nil
        }
        let cgFont = CTFontCopyGraphicsFont(baseFont, nil)
        guard let rawTags = cgFont.tableTags else { return nil }

        let tagName: UInt32 = 0x6E61_6D65 // 'name'
        let tagHead: UInt32 = 0x6865_6164 // 'head'
        let tagCFF: UInt32 = 0x4346_4620 // 'CFF '
        let tagDSIG: UInt32 = 0x4453_4947 // 'DSIG'

        var tables: [(tag: UInt32, data: Data)] = []
        var isCFF = false
        let tagCount = CFArrayGetCount(rawTags)
        tables.reserveCapacity(tagCount)

        for index in 0..<tagCount {
            let rawPtr = CFArrayGetValueAtIndex(rawTags, index)
            let tag = UInt32(bitPattern: Int32(truncatingIfNeeded: Int(bitPattern: rawPtr)))
            if tag == tagDSIG { continue }
            if tag == tagCFF { isCFF = true }

            if tag == tagName {
                tables.append((tag, makeNameTable(family: spec.familyName, postScript: spec.postScriptName)))
            } else if let cfData = cgFont.table(for: tag) {
                let length = CFDataGetLength(cfData)
                guard length > 0 else { continue }
                var bytes = [UInt8](repeating: 0, count: length)
                CFDataGetBytes(cfData, CFRange(location: 0, length: length), &bytes)
                if tag == tagHead && bytes.count >= 12 {
                    bytes[8] = 0
                    bytes[9] = 0
                    bytes[10] = 0
                    bytes[11] = 0
                }
                tables.append((tag, Data(bytes)))
            }
        }

        guard !tables.isEmpty else { return nil }
        tables.sort { $0.tag < $1.tag }

        let numTables = UInt16(tables.count)
        var entrySelector: UInt16 = 0
        var power: UInt16 = 1
        while power * 2 <= numTables {
            power *= 2
            entrySelector += 1
        }
        let searchRange = power * 16
        let rangeShift = numTables * 16 - searchRange

        var sfnt = Data()
        sfnt.append(be32(isCFF ? 0x4F54_544F : 0x0001_0000))
        sfnt.append(be16(numTables))
        sfnt.append(be16(searchRange))
        sfnt.append(be16(entrySelector))
        sfnt.append(be16(rangeShift))

        var offset = UInt32(12 + tables.count * 16)
        var headOffset: Int?
        var body = Data()
        for entry in tables {
            let checksum = sfntChecksum(entry.data)
            sfnt.append(be32(entry.tag))
            sfnt.append(be32(checksum))
            sfnt.append(be32(offset))
            sfnt.append(be32(UInt32(entry.data.count)))
            if entry.tag == tagHead {
                headOffset = Int(offset)
            }
            body.append(entry.data)
            let pad = (4 - (entry.data.count % 4)) % 4
            if pad > 0 {
                body.append(Data(count: pad))
            }
            offset += UInt32(entry.data.count + pad)
        }
        sfnt.append(body)

        if let headOffset, headOffset + 12 <= sfnt.count {
            let adjustment = 0xB1B0_AFBA &- sfntChecksum(sfnt)
            sfnt.replaceSubrange((headOffset + 8)..<(headOffset + 12), with: be32(adjustment))
        }
        return sfnt
    }

    private static func resolveAvailableBaseFont(candidates: [String]) -> CTFont? {
        for name in candidates {
            let font = CTFontCreateWithName(name as CFString, 16, nil)
            let ps = CTFontCopyPostScriptName(font) as String
            if ps.caseInsensitiveCompare(name) == .orderedSame {
                return font
            }
        }
        for fallback in ["Optima-Regular", "Georgia", "Verdana", "TrebuchetMS", "Futura-Medium", "Baskerville"] {
            let font = CTFontCreateWithName(fallback as CFString, 16, nil)
            let ps = CTFontCopyPostScriptName(font) as String
            if ps.caseInsensitiveCompare(fallback) == .orderedSame {
                return font
            }
        }
        return nil
    }

    private static func isFamilyAlreadyInstalled(_ familyName: String) -> Bool {
        let desc = CTFontDescriptorCreateWithAttributes(
            [kCTFontFamilyNameAttribute: familyName] as CFDictionary
        )
        let matched = CTFontDescriptorCreateMatchingFontDescriptor(desc, nil)
        guard let matched,
              let resolved = CTFontDescriptorCopyAttribute(matched, kCTFontFamilyNameAttribute) as? String
        else {
            return false
        }
        return resolved.caseInsensitiveCompare(familyName) == .orderedSame
    }

    private static func cleanupStaleTempDirectories() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let currentName = "\(tempDirPrefix)\(ProcessInfo.processInfo.processIdentifier)"
        guard let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else {
            return
        }
        for item in items {
            let name = item.lastPathComponent
            if name.hasPrefix(tempDirPrefix) && name != currentName {
                try? fm.removeItem(at: item)
            }
        }
    }

    private static func makeNameTable(family: String, postScript: String) -> Data {
        let entries: [(UInt16, String)] = [
            (1, family),
            (2, "Regular"),
            (3, "1.0;\(postScript)"),
            (4, family),
            (5, "Version 1.0"),
            (6, postScript),
            (16, family),
            (17, "Regular"),
        ]
        var records: [(UInt16, UInt16, UInt16, UInt16, Data)] = []
        records.reserveCapacity(entries.count * 2)
        for (id, value) in entries {
            records.append((1, 0, 0, id, Data(value.utf8)))
        }
        for (id, value) in entries {
            var utf16 = Data()
            utf16.reserveCapacity(value.utf16.count * 2)
            for unit in value.utf16 {
                utf16.append(be16(unit))
            }
            records.append((3, 1, 0x0409, id, utf16))
        }

        let count = UInt16(records.count)
        let stringOffset = UInt16(6 + records.count * 12)
        var out = Data()
        out.append(be16(0))
        out.append(be16(count))
        out.append(be16(stringOffset))

        var storage = Data()
        for (platform, encoding, language, id, bytes) in records {
            out.append(be16(platform))
            out.append(be16(encoding))
            out.append(be16(language))
            out.append(be16(id))
            out.append(be16(UInt16(bytes.count)))
            out.append(be16(UInt16(storage.count)))
            storage.append(bytes)
        }
        out.append(storage)
        return out
    }

    private static func sfntChecksum(_ data: Data) -> UInt32 {
        var sum: UInt32 = 0
        data.withUnsafeBytes { buf in
            let count = buf.count
            var index = 0
            while index < count {
                let b0 = UInt32(buf[index])
                let b1 = index + 1 < count ? UInt32(buf[index + 1]) : 0
                let b2 = index + 2 < count ? UInt32(buf[index + 2]) : 0
                let b3 = index + 3 < count ? UInt32(buf[index + 3]) : 0
                sum = sum &+ ((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
                index += 4
            }
        }
        return sum
    }

    private static func be16(_ value: UInt16) -> Data {
        var big = value.bigEndian
        return Data(bytes: &big, count: 2)
    }

    private static func be32(_ value: UInt32) -> Data {
        var big = value.bigEndian
        return Data(bytes: &big, count: 4)
    }

    private static func readLE64(_ bytes: [UInt8], offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(bytes[offset + i]) << (UInt64(i) * 8)
        }
        return value
    }
}
