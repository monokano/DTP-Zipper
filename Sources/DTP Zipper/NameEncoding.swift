import Foundation

/// ZIP 内のファイル名に使うエンコーディング（仕様 §4.1）。
nonisolated enum NameEncodingKind: String, Sendable {
    case cp932
    case utf8
}

/// 名前の検査と ZIP 書き込みに使う設定。
nonisolated struct NameOptions: Hashable, Sendable {
    var encoding: NameEncodingKind = .utf8
}

/// CP932 の名前で保持できない文字の種類（E2）。問題欄の文言を分けるために使う。並びは報告する順。
nonisolated enum NotPreservedKind: String, Sendable, CaseIterable {
    /// CP932 にはあるが、macOS の Shift_JIS と両立しない（`①` `㈱` `髙` `～` など）。
    case platformDependent
    /// macOS の Shift_JIS にはあるが、CP932 と両立しない（`〜` `−` `—` など）。
    case differsByPlatform
    /// どちらにもない（`𠮷` `é`、絵文字など）。
    case notInShiftJIS
    /// 外字（私用領域）。
    case userDefined
}

/// ZIP のヘッダへ書く名前（仕様 §5.2）。
nonisolated struct EncodedName: Equatable, Sendable {
    let bytes: [UInt8]
    /// 汎用フラグ bit 11 を立てるか。
    let usesUTF8Flag: Bool
    /// 拡張フィールド `0x7075` に併記する UTF-8。CP932 のときのみ。
    let unicodePathUTF8: [UInt8]?
}

/// 名前の変換と、CP932 / UTF-8 のバイト列の生成（UI に依存しない）。
nonisolated enum NameEncoding {

    // MARK: - 安全な NFC

    /// 合成除外文字（Composition Exclusions, astral 含む）。FILL Id の `TextNormalizer` から移植。
    /// raw string literal なのでバックスラッシュはそのまま ICU の `\x{...}` として解釈される。
    private static let compositionExclusionsPattern =
        #"[\x{0340}\x{0341}\x{0343}\x{0344}\x{0374}\x{037E}\x{0387}\x{0958}-\x{095F}\x{09DC}\x{09DD}\x{09DF}\x{0A33}\x{0A36}\x{0A59}-\x{0A5B}\x{0A5E}\x{0B5C}\x{0B5D}\x{0F43}\x{0F4D}\x{0F52}\x{0F57}\x{0F5C}\x{0F69}\x{0F73}\x{0F75}\x{0F76}\x{0F78}\x{0F81}\x{0F93}\x{0F9D}\x{0FA2}\x{0FA7}\x{0FAC}\x{0FB9}\x{1F71}\x{1F73}\x{1F75}\x{1F77}\x{1F79}\x{1F7B}\x{1F7D}\x{1FBB}\x{1FBE}\x{1FC9}\x{1FCB}\x{1FD3}\x{1FDB}\x{1FE3}\x{1FEB}\x{1FEE}\x{1FEF}\x{1FF9}\x{1FFB}\x{1FFD}\x{2000}\x{2001}\x{2126}\x{212A}\x{212B}\x{2329}-\x{232A}\x{2ADC}\x{F900}-\x{FAFF}\x{FB1D}\x{FB1F}\x{FB2A}-\x{FB36}\x{FB38}-\x{FB3C}\x{FB3E}\x{FB40}\x{FB41}\x{FB43}\x{FB44}\x{FB46}-\x{FB4E}\x{1D15E}-\x{1D164}\x{1D1BB}-\x{1D1C0}\x{2F800}-\x{2FA1F}]"#

    private static let exclusionsRegex = try! NSRegularExpression(pattern: compositionExclusionsPattern)

    /// 合成除外文字を保護した NFC 正規化。
    /// 単純な NFC だと互換漢字などが統合漢字へ化けるため、合成除外文字を一時退避してから NFC を適用する。
    static func nfcSafe(_ input: String) -> String {
        if input.isEmpty { return input }
        if input.allSatisfy({ $0.isASCII }) { return input }

        let ns = input as NSString
        let matches = exclusionsRegex.matches(in: input, range: NSRange(location: 0, length: ns.length))

        var protectedChars: [String] = []
        var placeholders: [String] = []
        var seen = Set<String>()
        for m in matches {
            let ch = ns.substring(with: m.range)
            // ⚠️ String の == と Set は正規等価で比較するので、Unicode スカラーの列を鍵にする。
            if seen.insert(ch.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "+")).inserted {
                protectedChars.append(ch)
                placeholders.append(UUID().uuidString)
            }
        }

        // ⚠️ 置換は必ず `.literal`（コードポイント単位の比較）で行う。既定の比較は**正規等価**なので、
        //    互換漢字 U+F9DC（隆）を退避すると、同じ字の統合漢字 U+9686 まで一緒に置き換わる。
        var work = input
        for (ch, ph) in zip(protectedChars, placeholders) {
            work = work.replacingOccurrences(of: ch, with: ph, options: .literal)
        }
        work = work.precomposedStringWithCanonicalMapping
        for (ch, ph) in zip(protectedChars, placeholders).reversed() {
            work = work.replacingOccurrences(of: ph, with: ch, options: .literal)
        }
        return work
    }

    /// 判定と ZIP の書き込みに使う名前（仕様 §4.2 の手順 1）。
    static func normalized(_ name: String) -> String {
        nfcSafe(name)
    }

    // MARK: - CP932 の文字表

    /// CFStringEncoding の値。
    private static let cp932Encoding = encoding(0x0420)      // kCFStringEncodingDOSJapanese
    private static let shiftJISEncoding = encoding(0x0A01)   // kCFStringEncodingShiftJIS

    private static func encoding(_ cf: UInt32) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// BMP の文字ごとの CP932 バイト列と、保持できるかどうか。CP932 に BMP 外の文字はない。
    private struct CP932Table {
        /// 上位バイト、下位バイトの順にまとめた値。1バイト文字は上位が 0。0 は「保持できない」。
        var codes = [UInt16](repeating: 0, count: 0x10000)
        var strict = [Bool](repeating: false, count: 0x10000)
        /// CP932 では往復できないが、macOS の Shift_JIS では往復できる文字（E2 の種類分けに使う）。
        var shiftJISOnly = [Bool](repeating: false, count: 0x10000)
    }

    /// 変換して戻した結果が元と同じ Unicode スカラーになるかを確かめて作る。
    /// ⚠️ String の == は正規等価なので使わない（互換漢字が統合漢字に戻っても一致してしまう）。
    private static let table: CP932Table = {
        var t = CP932Table()
        for v in UInt32(1)...0xFFFF {
            guard !(0xE000...0xF8FF).contains(v),   // 外字は常に保持できない扱い（E2）
                  let scalar = Unicode.Scalar(v) else { continue }
            let s = String(Character(scalar))
            let inShiftJIS = roundTrippedBytes(s, shiftJISEncoding) != nil
            guard let bytes = roundTrippedBytes(s, cp932Encoding) else {
                t.shiftJISOnly[Int(v)] = inShiftJIS
                continue
            }
            t.codes[Int(v)] = bytes.reduce(UInt16(0)) { $0 << 8 | UInt16($1) }
            t.strict[Int(v)] = inShiftJIS
        }
        // 実測による調整（仕様 §4.1）。
        t.strict[0x7E] = true       // `~`：変換表では `‾` だが、実際の解凍では `~` のまま
        t.strict[0xFF69] = false    // `ｩ`：変換表では往復できるが、実際の解凍では `0x7075` がないと文字化けする
        return t
    }()

    private static func roundTrippedBytes(_ s: String, _ encoding: String.Encoding) -> [UInt8]? {
        guard let data = s.data(using: encoding), !data.isEmpty,
              let back = String(data: data, encoding: encoding),
              back.unicodeScalars.elementsEqual(s.unicodeScalars) else { return nil }
        return Array(data)
    }

    /// この文字を CP932 の名前で保持できるか（E2）。Windows と macOS で共通に保たれる文字に限る。
    static func isPreservedInCP932(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.value <= 0xFFFF else { return false }
        return table.strict[Int(scalar.value)]
    }

    /// CP932 の名前で保持できない文字の種類（E2）。保持できる文字は nil。
    static func notPreservedKind(_ scalar: Unicode.Scalar) -> NotPreservedKind? {
        let v = scalar.value
        if (0xE000...0xF8FF).contains(v) || v >= 0xF0000 { return .userDefined }
        guard v <= 0xFFFF else { return .notInShiftJIS }
        if table.strict[Int(v)] { return nil }
        if table.codes[Int(v)] != 0 { return .platformDependent }   // `ｩ` もここに入る
        return table.shiftJISOnly[Int(v)] ? .differsByPlatform : .notInShiftJIS
    }

    /// この文字の CP932 バイト列の2バイト目が `0x5C` か（W1）。
    /// 文字のリストは持たず、バイト列で判定する（仕様 §4.4）。
    static func hasTrailing5C(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.value <= 0xFFFF else { return false }
        let code = table.codes[Int(scalar.value)]
        return code > 0xFF && code & 0xFF == 0x5C
    }

    /// CP932 のバイト列。保持できない文字があれば nil。
    static func cp932Bytes(_ name: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(name.utf8.count)
        for scalar in name.unicodeScalars {
            guard scalar.value <= 0xFFFF else { return nil }
            let code = table.codes[Int(scalar.value)]
            if code == 0 { return nil }
            if code > 0xFF { bytes.append(UInt8(code >> 8)) }
            bytes.append(UInt8(code & 0xFF))
        }
        return bytes
    }

    // MARK: - ZIP に書く名前

    /// ZIP 内のパス（`/` 区切り）のバイト列。`path` は `zipPath` で作ったものであること。
    /// CP932 で保持できない文字があれば nil。E2 で停止した項目は書き込まないので、通常は起きない。
    static func encoded(zipPath path: String, options: NameOptions) -> EncodedName? {
        switch options.encoding {
        case .cp932:
            guard let bytes = cp932Bytes(path) else { return nil }
            return EncodedName(bytes: bytes, usesUTF8Flag: false, unicodePathUTF8: Array(path.utf8))
        case .utf8:
            return EncodedName(bytes: Array(path.utf8), usesUTF8Flag: true, unicodePathUTF8: nil)
        }
    }

    /// ZIP 内のパス。各階層の名前を `normalized` で変換して `/` でつなぐ。
    static func zipPath(_ components: [String]) -> String {
        components.map { normalized($0) }.joined(separator: "/")
    }
}
