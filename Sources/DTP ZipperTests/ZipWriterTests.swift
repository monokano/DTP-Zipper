import XCTest
import zlib
@testable import DTP_Zipper

final class ZipWriterTests: XCTestCase {

    private var dir: URL!
    private let attributes = ZipEntryAttributes(modificationDate: Date(), posixPermissions: 0o644)
    private let cp932 = NameOptions(encoding: .cp932)
    private let utf8 = NameOptions(encoding: .utf8)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ZipWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - 補助

    private func makeFile(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func randomData(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    private func encoded(_ path: [String], _ options: NameOptions) throws -> EncodedName {
        try XCTUnwrap(NameEncoding.encoded(zipPath: NameEncoding.zipPath(path), options: options))
    }

    private func add(_ writer: ZipWriter, _ source: URL, _ path: [String], _ options: NameOptions, forceStored: Bool = false) throws {
        let size = try XCTUnwrap(source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        try writer.addFile(source: source, size: UInt64(size), name: encoded(path, options),
                           attributes: attributes, forceStored: forceStored)
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let outputURL = dir.appendingPathComponent("output-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        try handle.close()
        let output = try String(decoding: Data(contentsOf: outputURL), as: UTF8.self)
        try FileManager.default.removeItem(at: outputURL)
        return (process.terminationStatus, output)
    }

    /// `unzip -t`、`zipinfo`、Python `zipfile` で読めることを確認する。
    private func assertReadableByTools(_ zip: URL, line: UInt = #line) throws {
        let unzip = try run("/usr/bin/unzip", ["-t", zip.path])
        XCTAssertEqual(unzip.status, 0, unzip.output, line: line)
        let info = try run("/usr/bin/zipinfo", [zip.path])
        XCTAssertEqual(info.status, 0, info.output, line: line)
        let python = try run("/usr/bin/python3", ["-c", "import sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); r=z.testzip(); sys.exit(1 if r else 0)", zip.path])
        XCTAssertEqual(python.status, 0, python.output, line: line)
    }

    // MARK: - 形式

    func testCP932EntryFields() throws {
        let zipURL = dir.appendingPathComponent("a.zip")
        let content = Data(repeating: 0x41, count: 10_000)
        let source = try makeFile("src", content)
        let date = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2024, month: 3, day: 5, hour: 13, minute: 7, second: 41).date!
        let writer = try ZipWriter(url: zipURL)
        try writer.addFile(source: source, size: 10_000, name: encoded(["フォルダ", "表.txt"], cp932),
                           attributes: ZipEntryAttributes(modificationDate: date, posixPermissions: 0o444))
        try writer.finish()

        let archive = try ParsedZip(url: zipURL)
        let entry = try XCTUnwrap(archive.entries.first)
        XCTAssertEqual(entry.nameBytes, NameEncoding.cp932Bytes("フォルダ/表.txt"))
        XCTAssertEqual(entry.flags & (1 << 11), 0)
        XCTAssertEqual(entry.method, 8)
        XCTAssertEqual(entry.versionMadeBy, 3 << 8 | 20)
        XCTAssertEqual(entry.versionNeeded, 20)
        XCTAssertEqual(entry.uncompressedSize, 10_000)
        XCTAssertLessThan(entry.compressedSize, 10_000)
        XCTAssertEqual(entry.crc, Self.crc(content))
        XCTAssertEqual(entry.externalAttributes >> 16, 0o100444)
        XCTAssertEqual(entry.externalAttributes & 0xFF, 0x01)      // 読み取り専用
        XCTAssertEqual(entry.dosTime, 13 << 11 | 7 << 5 | 20)
        XCTAssertEqual(entry.dosDate, 44 << 9 | 3 << 5 | 5)

        // `0x7075`：version 1、ファイル名フィールドの CRC、UTF-8
        let unicode = try XCTUnwrap(entry.extra[0x7075])
        XCTAssertEqual(unicode[0], 1)
        XCTAssertEqual(ParsedZip.u32(unicode, 1), Self.crc(Data(entry.nameBytes)))
        XCTAssertEqual(String(decoding: unicode[5...], as: UTF8.self), "フォルダ/表.txt")
        XCTAssertNil(entry.extra[0x0001])

        // ローカルヘッダが中央ディレクトリと一致する。
        XCTAssertEqual(entry.localNameBytes, entry.nameBytes)
        XCTAssertEqual(entry.localCRC, entry.crc)
        XCTAssertEqual(entry.localCompressedSize, UInt64(entry.compressedSize))
        XCTAssertEqual(entry.localUncompressedSize, UInt64(entry.uncompressedSize))
        XCTAssertEqual(entry.localMethod, entry.method)
        XCTAssertEqual(entry.localFlags & 0x8, 0)                  // データディスクリプタなし
        XCTAssertEqual(entry.localExtra[0x7075], entry.extra[0x7075])
        try assertReadableByTools(zipURL)
    }

    func testUTF8EntryHasFlagAndNoUnicodeExtra() throws {
        let zipURL = dir.appendingPathComponent("a.zip")
        let source = try makeFile("src", Data("hello".utf8))
        let writer = try ZipWriter(url: zipURL)
        try add(writer, source, ["𠮷😀é.txt"], utf8)
        try writer.finish()

        let entry = try XCTUnwrap(ParsedZip(url: zipURL).entries.first)
        XCTAssertEqual(entry.flags & (1 << 11), 1 << 11)
        XCTAssertEqual(entry.localFlags & (1 << 11), 1 << 11)
        XCTAssertEqual(entry.nameBytes, Array("𠮷😀é.txt".utf8))
        XCTAssertTrue(entry.extra.isEmpty)
        try assertReadableByTools(zipURL)
    }

    func testDirectoryEntry() throws {
        let zipURL = dir.appendingPathComponent("a.zip")
        let writer = try ZipWriter(url: zipURL)
        try writer.addDirectory(name: encoded(["空のフォルダ"], cp932),
                                attributes: ZipEntryAttributes(modificationDate: Date(), posixPermissions: 0o755))
        try writer.finish()

        let entry = try XCTUnwrap(ParsedZip(url: zipURL).entries.first)
        XCTAssertEqual(entry.nameBytes.last, 0x2F)
        XCTAssertEqual(entry.method, 0)
        XCTAssertEqual(entry.compressedSize, 0)
        XCTAssertEqual(entry.externalAttributes >> 16, 0o040755)
        XCTAssertEqual(entry.externalAttributes & 0xFF, 0x10)
        // Unicode 名も末尾の `/` を含み、CRC はファイル名フィールドと一致する。
        let unicode = try XCTUnwrap(entry.extra[0x7075])
        XCTAssertEqual(String(decoding: unicode[5...], as: UTF8.self), "空のフォルダ/")
        XCTAssertEqual(ParsedZip.u32(unicode, 1), Self.crc(Data(entry.nameBytes)))
        try assertReadableByTools(zipURL)
    }

    // MARK: - 圧縮方式

    func testIncompressibleFileIsStored() throws {
        let zipURL = dir.appendingPathComponent("a.zip")
        // 読み取りの単位をまたぐ大きさも確認する。
        let small = randomData(5000)
        let large = randomData(3 * (1 << 20) + 17)
        let writer = try ZipWriter(url: zipURL)
        try add(writer, makeFile("small", small), ["small"], cp932)
        try add(writer, makeFile("large", large), ["large"], cp932)
        try writer.finish()

        let archive = try ParsedZip(url: zipURL)
        for (entry, content) in zip(archive.entries, [small, large]) {
            XCTAssertEqual(entry.method, 0)
            XCTAssertEqual(entry.compressedSize, UInt32(content.count))
            XCTAssertEqual(entry.crc, Self.crc(content))
            XCTAssertEqual(entry.localMethod, 0)
            XCTAssertEqual(try archive.storedData(of: entry), content)
        }
        try assertReadableByTools(zipURL)
    }

    func testEmptyFileIsStored() throws {
        let zipURL = dir.appendingPathComponent("a.zip")
        let writer = try ZipWriter(url: zipURL)
        try add(writer, makeFile("empty", Data()), ["empty"], cp932)
        try writer.finish()

        let entry = try XCTUnwrap(ParsedZip(url: zipURL).entries.first)
        XCTAssertEqual(entry.method, 0)
        XCTAssertEqual(entry.compressedSize, 0)
        XCTAssertEqual(entry.crc, 0)
        try assertReadableByTools(zipURL)
    }

    func testForceStoredAndFirstEntryForMimetype() throws {
        let zipURL = dir.appendingPathComponent("a.zip")
        let content = Data("application/epub+zip".utf8)
        let writer = try ZipWriter(url: zipURL)
        try add(writer, makeFile("mimetype", content), ["mimetype"], cp932, forceStored: true)
        try writer.finish()

        let archive = try ParsedZip(url: zipURL)
        let entry = try XCTUnwrap(archive.entries.first)
        XCTAssertEqual(entry.method, 0)
        XCTAssertEqual(entry.localOffset, 0)
        XCTAssertEqual(try archive.storedData(of: entry), content)
    }

    func testLargeCompressibleFileAcrossBuffers() throws {
        let zipURL = dir.appendingPathComponent("a.zip")
        // 出力バッファをあふれさせるよう、乱数と繰り返しを混ぜる。
        var content = randomData(1 << 20)
        content.append(Data(repeating: 0x20, count: 8 << 20))
        let writer = try ZipWriter(url: zipURL)
        try add(writer, makeFile("mixed", content), ["mixed"], cp932)
        try writer.finish()

        let entry = try XCTUnwrap(ParsedZip(url: zipURL).entries.first)
        XCTAssertEqual(entry.method, 8)
        XCTAssertEqual(entry.crc, Self.crc(content))
        try assertReadableByTools(zipURL)

        let out = dir.appendingPathComponent("out")
        XCTAssertEqual(try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, out.path]).status, 0)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("mixed")), content)
    }

    // MARK: - 解凍

    func testExtractionKeepsNamesContentsAndAttributes() throws {
        for (options, label, names) in [
            (cp932, "cp932", ["普通の名前.txt", "か\u{3099}.txt", "~$a.txt", "半角ｶﾅ.txt"]),
            (utf8, "utf8", ["普通の名前.txt", "か\u{3099}.txt", "𠮷😀é〜.txt", "①㈱.txt"]),
        ] {
            let zipURL = dir.appendingPathComponent("\(label).zip")
            let writer = try ZipWriter(url: zipURL)
            try writer.addDirectory(name: encoded(["親"], options), attributes: ZipEntryAttributes(modificationDate: Date(), posixPermissions: 0o755))
            try writer.addDirectory(name: encoded(["親", "空"], options), attributes: ZipEntryAttributes(modificationDate: Date(), posixPermissions: 0o755))
            var expected: [String: Data] = [:]
            for (i, name) in names.enumerated() {
                let content = Data(repeating: UInt8(0x41 + i), count: 100 + i)
                let source = try makeFile("\(label)-\(i)", content)
                try add(writer, source, ["親", name], options)
                expected[NameEncoding.normalized(name)] = content
            }
            try writer.finish()
            try assertReadableByTools(zipURL)

            let out = dir.appendingPathComponent("out-\(label)")
            let result = try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, out.path])
            XCTAssertEqual(result.status, 0, result.output)

            let parent = out.appendingPathComponent("親")
            let found = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            XCTAssertTrue(found.contains("空"), label)
            for (name, content) in expected {
                XCTAssertEqual(try Data(contentsOf: parent.appendingPathComponent(name)), content, name)
                // String の == は正規等価なので、スカラーで元の名前と比べる。
                XCTAssertTrue(found.contains { $0.unicodeScalars.elementsEqual(name.unicodeScalars) }, name)
            }
        }
    }

    func testReadOnlyPermissionSurvivesExtraction() throws {
        let zipURL = dir.appendingPathComponent("a.zip")
        let source = try makeFile("src", Data("x".utf8))
        let writer = try ZipWriter(url: zipURL)
        try writer.addFile(source: source, size: 1, name: encoded(["r.txt"], cp932),
                           attributes: ZipEntryAttributes(modificationDate: Date(), posixPermissions: 0o444))
        try writer.finish()

        let out = dir.appendingPathComponent("out")
        XCTAssertEqual(try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, out.path]).status, 0)
        let extracted = out.appendingPathComponent("r.txt")
        let mode = try FileManager.default.attributesOfItem(atPath: extracted.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o444)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: extracted.path)
    }

    // MARK: - 日時

    func testDOSDateOutOfRangeIsClamped() throws {
        let zipURL = dir.appendingPathComponent("a.zip")
        let calendar = Calendar(identifier: .gregorian)
        let writer = try ZipWriter(url: zipURL)
        for (name, year) in [("old", 1970), ("new", 2200)] {
            let date = DateComponents(calendar: calendar, year: year, month: 6, day: 1).date!
            try writer.addDirectory(name: encoded([name], cp932), attributes: ZipEntryAttributes(modificationDate: date, posixPermissions: 0o755))
        }
        try writer.finish()
        let entries = try ParsedZip(url: zipURL).entries
        XCTAssertEqual(entries[0].dosDate, 0 << 9 | 1 << 5 | 1)
        XCTAssertEqual(entries[1].dosDate, 127 << 9 | 12 << 5 | 31)
    }

    // MARK: - ZIP 暗号

    func testEncryptedArchiveExtractsOnlyWithPassword() throws {
        let zipURL = dir.appendingPathComponent("a.zip")
        let password = "Abc 123!~"
        let text = Data(String(repeating: "入稿データ ", count: 5000).utf8)   // Deflate になる
        let random = randomData(3 * (1 << 20) + 17)                             // 無圧縮に戻る。読み取りの単位をまたぐ
        let empty = Data()
        let writer = try ZipWriter(url: zipURL, password: Array(password.utf8))
        try writer.addDirectory(name: encoded(["フォルダ"], utf8), attributes: attributes)
        try add(writer, makeFile("text", text), ["フォルダ", "文章.txt"], utf8)
        try add(writer, makeFile("random", random), ["random.bin"], cp932)
        try add(writer, makeFile("empty", empty), ["empty"], cp932)
        try writer.finish()

        let archive = try ParsedZip(url: zipURL)
        let raw = try [UInt8](Data(contentsOf: zipURL))
        XCTAssertEqual(archive.entries.map { $0.flags & 1 }, [0, 1, 1, 1])        // フォルダは暗号化しない
        XCTAssertEqual(archive.entries.map { $0.localFlags & 1 }, [0, 1, 1, 1])
        XCTAssertEqual(archive.entries.map(\.method), [0, 8, 0, 0])
        for (entry, content) in zip(archive.entries.dropFirst(), [text, random, empty]) {
            XCTAssertEqual(entry.crc, Self.crc(content))
            XCTAssertEqual(entry.uncompressedSize, UInt32(content.count))
            // 暗号化ヘッダの12バイトの分だけ大きい。最後の1バイトは CRC の上位8ビット。
            var header = Array(raw[Int(entry.dataOffset)..<Int(entry.dataOffset) + 12])
            var cipher = ZipCrypto(password: Array(password.utf8))
            cipher.decrypt(&header)
            XCTAssertEqual(header[11], UInt8(entry.crc >> 24))
            if entry.method == 0 { XCTAssertEqual(entry.compressedSize, UInt32(content.count) + 12) }
        }

        XCTAssertEqual(try run("/usr/bin/unzip", ["-t", "-P", password, zipURL.path]).status, 0)
        XCTAssertNotEqual(try run("/usr/bin/unzip", ["-t", "-P", "wrong", zipURL.path]).status, 0)

        let out = dir.appendingPathComponent("out")
        let result = try run("/usr/bin/unzip", ["-P", password, "-d", out.path, zipURL.path])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("random.bin")), random)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("empty")), empty)
        let python = try run("/usr/bin/python3", ["-c", """
            import sys, zipfile
            z = zipfile.ZipFile(sys.argv[1])
            z.setpassword(sys.argv[2].encode())
            sys.exit(1 if z.testzip() else 0)
            """, zipURL.path, password])
        XCTAssertEqual(python.status, 0, python.output)
    }

    func testEncryptedProgressReportsEachByteOnce() throws {
        let zipURL = dir.appendingPathComponent("a.zip")
        let content = randomData(3 << 20)
        let writer = try ZipWriter(url: zipURL, password: Array("pw".utf8))
        var total: UInt64 = 0
        try writer.addFile(source: try makeFile("src", content), size: UInt64(content.count),
                           name: encoded(["a"], cp932), attributes: attributes) { total += $0 }
        try writer.finish()
        XCTAssertEqual(total, UInt64(content.count))
    }

    func testUnencryptedArchiveHasNoEncryptionFlag() throws {
        let zipURL = dir.appendingPathComponent("a.zip")
        let writer = try ZipWriter(url: zipURL)
        try add(writer, makeFile("a", Data("abc".utf8)), ["a"], cp932)
        try writer.finish()
        XCTAssertEqual(try ParsedZip(url: zipURL).entries.first.map { $0.flags & 1 }, 0)
    }

    // MARK: - エラーとキャンセル

    func testCancelFromProgressStopsAndAbortRemovesFile() throws {
        let zipURL = dir.appendingPathComponent("a.zip")
        let source = try makeFile("src", Data(repeating: 0, count: 3 << 20))
        let writer = try ZipWriter(url: zipURL)
        struct Cancelled: Error {}
        XCTAssertThrowsError(try writer.addFile(source: source, size: 3 << 20, name: encoded(["a"], cp932), attributes: attributes) { _ in
            throw Cancelled()
        }) { XCTAssertTrue($0 is Cancelled, "\($0)") }
        writer.abort()
        XCTAssertFalse(FileManager.default.fileExists(atPath: zipURL.path))
    }

    func testProgressReportsEachByteOnceEvenWhenStored() throws {
        let zipURL = dir.appendingPathComponent("a.zip")
        let content = randomData(3 << 20)
        let source = try makeFile("src", content)
        let writer = try ZipWriter(url: zipURL)
        var total: UInt64 = 0
        try writer.addFile(source: source, size: UInt64(content.count), name: encoded(["a"], cp932), attributes: attributes) { total += $0 }
        try writer.finish()
        XCTAssertEqual(total, UInt64(content.count))
        XCTAssertEqual(try ParsedZip(url: zipURL).entries.first?.method, 0)
    }

    func testMissingSourceThrowsReadFailed() throws {
        let writer = try ZipWriter(url: dir.appendingPathComponent("a.zip"))
        let missing = dir.appendingPathComponent("missing")
        XCTAssertThrowsError(try writer.addFile(source: missing, size: 1, name: encoded(["a"], cp932), attributes: attributes)) { error in
            guard case ZipWriterError.readFailed(let url, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(url, missing)
        }
        writer.abort()
    }

    func testChangedSizeThrowsFileChanged() throws {
        let source = try makeFile("src", Data(repeating: 0, count: 100))
        for size: UInt64 in [99, 101] {
            let zipURL = dir.appendingPathComponent("a\(size).zip")
            let writer = try ZipWriter(url: zipURL)
            XCTAssertThrowsError(try writer.addFile(source: source, size: size, name: encoded(["a"], cp932), attributes: attributes)) { error in
                guard case ZipWriterError.fileChanged = error else { return XCTFail("\(error)") }
            }
            writer.abort()
        }
    }

    func testExistingFileIsNotOverwritten() throws {
        let existing = try makeFile("a.zip", Data("keep".utf8))
        XCTAssertThrowsError(try ZipWriter(url: existing)) { error in
            guard case ZipWriterError.writeFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))
    }

    // MARK: - ZIP64

    func testNoZip64ForOrdinaryArchive() throws {
        let zipURL = dir.appendingPathComponent("a.zip")
        let writer = try ZipWriter(url: zipURL)
        try add(writer, makeFile("src", Data("x".utf8)), ["a"], cp932)
        try writer.finish()
        XCTAssertFalse(try ParsedZip(url: zipURL).hasZip64End)
    }

    func test65535EntriesDoNotUseZip64() throws {
        let archive = try makeEmptyEntries(count: 65535)
        XCTAssertFalse(archive.hasZip64End)
        XCTAssertEqual(archive.entries.count, 65535)
    }

    func test65536EntriesUseZip64() throws {
        let archive = try makeEmptyEntries(count: 65536)
        XCTAssertTrue(archive.hasZip64End)
        XCTAssertEqual(archive.entries.count, 65536)
        XCTAssertEqual(archive.endEntryCount, 0xFFFF)
    }

    private func makeEmptyEntries(count: Int) throws -> ParsedZip {
        let zipURL = dir.appendingPathComponent("many\(count).zip")
        let writer = try ZipWriter(url: zipURL)
        for i in 0..<count {
            try writer.addDirectory(name: EncodedName(bytes: Array("d\(i)".utf8), usesUTF8Flag: true, unicodePathUTF8: nil), attributes: attributes)
        }
        try writer.finish()
        try assertReadableByTools(zipURL)
        return try ParsedZip(url: zipURL)
    }

    /// 実データで 4GiB をまたぐ検査。時間がかかるので、環境変数を指定したときだけ実行する：
    /// `TEST_RUNNER_DTP_ZIPPER_BIG_TESTS=1 xcodebuild test ...`
    private func skipUnlessBigTests() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DTP_ZIPPER_BIG_TESTS"] != nil, "DTP_ZIPPER_BIG_TESTS が未指定")
    }

    /// 中身がすべて 0 のスパースファイルを作る。
    private func makeSparseFile(_ name: String, size: UInt64) throws -> URL {
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: size)
        try handle.close()
        return url
    }

    func testFileOver4GiBUsesZip64Sizes() throws {
        try skipUnlessBigTests()
        let size: UInt64 = (4 << 30) + 1
        let source = try makeSparseFile("big", size: size)
        let zipURL = dir.appendingPathComponent("a.zip")
        let writer = try ZipWriter(url: zipURL)
        try writer.addFile(source: source, size: size, name: encoded(["大きなファイル"], cp932), attributes: attributes)
        try add(writer, makeFile("after", Data("after".utf8)), ["after.txt"], cp932)
        try writer.finish()

        let archive = try ParsedZip(url: zipURL)
        let entry = archive.entries[0]
        XCTAssertEqual(entry.uncompressedSize, UInt32.max)
        XCTAssertEqual(entry.versionNeeded, 45)
        XCTAssertEqual(entry.localVersionNeeded, 45)
        XCTAssertEqual(entry.zip64Values.first, size)
        // ローカルヘッダの ZIP64 フィールド：元のサイズ、圧縮後のサイズ
        XCTAssertEqual(ParsedZip.u64(try XCTUnwrap(entry.localExtra[0x0001]), 0), size)
        XCTAssertEqual(ParsedZip.u64(try XCTUnwrap(entry.localExtra[0x0001]), 8), UInt64(entry.compressedSize))
        XCTAssertFalse(archive.hasZip64End)     // 4GiB 以上でも中央ディレクトリの位置が収まれば不要
        try assertReadableByTools(zipURL)

        let out = dir.appendingPathComponent("out")
        XCTAssertEqual(try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, out.path]).status, 0)
        let values = try out.appendingPathComponent("大きなファイル").resourceValues(forKeys: [.fileSizeKey])
        XCTAssertEqual(UInt64(try XCTUnwrap(values.fileSize)), size)
    }

    func testTotalOver4GiBUsesZip64Offsets() throws {
        try skipUnlessBigTests()
        let size: UInt64 = (2 << 30) + (512 << 20)
        let zipURL = dir.appendingPathComponent("a.zip")
        let writer = try ZipWriter(url: zipURL)
        for name in ["a", "b", "c"] {
            let source = try makeSparseFile(name, size: size)
            try writer.addFile(source: source, size: size, name: encoded([name], cp932), attributes: attributes, forceStored: true)
            try FileManager.default.removeItem(at: source)
        }
        try writer.finish()

        let archive = try ParsedZip(url: zipURL)
        XCTAssertTrue(archive.hasZip64End)
        XCTAssertEqual(archive.entries.count, 3)
        // 2番目は 32 ビットに収まり、3番目の位置だけ ZIP64 になる。
        XCTAssertNil(archive.entries[1].extra[0x0001])
        XCTAssertEqual(archive.entries[2].localOffset, UInt64(UInt32.max))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(archive.entries[2].zip64Values.first), 4 << 30)
        try assertReadableByTools(zipURL)
    }

    // MARK: - CRC

    static func crc(_ data: Data) -> UInt32 {
        data.withUnsafeBytes {
            UInt32(zlib.crc32(zlib.crc32(0, nil, 0), $0.bindMemory(to: UInt8.self).baseAddress, UInt32($0.count)))
        }
    }
}

// MARK: - 検証用の読み取り

/// 書き込みの結果を、ライターのコードを通さずに読むための最小の ZIP パーサ。
private struct ParsedZip {

    struct Entry {
        var versionMadeBy: UInt16 = 0, versionNeeded: UInt16 = 0, flags: UInt16 = 0, method: UInt16 = 0
        var dosTime: UInt16 = 0, dosDate: UInt16 = 0
        var crc: UInt32 = 0, compressedSize: UInt32 = 0, uncompressedSize: UInt32 = 0
        var externalAttributes: UInt32 = 0, localOffset: UInt64 = 0
        var nameBytes: [UInt8] = []
        var extra: [UInt16: [UInt8]] = [:]
        var zip64Values: [UInt64] = []
        // ローカルヘッダ（4GiB 未満のオフセットのみ読む）
        var localVersionNeeded: UInt16 = 0, localFlags: UInt16 = 0, localMethod: UInt16 = 0
        var localCRC: UInt32 = 0, localCompressedSize: UInt64 = 0, localUncompressedSize: UInt64 = 0
        var localNameBytes: [UInt8] = []
        var localExtra: [UInt16: [UInt8]] = [:]
        var dataOffset: UInt64 = 0
    }

    let url: URL
    var entries: [Entry] = []
    var hasZip64End = false
    var endEntryCount: UInt16 = 0

    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(u16(b, i)) | UInt32(u16(b, i + 2)) << 16 }
    static func u64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(u32(b, i)) | UInt64(u32(b, i + 4)) << 32 }

    private static func parseExtra(_ bytes: [UInt8]) -> [UInt16: [UInt8]] {
        var result: [UInt16: [UInt8]] = [:]
        var i = 0
        while i + 4 <= bytes.count {
            let id = u16(bytes, i), length = Int(u16(bytes, i + 2))
            result[id] = Array(bytes[(i + 4)..<(i + 4 + length)])
            i += 4 + length
        }
        return result
    }

    init(url: URL) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()

        func read(_ offset: UInt64, _ count: Int) throws -> [UInt8] {
            try handle.seek(toOffset: offset)
            return Array(try handle.read(upToCount: count) ?? Data())
        }

        // コメントは書かないので、末尾の 22 バイトが終端レコード。
        let end = try read(fileSize - 22, 22)
        XCTAssertEqual(Self.u32(end, 0), 0x0605_4B50)
        endEntryCount = Self.u16(end, 8)
        var count = UInt64(endEntryCount)
        var directorySize = UInt64(Self.u32(end, 12))
        var directoryStart = UInt64(Self.u32(end, 16))

        if fileSize >= 42 {
            let locator = try read(fileSize - 42, 20)
            if Self.u32(locator, 0) == 0x0706_4B50 {
                hasZip64End = true
                let record = try read(Self.u64(locator, 8), 56)
                XCTAssertEqual(Self.u32(record, 0), 0x0606_4B50)
                count = Self.u64(record, 32)
                directorySize = Self.u64(record, 40)
                directoryStart = Self.u64(record, 48)
            }
        }

        let directory = try read(directoryStart, Int(directorySize))
        var i = 0
        for _ in 0..<count {
            XCTAssertEqual(Self.u32(directory, i), 0x0201_4B50)
            var e = Entry()
            e.versionMadeBy = Self.u16(directory, i + 4)
            e.versionNeeded = Self.u16(directory, i + 6)
            e.flags = Self.u16(directory, i + 8)
            e.method = Self.u16(directory, i + 10)
            e.dosTime = Self.u16(directory, i + 12)
            e.dosDate = Self.u16(directory, i + 14)
            e.crc = Self.u32(directory, i + 16)
            e.compressedSize = Self.u32(directory, i + 20)
            e.uncompressedSize = Self.u32(directory, i + 24)
            let nameLength = Int(Self.u16(directory, i + 28))
            let extraLength = Int(Self.u16(directory, i + 30))
            e.externalAttributes = Self.u32(directory, i + 38)
            e.localOffset = UInt64(Self.u32(directory, i + 42))
            e.nameBytes = Array(directory[(i + 46)..<(i + 46 + nameLength)])
            e.extra = Self.parseExtra(Array(directory[(i + 46 + nameLength)..<(i + 46 + nameLength + extraLength)]))
            if let zip64 = e.extra[0x0001] {
                e.zip64Values = stride(from: 0, to: zip64.count, by: 8).map { Self.u64(zip64, $0) }
            }
            i += 46 + nameLength + extraLength

            if e.localOffset != UInt64(UInt32.max) {
                let local = try read(e.localOffset, 30)
                XCTAssertEqual(Self.u32(local, 0), 0x0403_4B50)
                e.localVersionNeeded = Self.u16(local, 4)
                e.localFlags = Self.u16(local, 6)
                e.localMethod = Self.u16(local, 8)
                e.localCRC = Self.u32(local, 14)
                e.localCompressedSize = UInt64(Self.u32(local, 18))
                e.localUncompressedSize = UInt64(Self.u32(local, 22))
                let localNameLength = Int(Self.u16(local, 26))
                let localExtraLength = Int(Self.u16(local, 28))
                let rest = try read(e.localOffset + 30, localNameLength + localExtraLength)
                e.localNameBytes = Array(rest[0..<localNameLength])
                e.localExtra = Self.parseExtra(Array(rest[localNameLength...]))
                e.dataOffset = e.localOffset + 30 + UInt64(localNameLength + localExtraLength)
            }
            entries.append(e)
        }
    }

    func storedData(of entry: Entry) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: entry.dataOffset)
        return try handle.read(upToCount: Int(entry.compressedSize)) ?? Data()
    }
}
