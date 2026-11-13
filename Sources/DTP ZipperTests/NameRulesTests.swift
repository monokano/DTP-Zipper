import XCTest
@testable import DTP_Zipper

final class NameRulesTests: XCTestCase {

    // 3つの設定と、UTF-8 の合成 OFF。
    private static let cp932 = NameOptions(encoding: .cp932)
    private static let utf8 = NameOptions(encoding: .utf8)
    private static let allModes = [cp932, utf8]

    /// 最上位のファイルとして検査し、見つかった規則を返す。
    private func rules(_ name: String, _ options: NameOptions, isDirectory: Bool = false) -> [NameRule] {
        let item = NameCheckItem(path: [name], isDirectory: isDirectory)
        return NameRules.check([item], options: options).map(\.rule)
    }

    /// 5C の警告が出ないようフォルダの中に置いて検査する。
    private func nestedRules(_ name: String, _ options: NameOptions) -> [NameRule] {
        let items = [NameCheckItem(path: ["f"], isDirectory: true), NameCheckItem(path: ["f", name])]
        return NameRules.check(items, options: options).map(\.rule)
    }

    // MARK: - 問題なし

    func testPlainNamesPassInAllModes() {
        for options in Self.allModes {
            for name in ["普通の名前.indd", "A b_c-1.txt", "~$file.docx", "$ ( ) & # %", "あいう", ".hidden", "CONSOLE.txt", "COM0", "LPT10", "aux_file.txt"] {
                XCTAssertEqual(rules(name, options), [], "\(name) \(options)")
            }
        }
    }

    // MARK: - E1

    func testForbiddenCharactersInAllModes() {
        for options in Self.allModes {
            for ch in ["/", "\\", "¥", "<", ">", "?", "\"", "|", ":", "*"] {
                // ¥ と \ が E2 に重ならないこと（1文字につき1件）。
                XCTAssertEqual(rules("a\(ch)b", options), [.forbiddenCharacter], "\(ch) \(options)")
            }
        }
    }

    // MARK: - E2

    func testPreservationByMode() {
        typealias Row = (chars: String, cp932: Bool, utf8: Bool)
        let rows: [Row] = [
            ("漢字かな、ｱ~", true, true),
            ("①㈱髙﨑Ⅸ№～－∥―ｩ", false, true),
            ("〜−—‖¢£¬‾", false, true),      // §4.3 の表のうち ¥ 以外の8文字（¥ は E1）
            ("é", false, true),
            ("\u{E000}\u{F8FF}", false, true),
        ]
        for row in rows {
            for ch in row.chars.map(String.init) {
                let name = "a\(ch)b"
                XCTAssertEqual(nestedRules(name, Self.cp932).contains(.notPreserved), !row.cp932, "cp932 \(ch)")
                XCTAssertEqual(nestedRules(name, Self.utf8).contains(.notPreserved), !row.utf8, "utf8 \(ch)")
            }
        }
        for name in ["𠮷", "😀"] {
            XCTAssertEqual(nestedRules(name, Self.cp932), [.notPreserved])
            XCTAssertEqual(nestedRules(name, Self.utf8), [])
        }
    }

    /// ヘルプ「エンコーディング」に挙げた文字が、見出しどおりの種類になること。
    func testNotPreservedKinds() {
        let rows: [(chars: String, kind: NotPreservedKind)] = [
            ("①㈱髙﨑Ⅸ№～－∥―ｩ\u{F9DC}", .platformDependent),
            ("〜−—‖¢£¬‾", .differsByPlatform),
            ("𠮷é😀\u{F900}", .notInShiftJIS),
            ("\u{E000}\u{F8FF}", .userDefined),
        ]
        for row in rows {
            for ch in row.chars.unicodeScalars {
                let issues = NameRules.check([NameCheckItem(path: ["f", "a\(ch)b"])], options: Self.cp932)
                XCTAssertEqual(issues.map(\.notPreservedKind), [row.kind], "U+\(String(ch.value, radix: 16))")
            }
        }
        for ch in "漢字かな、ｱ~".unicodeScalars {
            XCTAssertNil(NameEncoding.notPreservedKind(ch), "\(ch)")
        }
        // 保持できない文字は、必ずいずれかの種類になる。
        for v in UInt32(1)...0xFFFF {
            guard let scalar = Unicode.Scalar(v) else { continue }
            XCTAssertEqual(NameEncoding.notPreservedKind(scalar) == nil, NameEncoding.isPreservedInCP932(scalar), "U+\(String(v, radix: 16))")
        }
    }

    /// 種類の違う文字が混ざった名前は、種類ごとに分けて報告する。
    func testNotPreservedKindsAreReportedSeparately() {
        let issues = NameRules.check([NameCheckItem(path: ["f", "a\u{E000}〜①é‾"])], options: Self.cp932)
        XCTAssertEqual(issues.map(\.rule), [.notPreserved, .notPreserved, .notPreserved, .notPreserved])
        XCTAssertEqual(issues.map(\.notPreservedKind), [.platformDependent, .differsByPlatform, .notInShiftJIS, .userDefined])
        XCTAssertEqual(issues.map(\.scalarOffsets), [[3], [2, 5], [4], [1]])
        // E6 があるときの並べ替えでも、種類の順が保たれる。
        let items = [NameCheckItem(path: ["A①〜"]), NameCheckItem(path: ["a①〜"])]
        XCTAssertEqual(NameRules.check(items, options: Self.cp932).filter { $0.itemIndex == 0 }.map(\.notPreservedKind),
                       [.platformDependent, .differsByPlatform, nil])
    }

    func testNFDIsComposedBeforeJudging() {
        XCTAssertEqual(rules("か\u{3099}.txt", Self.cp932), [])
        // 合成できない結合文字は CP932 で保持できない。
        XCTAssertEqual(rules("a\u{3099}.txt", Self.cp932), [.notPreserved])
    }

    func testCompatibilityIdeographInCP932() {
        // CP932 にある互換漢字も、ない互換漢字も止まる。
        XCTAssertEqual(rules("\u{F9DC}.txt", Self.cp932), [.notPreserved])
        XCTAssertEqual(rules("\u{F900}.txt", Self.cp932), [.notPreserved])
    }

    func testOffsetsPointAtOffendingCharacters() throws {
        let issues = NameRules.check([NameCheckItem(path: ["a〜b‾"])], options: Self.cp932)
        let issue = try XCTUnwrap(issues.first)
        XCTAssertEqual(issue.rule, .notPreserved)
        XCTAssertEqual(issue.scalarOffsets, [1, 3])
    }

    // MARK: - E3

    func testControlCharactersInAllModes() {
        let controls: [UInt32] = [0x01, 0x0D, 0x1F, 0x7F, 0x80, 0x9F, 0x061C, 0x200B, 0x200F,
                                  0x2028, 0x202F, 0x2060, 0x2066, 0x2069]
        for options in Self.allModes {
            for value in controls {
                let name = "a\(Character(Unicode.Scalar(value)!))b"
                XCTAssertEqual(rules(name, options), [.controlCharacter],
                               "U+\(String(value, radix: 16)) \(options)")
            }
        }
        // 範囲のすぐ外は制御文字ではない。
        for value: UInt32 in [0x200A, 0x2010, 0x2027, 0x2030, 0x205F, 0x2061, 0x2065, 0x206A] {
            let name = "a\(Character(Unicode.Scalar(value)!))b"
            XCTAssertFalse(rules(name, Self.utf8).contains(.controlCharacter), "U+\(String(value, radix: 16))")
        }
    }

    // MARK: - E4

    func testReservedNames() {
        var names = ["CON", "PRN", "AUX", "NUL", "con", "Nul", "CON.txt", "aux.tar.gz", "CON .txt"]
        for n in 1...9 {
            names += ["COM\(n)", "LPT\(n)", "com\(n).log"]
        }
        for options in Self.allModes {
            for name in names {
                XCTAssertTrue(rules(name, options).contains(.reservedName), "\(name) \(options)")
            }
        }
    }

    // MARK: - E5

    func testTrailingSpaceOrPeriod() throws {
        for options in Self.allModes {
            for name in ["x ", "x.", "x. .", "folder "] {
                XCTAssertEqual(rules(name, options), [.trailingSpaceOrPeriod], "\(name)")
            }
            for name in ["x y", "x.y", " x", ".x"] {
                XCTAssertEqual(rules(name, options), [], "\(name)")
            }
        }
        let issue = try XCTUnwrap(NameRules.check([NameCheckItem(path: ["a b. "])], options: Self.cp932).first)
        XCTAssertEqual(issue.scalarOffsets, [3, 4])
    }

    func testEveryLevelIsCheckedThroughItsOwnItem() {
        let items = [NameCheckItem(path: ["ok"], isDirectory: true),
                     NameCheckItem(path: ["ok", "bad."], isDirectory: true),
                     NameCheckItem(path: ["ok", "bad.", "file.txt"])]
        let issues = NameRules.check(items, options: Self.cp932)
        XCTAssertEqual(issues.map(\.rule), [.trailingSpaceOrPeriod])
        XCTAssertEqual(issues.map(\.itemIndex), [1])
    }

    // MARK: - E6

    private func collidedIndexes(_ paths: [[String]], _ options: NameOptions) -> [Int] {
        NameRules.check(paths.map { NameCheckItem(path: $0) }, options: options)
            .filter { $0.rule == .nameCollision }.map(\.itemIndex)
    }

    func testCollisionIgnoresCase() {
        for options in Self.allModes {
            XCTAssertEqual(collidedIndexes([["A.txt"], ["a.txt"], ["b.txt"]], options), [0, 1])
            XCTAssertEqual(collidedIndexes([["d", "A.txt"], ["d", "a.TXT"]], options), [0, 1])
            // 別の階層なら衝突しない。
            XCTAssertEqual(collidedIndexes([["d", "A.txt"], ["e", "a.txt"], ["a.txt"]], options), [])
        }
    }

    func testCollisionComparesAsNFC() {
        XCTAssertEqual(collidedIndexes([["か\u{3099}"], ["が"]], Self.utf8), [0, 1])
    }

    func testCollisionDoesNotConfuseDifferentCharacters() {
        // 全角と半角、ひらがなとカタカナは別の名前。
        XCTAssertEqual(collidedIndexes([["a"], ["ａ"]], Self.utf8), [])
        XCTAssertEqual(collidedIndexes([["か"], ["カ"]], Self.utf8), [])
        XCTAssertEqual(collidedIndexes([["ß"], ["ss"]], Self.utf8), [])
    }

    func testExcludedLinksDoNotCollide() {
        let items = [NameCheckItem(path: ["A"]), NameCheckItem(path: ["a"], isExcludedLink: true)]
        XCTAssertEqual(NameRules.check(items, options: Self.cp932).map(\.rule), [.excludedLink])
    }

    func testIssuesAreOrderedByItemThenRule() {
        let items = [NameCheckItem(path: ["A."]), NameCheckItem(path: ["z"]), NameCheckItem(path: ["a."])]
        let issues = NameRules.check(items, options: Self.cp932)
        XCTAssertEqual(issues.map(\.itemIndex), [0, 0, 2, 2])
        XCTAssertEqual(issues.map(\.rule), [.trailingSpaceOrPeriod, .nameCollision, .trailingSpaceOrPeriod, .nameCollision])
    }

    // MARK: - E7

    private var fontFolder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("検証用/Windows非対応フォント")
    }

    func testRealFontFilesAreResourceForkOnly() {
        for name in ["Futura", "Geneva", "FuturBol", "PifonSym", "PifonUt1"] {
            let url = fontFolder.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), name)
            XCTAssertTrue(NameRules.isResourceForkOnly(at: url), name)
            XCTAssertTrue(NameRules.isFont(at: url), name)
        }
    }

    func testEmptyAndNormalFilesAreNotResourceForkOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let empty = dir.appendingPathComponent("empty")
        let normal = dir.appendingPathComponent("normal.txt")
        try Data().write(to: empty)
        try Data("x".utf8).write(to: normal)
        XCTAssertFalse(NameRules.isResourceForkOnly(at: empty))
        XCTAssertFalse(NameRules.isResourceForkOnly(at: normal))
        XCTAssertFalse(NameRules.isFont(at: normal))
    }

    func testResourceForkOnlyRule() {
        for options in Self.allModes {
            XCTAssertEqual(NameRules.check([NameCheckItem(path: ["f"], isResourceForkOnly: true)], options: options).map(\.rule),
                           [.resourceForkOnly])
            XCTAssertEqual(NameRules.check([NameCheckItem(path: ["f"], isResourceForkOnly: true, isFont: true)], options: options).map(\.rule),
                           [.fontResourceForkOnly])
            XCTAssertEqual(NameRules.check([NameCheckItem(path: ["f"], isDirectory: true, isResourceForkOnly: true)], options: options).map(\.rule),
                           [])
        }
    }

    // MARK: - W1

    func testTrailing5CAllCharactersAtTopLevel() {
        for ch in NameEncodingTests.all5C.unicodeScalars {
            let name = "\(ch).txt"
            XCTAssertTrue(rules(name, Self.cp932).contains(.trailing5C), "\(ch)")
            XCTAssertEqual(rules(name, Self.cp932).contains(.notPreserved), !NameEncoding.isPreservedInCP932(ch), "\(ch)")
            XCTAssertEqual(rules(name, Self.utf8), [], "\(ch)")
        }
    }

    func testTrailing5COnlyForTopLevelFiles() {
        XCTAssertEqual(rules("表.txt", Self.cp932), [.trailing5C])
        XCTAssertEqual(rules("表", Self.cp932, isDirectory: true), [])
        XCTAssertEqual(nestedRules("表.txt", Self.cp932), [])
        XCTAssertFalse(rules("\u{2014}.txt", Self.cp932).contains(.trailing5C))   // `—` は CP932 のバイト列を持つが往復できない
    }

    func testTrailing5COffsets() throws {
        let issue = try XCTUnwrap(NameRules.check([NameCheckItem(path: ["a表b能"])], options: Self.cp932).first)
        XCTAssertEqual(issue.rule, .trailing5C)
        XCTAssertEqual(issue.scalarOffsets, [1, 3])
    }

    // MARK: - W2

    func testLongPathBoundary() {
        let folder = String(repeating: "a", count: 100)
        let under = [folder, String(repeating: "b", count: 98)]     // 100 + 1 + 98 = 199
        let at = [folder, String(repeating: "b", count: 99)]        // 200
        for options in Self.allModes {
            XCTAssertEqual(NameRules.check([NameCheckItem(path: under)], options: options).map(\.rule), [])
            XCTAssertEqual(NameRules.check([NameCheckItem(path: at)], options: options).map(\.rule), [.longPath])
        }
    }

    func testLongPathCountsAfterNormalization() {
        // NFD のままでは長いパスになる名前も、合成後の文字数で数える。
        let name = String(repeating: "か\u{3099}", count: 100)
        XCTAssertFalse(rules(name, Self.utf8).contains(.longPath))
    }

    // MARK: - W3

    func testExcludedLinkReportsOnlyW3() {
        for options in Self.allModes {
            let item = NameCheckItem(path: ["bad:〜."], isExcludedLink: true)
            XCTAssertEqual(NameRules.check([item], options: options).map(\.rule), [.excludedLink])
        }
    }

    // MARK: - W4

    func testCompatibilityIdeographWarningInUTF8Only() {
        XCTAssertEqual(rules("\u{F9DC}.txt", Self.utf8), [.compatibilityIdeograph])
        XCTAssertEqual(rules("\u{2F800}.txt", Self.utf8), [.compatibilityIdeograph])
        // 正規化で変わらない字は対象外。
        XCTAssertEqual(rules("﨑.txt", Self.utf8), [])
        XCTAssertEqual(rules("\u{9686}.txt", Self.utf8), [])
        XCTAssertFalse(rules("\u{F9DC}.txt", Self.cp932).contains(.compatibilityIdeograph))
    }

    // MARK: - 停止と警告

    func testSeverity() {
        let stops: [NameRule] = [.forbiddenCharacter, .notPreserved, .controlCharacter, .reservedName,
                                 .trailingSpaceOrPeriod, .nameCollision, .fontResourceForkOnly, .resourceForkOnly]
        for rule in NameRule.allCases {
            XCTAssertEqual(rule.isStop, stops.contains(rule), rule.rawValue)
        }
    }

    // MARK: - 全項目の検査

    func testAllProblemsAreReportedTogether() {
        let issues = rules("CON〜:", Self.cp932)
        XCTAssertEqual(issues, [.forbiddenCharacter, .notPreserved])    // `CON〜:` の基本名は予約名ではない
        XCTAssertEqual(rules("CON:. ", Self.cp932), [.forbiddenCharacter, .trailingSpaceOrPeriod])
    }
}
