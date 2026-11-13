import Foundation
import zlib

/// ZIP の書き込みで起きるエラー。
nonisolated enum ZipWriterError: Error {
    /// ファイルを読めなかった。
    case readFailed(URL, underlying: Error)
    /// 読んだサイズが走査時と異なる。圧縮中にファイルが変更された。
    case fileChanged(URL)
    /// ZIP を書き込めなかった。
    case writeFailed(URL, underlying: Error)
    /// 圧縮に失敗した。
    case compressionFailed(URL, code: Int32)
    /// ZIP のヘッダに書けないほど名前が長い。
    case nameTooLong
}

/// エントリの属性。
nonisolated struct ZipEntryAttributes: Sendable {
    var modificationDate: Date
    /// Unix パーミッション（`0o644` など）。ファイルの種類のビットは含めない。
    var posixPermissions: UInt16
}

/// ZIP の書き込み（UI に依存しない。仕様 §5.2、§5.5）。
///
/// エントリは呼び出した順に書く。ヘッダへサイズと CRC を書き戻す方式で、データディスクリプタは使わない。
/// ZIP64 は必要なときだけ使う。1つのインスタンスを同時に複数のスレッドから使わないこと。
///
/// パスワードを渡すと、ファイルのエントリを従来の ZIP 暗号（ZipCrypto。APPNOTE 6.1）で暗号化する。
/// Windows のエクスプローラーで解凍できる唯一の方式だが、暗号としては弱い。暗号化ヘッダの検査用の1バイトに
/// CRC が要るので、暗号化するときはファイルを先に1回読んで CRC を求める。
nonisolated final class ZipWriter {

    private let url: URL
    private let output: FileHandle
    private var position: UInt64 = 0
    private var entries: [CentralEntry] = []
    private var isClosed = false
    /// ZIP 暗号のパスワード。nil なら暗号化しない。
    private let password: [UInt8]?
    /// データを書いている間だけ設定する。`writeData` がこれで暗号化する。
    private var cipher: ZipCrypto?

    /// `url` に新しいファイルを作る。既にあれば失敗する。
    /// - Parameter password: ZIP 暗号のパスワード（バイト列）。nil なら暗号化しない。
    init(url: URL, password: [UInt8]? = nil) throws {
        self.url = url
        self.password = password
        do {
            // `O_EXCL` で作り、既存のファイルを上書きしない。
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        } catch {
            throw ZipWriterError.writeFailed(url, underlying: error)
        }
    }

    deinit {
        if !isClosed { try? output.close() }
    }

    // MARK: - エントリの追加

    /// フォルダを追加する。`name` の末尾の `/` はここで付ける。
    func addDirectory(name: EncodedName, attributes: ZipEntryAttributes) throws {
        try validate(name)
        let nameBytes = name.bytes + [Self.slash]
        let unicodePath = name.unicodePathUTF8.map { $0 + [Self.slash] }
        let entry = CentralEntry(name: nameBytes, usesUTF8Flag: name.usesUTF8Flag,
                                 unicodePathExtra: Self.unicodePathExtra(utf8: unicodePath, nameBytes: nameBytes),
                                 attributes: attributes, isDirectory: true, offset: position)
        try writing { try write(entry.localHeader(usesZip64Sizes: false)) }
        entries.append(entry)
    }

    /// ファイルを追加する。全体をメモリに載せず、順に読み書きする。
    /// - Parameters:
    ///   - size: 走査時のサイズ。読んだサイズと異なれば `fileChanged` で中止する。
    ///   - forceStored: 無圧縮で格納する（EPUB の `mimetype` 用）。
    ///   - progress: 読み終えたバイト数の増分を受け取る。キャンセルするときはここでエラーを投げる。
    func addFile(source: URL, size: UInt64, name: EncodedName, attributes: ZipEntryAttributes,
                 forceStored: Bool = false, progress: (UInt64) throws -> Void = { _ in }) throws {
        try validate(name)
        var entry = CentralEntry(name: name.bytes, usesUTF8Flag: name.usesUTF8Flag,
                                 unicodePathExtra: Self.unicodePathExtra(utf8: name.unicodePathUTF8, nameBytes: name.bytes),
                                 attributes: attributes, isDirectory: false, offset: position)
        entry.uncompressedSize = size
        entry.isEncrypted = password != nil
        let overhead: UInt64 = entry.isEncrypted ? ZipCrypto.headerSize : 0
        let usesZip64Sizes = size + overhead >= Self.limit32

        // 暗号化ヘッダに CRC の上位8ビットを入れるので、先に求める。
        var expectedCRC: UInt32?
        if entry.isEncrypted {
            expectedCRC = try crc(of: source, size: size) { try progress(0) }
        }

        let headerStart = position
        try writing { try write(entry.localHeader(usesZip64Sizes: usesZip64Sizes)) }
        let dataStart = position

        /// 暗号化するなら、鍵を初期化して暗号化ヘッダを書く。無圧縮で書き直すときも最初からやり直す。
        func beginData() throws {
            guard let password, let expectedCRC else { return }
            cipher = ZipCrypto(password: password)
            var header = (0..<11).map { _ in UInt8.random(in: 0...255) }
            header.append(UInt8(expectedCRC >> 24))
            try writing { try writeData(header) }
        }
        defer { cipher = nil }
        try beginData()

        var reported: UInt64 = 0
        func report(upTo read: UInt64) throws {
            if read > reported {
                try progress(read - reported)
                reported = read
            } else {
                try progress(0)
            }
        }

        var deflated: (crc: UInt32, size: UInt64)?
        if !forceStored && size > 0 {
            deflated = try deflate(source: source, size: size, report: report)
        }
        if let deflated {
            entry.method = Self.methodDeflated
            entry.crc32 = deflated.crc
            entry.compressedSize = deflated.size + overhead
        } else {
            // 小さくならなかったので、書いた分を捨てて無圧縮で書き直す。
            try writing {
                try output.truncate(atOffset: dataStart)
                try output.seek(toOffset: dataStart)
            }
            position = dataStart
            try beginData()
            entry.method = Self.methodStored
            entry.crc32 = try store(source: source, size: size, report: report)
            entry.compressedSize = size + overhead
        }
        // 先に求めた CRC と違えば、読んでいる間にファイルが変更された。
        if let expectedCRC, expectedCRC != entry.crc32 { throw ZipWriterError.fileChanged(source) }

        try writing {
            try output.seek(toOffset: headerStart)
            try write(entry.localHeader(usesZip64Sizes: usesZip64Sizes), countsPosition: false)
            try output.seek(toOffset: position)
        }
        entries.append(entry)
    }

    /// 中央ディレクトリを書いて閉じる。
    func finish() throws {
        try writing {
            let directoryStart = position
            var buffer: [UInt8] = []
            for entry in entries {
                buffer += entry.centralHeader()
                if buffer.count >= Self.bufferSize {
                    try write(buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try write(buffer)
            try writeEndOfDirectory(start: directoryStart, size: position - directoryStart)
            try output.close()
            isClosed = true
        }
    }

    /// 閉じて、書きかけのファイルを削除する。
    func abort() {
        if !isClosed {
            try? output.close()
            isClosed = true
        }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - データ

    /// Deflate で書く。圧縮しても小さくならなければ途中でやめて nil を返す。
    private func deflate(source: URL, size: UInt64, report: (UInt64) throws -> Void) throws -> (crc: UInt32, size: UInt64)? {
        var stream = z_stream()
        // windowBits = -15：生の Deflate
        let initResult = deflateInit2_(&stream, Self.compressionLevel, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
                                       ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else { throw ZipWriterError.compressionFailed(source, code: initResult) }
        defer { deflateEnd(&stream) }

        var compressed: UInt64 = 0
        var crc = Self.initialCRC
        var outBuffer = [UInt8](repeating: 0, count: Self.bufferSize)

        /// 入力を渡して、出力を ZIP へ書く。
        func pump(_ input: UnsafeBufferPointer<UInt8>, flush: Int32) throws {
            // zlib は入力を書き換えない。
            stream.next_in = input.baseAddress.map { UnsafeMutablePointer(mutating: $0) }
            stream.avail_in = UInt32(input.count)
            var result = Z_OK
            repeat {
                let produced: Int = try outBuffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = UInt32(out.count)
                    result = zlib.deflate(&stream, flush)
                    guard result == Z_OK || result == Z_STREAM_END || result == Z_BUF_ERROR else {
                        throw ZipWriterError.compressionFailed(source, code: result)
                    }
                    return out.count - Int(stream.avail_out)
                }
                if produced > 0 {
                    try writing { try writeData(Array(outBuffer[0..<produced])) }
                    compressed += UInt64(produced)
                }
            } while stream.avail_out == 0 || (flush == Z_FINISH && result != Z_STREAM_END)
        }

        var total: UInt64 = 0
        let complete = try readChunks(of: source, size: size) { chunk in
            total += UInt64(chunk.count)
            crc = Self.updatedCRC(crc, chunk)
            try chunk.withUnsafeBytes { try pump($0.bindMemory(to: UInt8.self), flush: Z_NO_FLUSH) }
            try report(total)
            return compressed < size
        }
        guard complete else { return nil }

        try pump(UnsafeBufferPointer(start: nil, count: 0), flush: Z_FINISH)
        return compressed < size ? (UInt32(truncatingIfNeeded: crc), compressed) : nil
    }

    /// 無圧縮で書いて CRC を返す。
    private func store(source: URL, size: UInt64, report: (UInt64) throws -> Void) throws -> UInt32 {
        var crc = Self.initialCRC
        var total: UInt64 = 0
        _ = try readChunks(of: source, size: size) { chunk in
            total += UInt64(chunk.count)
            crc = Self.updatedCRC(crc, chunk)
            try writing { try writeData([UInt8](chunk)) }
            try report(total)
            return true
        }
        return UInt32(truncatingIfNeeded: crc)
    }

    /// CRC だけを求める。`tick` はチャンクごとに呼ぶ（キャンセル用）。
    private func crc(of source: URL, size: UInt64, tick: () throws -> Void) throws -> UInt32 {
        var crc = Self.initialCRC
        _ = try readChunks(of: source, size: size) { chunk in
            crc = Self.updatedCRC(crc, chunk)
            try tick()
            return true
        }
        return UInt32(truncatingIfNeeded: crc)
    }

    private static let initialCRC = zlib.crc32(0, nil, 0)

    private static func updatedCRC(_ crc: UInt, _ data: Data) -> UInt {
        data.withUnsafeBytes { zlib.crc32(crc, $0.bindMemory(to: UInt8.self).baseAddress, UInt32($0.count)) }
    }

    /// `body` が false を返すまで順に読む。最後まで読んだら true を返す。
    private func readChunks(of source: URL, size: UInt64, body: (Data) throws -> Bool) throws -> Bool {
        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: source)
        } catch {
            throw ZipWriterError.readFailed(source, underlying: error)
        }
        defer { try? input.close() }

        var total: UInt64 = 0
        while true {
            // 大きなファイルでも自動解放プールに読み込みデータを溜めない。
            let (chunk, shouldContinue): (Data?, Bool) = try autoreleasepool {
                let chunk: Data?
                do {
                    chunk = try input.read(upToCount: Self.bufferSize)
                } catch {
                    throw ZipWriterError.readFailed(source, underlying: error)
                }
                guard let chunk, !chunk.isEmpty else { return (nil, true) }
                total += UInt64(chunk.count)
                if total > size { throw ZipWriterError.fileChanged(source) }
                return (chunk, try body(chunk))
            }
            if chunk == nil { break }
            if !shouldContinue { return false }
        }
        if total != size { throw ZipWriterError.fileChanged(source) }
        return true
    }

    // MARK: - 出力

    /// 出力のエラーを `writeFailed` へ変換する。出力の操作だけを囲むこと。
    private func writing<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw ZipWriterError.writeFailed(url, underlying: error)
        }
    }

    private func validate(_ name: EncodedName) throws {
        // 末尾の `/` と拡張フィールドのヘッダの分を見込む。
        if max(name.bytes.count, name.unicodePathUTF8?.count ?? 0) > 0xFF00 { throw ZipWriterError.nameTooLong }
    }

    private func write(_ bytes: [UInt8], countsPosition: Bool = true) throws {
        guard !bytes.isEmpty else { return }
        try output.write(contentsOf: bytes)
        if countsPosition { position += UInt64(bytes.count) }
    }

    /// エントリのデータを書く。暗号化中なら暗号化する。
    private func writeData(_ bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        if cipher != nil {
            var encrypted = bytes
            cipher!.encrypt(&encrypted)
            try write(encrypted)
        } else {
            try write(bytes)
        }
    }

    private func writeEndOfDirectory(start: UInt64, size: UInt64) throws {
        let count = UInt64(entries.count)
        let needsZip64 = count > 0xFFFF || start >= Self.limit32 || size >= Self.limit32

        if needsZip64 {
            let zip64Start = position
            var record = LittleEndianBytes()
            record.append32(0x0606_4B50)
            record.append64(44)                                 // このフィールドより後のサイズ
            record.append16(Self.versionMadeBy)
            record.append16(Self.versionZip64)
            record.append32(0)                                  // このディスクの番号
            record.append32(0)                                  // 中央ディレクトリのディスク番号
            record.append64(count)
            record.append64(count)
            record.append64(size)
            record.append64(start)
            record.append32(0x0706_4B50)                        // ZIP64 ロケータ
            record.append32(0)
            record.append64(zip64Start)
            record.append32(1)                                  // ディスクの総数
            try write(record.bytes)
        }

        var end = LittleEndianBytes()
        end.append32(0x0605_4B50)
        end.append16(0)
        end.append16(0)
        end.append16(UInt16(min(count, 0xFFFF)))
        end.append16(UInt16(min(count, 0xFFFF)))
        end.append32(UInt32(min(size, Self.limit32)))
        end.append32(UInt32(min(start, Self.limit32)))
        end.append16(0)                                         // コメントなし
        try write(end.bytes)
    }

    // MARK: - 定数

    private static let slash: UInt8 = 0x2F
    private static let bufferSize = 1 << 20
    /// これ以上の値は ZIP64 で表す（0xFFFFFFFF は ZIP64 の目印なので、そのままでは書けない）。
    private static let limit32: UInt64 = 0xFFFF_FFFF
    private static let compressionLevel: Int32 = 6              // zlib 既定
    fileprivate static let methodStored: UInt16 = 0
    fileprivate static let methodDeflated: UInt16 = 8
    fileprivate static let versionDefault: UInt16 = 20
    fileprivate static let versionZip64: UInt16 = 45
    fileprivate static let versionMadeBy: UInt16 = 3 << 8 | 20  // Unix、2.0（v1 と同じ）

    /// Info-ZIP の Unicode パス拡張フィールド `0x7075`。CRC は通常のファイル名フィールドのもの。
    private static func unicodePathExtra(utf8: [UInt8]?, nameBytes: [UInt8]) -> [UInt8] {
        guard let utf8 else { return [] }
        var extra = LittleEndianBytes()
        extra.append16(0x7075)
        extra.append16(UInt16(5 + utf8.count))
        extra.bytes.append(1)
        extra.append32(UInt32(truncatingIfNeeded: nameBytes.withUnsafeBufferPointer {
            zlib.crc32(0, $0.baseAddress, UInt32($0.count))
        }))
        extra.bytes += utf8
        return extra.bytes
    }
}

// MARK: - ヘッダ

/// 1エントリの情報。ローカルヘッダと中央ディレクトリの両方を作る。
private nonisolated struct CentralEntry {
    let name: [UInt8]
    let usesUTF8Flag: Bool
    let unicodePathExtra: [UInt8]
    let attributes: ZipEntryAttributes
    let isDirectory: Bool
    let offset: UInt64
    var method: UInt16 = ZipWriter.methodStored
    var crc32: UInt32 = 0
    var compressedSize: UInt64 = 0
    var uncompressedSize: UInt64 = 0
    /// ZIP 暗号で暗号化したか（汎用フラグ bit 0）。
    var isEncrypted = false

    private static let limit32: UInt64 = 0xFFFF_FFFF

    private var flags: UInt16 { (usesUTF8Flag ? 1 << 11 : 0) | (isEncrypted ? 1 : 0) }

    func localHeader(usesZip64Sizes: Bool) -> [UInt8] {
        var extra = LittleEndianBytes()
        if usesZip64Sizes {
            extra.append16(0x0001)
            extra.append16(16)
            extra.append64(uncompressedSize)
            extra.append64(compressedSize)
        }
        extra.bytes += unicodePathExtra

        var h = LittleEndianBytes()
        h.append32(0x0403_4B50)
        h.append16(usesZip64Sizes ? ZipWriter.versionZip64 : ZipWriter.versionDefault)
        h.append16(flags)
        h.append16(method)
        appendDOSDateTime(to: &h)
        h.append32(crc32)
        h.append32(usesZip64Sizes ? UInt32.max : UInt32(compressedSize))
        h.append32(usesZip64Sizes ? UInt32.max : UInt32(uncompressedSize))
        h.append16(UInt16(name.count))
        h.append16(UInt16(extra.bytes.count))
        h.bytes += name
        h.bytes += extra.bytes
        return h.bytes
    }

    func centralHeader() -> [UInt8] {
        // ZIP64 拡張フィールドには、32ビットに収まらない項目だけをこの順に入れる。
        var zip64 = LittleEndianBytes()
        if uncompressedSize >= Self.limit32 { zip64.append64(uncompressedSize) }
        if compressedSize >= Self.limit32 { zip64.append64(compressedSize) }
        if offset >= Self.limit32 { zip64.append64(offset) }

        var extra = LittleEndianBytes()
        if !zip64.bytes.isEmpty {
            extra.append16(0x0001)
            extra.append16(UInt16(zip64.bytes.count))
            extra.bytes += zip64.bytes
        }
        extra.bytes += unicodePathExtra

        var h = LittleEndianBytes()
        h.append32(0x0201_4B50)
        h.append16(ZipWriter.versionMadeBy)
        h.append16(zip64.bytes.isEmpty ? ZipWriter.versionDefault : ZipWriter.versionZip64)
        h.append16(flags)
        h.append16(method)
        appendDOSDateTime(to: &h)
        h.append32(crc32)
        h.append32(UInt32(min(compressedSize, Self.limit32)))
        h.append32(UInt32(min(uncompressedSize, Self.limit32)))
        h.append16(UInt16(name.count))
        h.append16(UInt16(extra.bytes.count))
        h.append16(0)                                           // コメントなし
        h.append16(0)                                           // ディスク番号
        h.append16(0)                                           // 内部属性
        h.append32(externalAttributes)
        h.append32(UInt32(min(offset, Self.limit32)))
        h.bytes += name
        h.bytes += extra.bytes
        return h.bytes
    }

    /// 上位 16 ビットが Unix のモード、下位が DOS 属性（読み取り専用 0x01、フォルダ 0x10）。
    private var externalAttributes: UInt32 {
        let type: UInt32 = isDirectory ? 0o040000 : 0o100000
        var value = (type | UInt32(attributes.posixPermissions & 0o7777)) << 16
        if isDirectory { value |= 0x10 }
        if attributes.posixPermissions & 0o222 == 0 { value |= 0x01 }
        return value
    }

    /// DOS 形式のローカル時刻（2秒単位）。表せない範囲は端の値にする。
    private func appendDOSDateTime(to h: inout LittleEndianBytes) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: attributes.modificationDate)
        let year = c.year ?? 1980
        if year < 1980 {
            append(to: &h, year: 1980, month: 1, day: 1, hour: 0, minute: 0, second: 0)
        } else if year > 2107 {
            append(to: &h, year: 2107, month: 12, day: 31, hour: 23, minute: 59, second: 58)
        } else {
            append(to: &h, year: year, month: c.month ?? 1, day: c.day ?? 1,
                   hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0)
        }
    }

    private func append(to h: inout LittleEndianBytes, year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        let time: Int = hour << 11 | minute << 5 | second / 2
        let date: Int = (year - 1980) << 9 | month << 5 | day
        h.append16(UInt16(time))
        h.append16(UInt16(date))
    }
}

private nonisolated struct LittleEndianBytes {
    var bytes: [UInt8] = []

    mutating func append16(_ v: UInt16) {
        bytes.append(UInt8(v & 0xFF))
        bytes.append(UInt8(v >> 8))
    }

    mutating func append32(_ v: UInt32) {
        append16(UInt16(v & 0xFFFF))
        append16(UInt16(v >> 16))
    }

    mutating func append64(_ v: UInt64) {
        append32(UInt32(v & 0xFFFF_FFFF))
        append32(UInt32(v >> 32))
    }
}

// MARK: - ZIP 暗号

/// 従来の ZIP 暗号（ZipCrypto。APPNOTE 6.1「Traditional PKWARE Encryption」）。
nonisolated struct ZipCrypto {
    /// 暗号化ヘッダのバイト数。データの前に置く。
    static let headerSize: UInt64 = 12

    private var key0: UInt32 = 0x1234_5678
    private var key1: UInt32 = 0x2345_6789
    private var key2: UInt32 = 0x3456_7890

    init(password: [UInt8]) {
        for byte in password { update(byte) }
    }

    /// 平文を暗号文に置き換える。
    mutating func encrypt(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBufferPointer { buffer in
            for i in buffer.indices {
                let plain = buffer[i]
                buffer[i] = plain ^ streamByte
                update(plain)
            }
        }
    }

    /// 暗号文を平文に戻す（テスト用）。
    mutating func decrypt(_ bytes: inout [UInt8]) {
        for i in bytes.indices {
            let plain = bytes[i] ^ streamByte
            bytes[i] = plain
            update(plain)
        }
    }

    private var streamByte: UInt8 {
        let t = (key2 & 0xFFFF) | 2
        return UInt8(truncatingIfNeeded: (t &* (t ^ 1)) >> 8)
    }

    private mutating func update(_ byte: UInt8) {
        key0 = Self.crc(key0, byte)
        key1 = (key1 &+ (key0 & 0xFF)) &* 134_775_813 &+ 1
        key2 = Self.crc(key2, UInt8(truncatingIfNeeded: key1 >> 24))
    }

    private static func crc(_ value: UInt32, _ byte: UInt8) -> UInt32 {
        table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
    }

    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
}
