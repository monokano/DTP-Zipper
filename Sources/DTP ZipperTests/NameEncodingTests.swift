import XCTest
@testable import DTP_Zipper

final class NameEncodingTests: XCTestCase {

    private func scalars(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value) }

    private func bmpScalars() -> [Unicode.Scalar] {
        (UInt32(0x20)...0xFFFF).compactMap { Unicode.Scalar($0) }
    }

    // MARK: - 安全な NFC

    func testNFCSafeComposesDakuten() {
        XCTAssertEqual(scalars(NameEncoding.nfcSafe("か\u{3099}")), [0x304C])
        XCTAssertEqual(scalars(NameEncoding.nfcSafe("ハ\u{309A}")), [0x30D1])
    }

    func testNFCSafeKeepsCompatibilityAndUnifiedIdeographs() {
        // 互換漢字と統合漢字が同じ名前にあっても、両方そのまま残る。
        let name = "\u{F9DC}\u{9686}か\u{3099}"
        XCTAssertEqual(scalars(NameEncoding.nfcSafe(name)), [0xF9DC, 0x9686, 0x304C])
        // 単純な NFC では統合漢字へ化けることの確認。
        XCTAssertEqual(scalars("\u{F9DC}".precomposedStringWithCanonicalMapping), [0x9686])
    }

    func testNormalizedComposes() {
        XCTAssertEqual(scalars(NameEncoding.normalized("か\u{3099}")), [0x304C])
    }

    /// CP932 のバイト列を持つか。保持できる文字より広い。
    private func hasCP932Bytes(_ scalar: Unicode.Scalar) -> Bool {
        NameEncoding.cp932Bytes(String(scalar)) != nil
    }

    // MARK: - 文字の集合（仕様 §4.1 の実測値）

    func testPreservedCharacterCounts() {
        let all = bmpScalars()
        XCTAssertEqual(all.filter { hasCP932Bytes($0) }.count, 7485)
        XCTAssertEqual(all.filter { NameEncoding.isPreservedInCP932($0) }.count, 7029)
    }

    func testCharacterExamples() {
        typealias Row = (chars: String, preserved: Bool, hasBytes: Bool)
        let rows: [Row] = [
            ("漢字かな、。ｱﾞ~", true, true),
            ("①㈱髙﨑Ⅸ№～－∥―ｩ", false, true),
            ("〜−—‖¢£¬‾", false, false),
            ("é", false, false),
            ("\u{E000}\u{F8FF}", false, false),
            ("\u{F9DC}\u{F929}\u{FA10}", false, true),   // CP932 のバイト列はあるが保持できない互換漢字
            ("\u{F900}", false, false),      // CP932 にない互換漢字
        ]
        for row in rows {
            for scalar in row.chars.unicodeScalars {
                let label = "U+\(String(scalar.value, radix: 16, uppercase: true))"
                XCTAssertEqual(NameEncoding.isPreservedInCP932(scalar), row.preserved, label)
                XCTAssertEqual(hasCP932Bytes(scalar), row.hasBytes, label)
            }
        }
        // BMP 外
        for name in ["𠮷", "😀"] {
            let scalar = name.unicodeScalars.first!
            XCTAssertFalse(NameEncoding.isPreservedInCP932(scalar))
            XCTAssertFalse(hasCP932Bytes(scalar))
        }
    }

    func testCharactersChangedByPlainNFCArePreserved() throws {
        // CP932 にある文字のうち、単純な NFC で変わるのは次の23字。安全な NFC では変わらず、元のバイト列へ戻る。
        let changed = bmpScalars().filter {
            hasCP932Bytes($0)
                && scalars(String($0).precomposedStringWithCanonicalMapping) != [$0.value]
        }
        XCTAssertEqual(changed.map(\.value), [0x212B, 0xF929, 0xF9DC, 0xFA10, 0xFA12] + Array(0xFA15...0xFA1E) + [0xFA20, 0xFA22, 0xFA25, 0xFA26] + Array(0xFA2A...0xFA2D))
        for scalar in changed {
            let name = NameEncoding.nfcSafe(String(scalar))
            XCTAssertEqual(scalars(name), [scalar.value])
            let bytes = try XCTUnwrap(NameEncoding.cp932Bytes(name))
            let back = try XCTUnwrap(String(data: Data(bytes), encoding: Self.cp932))
            XCTAssertEqual(scalars(back), [scalar.value])
        }
    }

    // MARK: - 5C

    static let all5C = "Ы―Ⅸソ予偆兔十喀噂圭媾彌拿暴曾杤構欺歃浬濬申畚砡禄秉箪綵能臀藹蚕表觸貼軆鐔饅鷭"

    func testTrailing5CCharactersAreExactly40() {
        let expected = Set(Self.all5C.unicodeScalars)
        XCTAssertEqual(expected.count, 40)
        let found = bmpScalars().filter(NameEncoding.hasTrailing5C)
        XCTAssertEqual(Set(found), expected)
        for scalar in found {
            XCTAssertEqual(NameEncoding.cp932Bytes(String(scalar))?.last, 0x5C)
        }
        // 保持できるのは 36 字。
        XCTAssertEqual(found.filter { NameEncoding.isPreservedInCP932($0) }.count, 36)
    }

    func testBackslashIsNotTrailing5C() {
        // 1バイトの 0x5C と、1バイト目が 0x5C のように見えるものを含まないこと。
        XCTAssertFalse(NameEncoding.hasTrailing5C("\\"))
        XCTAssertFalse(NameEncoding.hasTrailing5C("A"))
    }

    // MARK: - バイト列

    private static let cp932 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0420))

    func testCP932BytesMatchFoundationForAllCharacters() {
        for scalar in bmpScalars() where hasCP932Bytes(scalar) {
            let s = String(scalar)
            XCTAssertEqual(NameEncoding.cp932Bytes(s), s.data(using: Self.cp932).map { Array($0) },
                           "U+\(String(scalar.value, radix: 16, uppercase: true))")
        }
    }

    func testCP932BytesOfMixedName() throws {
        let name = "A表_①ｱ.txt"
        let bytes = try XCTUnwrap(NameEncoding.cp932Bytes(name))
        XCTAssertEqual(bytes, [0x41, 0x95, 0x5C, 0x5F, 0x87, 0x40, 0xB1, 0x2E, 0x74, 0x78, 0x74])
        // 選択したエンコーディングで読むと元の名前に戻る（名称の保持）。
        let back = try XCTUnwrap(String(data: Data(bytes), encoding: Self.cp932))
        XCTAssertEqual(scalars(back), scalars(name))
    }

    func testCP932BytesFailsOnUnpreservedCharacter() {
        for name in ["〜", "é", "𠮷", "\u{E000}", "\u{F900}", "a\u{3099}"] {
            XCTAssertNil(NameEncoding.cp932Bytes(name), name)
        }
    }

    func testEncodedCP932HasUnicodePathAndNoFlag() throws {
        let options = NameOptions(encoding: .cp932)
        let path = NameEncoding.zipPath(["フォルダ", "か\u{3099}.txt"])
        XCTAssertEqual(scalars(path), scalars("フォルダ/が.txt"))
        let encoded = try XCTUnwrap(NameEncoding.encoded(zipPath: path, options: options))
        XCTAssertFalse(encoded.usesUTF8Flag)
        XCTAssertEqual(encoded.unicodePathUTF8, Array("フォルダ/が.txt".precomposedStringWithCanonicalMapping.utf8))
        XCTAssertEqual(encoded.bytes, NameEncoding.cp932Bytes(path))
    }

    func testEncodedUTF8SetsFlagAndComposes() throws {
        let options = NameOptions(encoding: .utf8)
        let path = NameEncoding.zipPath(["か\u{3099}𠮷😀.txt"])
        let encoded = try XCTUnwrap(NameEncoding.encoded(zipPath: path, options: options))
        XCTAssertTrue(encoded.usesUTF8Flag)
        XCTAssertNil(encoded.unicodePathUTF8)
        XCTAssertEqual(encoded.bytes, Array("\u{304C}𠮷😀.txt".utf8))
    }

    func testEncodedCP932ReturnsNilOnUnpreservedCharacter() {
        XCTAssertNil(NameEncoding.encoded(zipPath: "〜.txt", options: NameOptions(encoding: .cp932)))
    }
}
