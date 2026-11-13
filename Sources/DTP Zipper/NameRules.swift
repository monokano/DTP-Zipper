import Foundation
import UniformTypeIdentifiers

/// 検査の規則（仕様 §4.3、§4.4）。
nonisolated enum NameRule: String, Sendable, CaseIterable {
    case forbiddenCharacter         // E1
    case notPreserved               // E2
    case controlCharacter           // E3
    case reservedName               // E4
    case trailingSpaceOrPeriod      // E5
    case nameCollision              // E6
    case fontResourceForkOnly       // E7（フォント）
    case resourceForkOnly           // E7（フォントと認識できないもの）
    case trailing5C                 // W1
    case longPath                   // W2
    case excludedLink               // W3
    case compatibilityIdeograph     // W4

    /// 停止（修正するまで圧縮できない）か。false は警告。
    var isStop: Bool {
        switch self {
        case .forbiddenCharacter, .notPreserved, .controlCharacter, .reservedName,
             .trailingSpaceOrPeriod, .nameCollision, .fontResourceForkOnly, .resourceForkOnly:
            return true
        case .trailing5C, .longPath, .excludedLink, .compatibilityIdeograph:
            return false
        }
    }

    /// E7 か。
    var isResourceForkOnly: Bool {
        self == .fontResourceForkOnly || self == .resourceForkOnly
    }
}

/// 検査する項目。
nonisolated struct NameCheckItem: Sendable {
    /// ZIP のルートからの各階層の元の名前。最後が項目自身の名前。
    var path: [String]
    var isDirectory = false
    /// `NameRules.isResourceForkOnly(at:)` の結果。
    var isResourceForkOnly = false
    /// `NameRules.isFont(at:)` の結果。E7 の表示を分けるために使う。
    var isFont = false
    /// シンボリックリンクかエイリアス。ZIP には入らない（W3）。
    var isExcludedLink = false

    /// ドロップした項目そのものか。
    var isTopLevel: Bool { path.count == 1 }
}

/// 見つかった問題。
nonisolated struct NameIssue: Sendable {
    let rule: NameRule
    /// `NameRules.check` に渡した配列の添字。
    let itemIndex: Int
    /// 変換後の項目名。
    let name: String
    /// 問題の文字の位置（`name` の Unicode スカラーの添字）。名前全体の問題では空。
    let scalarOffsets: [Int]
    /// E2 の文字の種類。1つの名前に複数の種類があれば、種類ごとに別の問題として報告する。
    var notPreservedKind: NotPreservedKind? = nil
}

/// 名前の判定（UI に依存しない）。
nonisolated enum NameRules {

    static let longPathThreshold = 200

    /// すべての項目を検査する。項目の順に、1項目につき規則の順に並ぶ。
    static func check(_ items: [NameCheckItem], options: NameOptions) -> [NameIssue] {
        var issues: [NameIssue] = []
        for (index, item) in items.enumerated() {
            issues += check(item, at: index, options: options)
        }
        let collided = collisions(in: items, options: options)
        if !collided.isEmpty {
            // E6 を各項目の問題の並びへ入れる。
            for index in collided {
                let name = NameEncoding.normalized(items[index].path.last ?? "")
                issues.append(NameIssue(rule: .nameCollision, itemIndex: index, name: name, scalarOffsets: []))
            }
            let order = Dictionary(uniqueKeysWithValues: NameRule.allCases.enumerated().map { ($1, $0) })
            let kindOrder = Dictionary(uniqueKeysWithValues: NotPreservedKind.allCases.enumerated().map { ($1, $0) })
            func key(_ issue: NameIssue) -> (Int, Int, Int) {
                (issue.itemIndex, order[issue.rule]!, issue.notPreservedKind.map { kindOrder[$0]! } ?? 0)
            }
            issues.sort { key($0) < key($1) }
        }
        return issues
    }

    private static func check(_ item: NameCheckItem, at index: Int, options: NameOptions) -> [NameIssue] {
        let name = NameEncoding.normalized(item.path.last ?? "")

        func issue(_ rule: NameRule, _ offsets: [Int] = []) -> NameIssue {
            NameIssue(rule: rule, itemIndex: index, name: name, scalarOffsets: offsets)
        }

        // ZIP に入らない項目は W3 のみ。検査の対象と ZIP の中身を一致させる（仕様 §3）。
        if item.isExcludedLink { return [issue(.excludedLink)] }

        var issues: [NameIssue] = []
        let scalars = Array(name.unicodeScalars)
        func offsets(where predicate: (Unicode.Scalar) -> Bool) -> [Int] {
            scalars.indices.filter { predicate(scalars[$0]) }
        }

        // E1
        let forbidden = offsets(where: isForbidden)
        if !forbidden.isEmpty { issues.append(issue(.forbiddenCharacter, forbidden)) }

        // E2。E1 と E3 で報告する文字は重ねて報告しない。文字の種類ごとに分けて報告する。
        if options.encoding == .cp932 {
            for kind in NotPreservedKind.allCases {
                let notPreserved = offsets {
                    !isForbidden($0) && !isControl($0)
                        && NameEncoding.notPreservedKind($0) == kind
                }
                if !notPreserved.isEmpty {
                    var found = issue(.notPreserved, notPreserved)
                    found.notPreservedKind = kind
                    issues.append(found)
                }
            }
        }

        // E3
        let control = offsets(where: isControl)
        if !control.isEmpty { issues.append(issue(.controlCharacter, control)) }

        // E4
        if isReserved(name) { issues.append(issue(.reservedName)) }

        // E5
        if let last = scalars.last, last == " " || last == "." {
            var start = scalars.count - 1
            while start > 0, scalars[start - 1] == " " || scalars[start - 1] == "." { start -= 1 }
            issues.append(issue(.trailingSpaceOrPeriod, Array(start..<scalars.count)))
        }

        // E7
        if !item.isDirectory && item.isResourceForkOnly {
            issues.append(issue(item.isFont ? .fontResourceForkOnly : .resourceForkOnly))
        }

        // W1
        if options.encoding == .cp932 && item.isTopLevel && !item.isDirectory {
            let trailing5C = offsets(where: NameEncoding.hasTrailing5C)
            if !trailing5C.isEmpty { issues.append(issue(.trailing5C, trailing5C)) }
        }

        // W2。Windows の 260 文字制限と同じく UTF-16 で数える。
        if NameEncoding.zipPath(item.path).utf16.count >= longPathThreshold {
            issues.append(issue(.longPath))
        }

        // W4
        if options.encoding == .utf8 {
            let compatibility = offsets(where: isCompatibilityIdeograph)
            if !compatibility.isEmpty { issues.append(issue(.compatibilityIdeograph, compatibility)) }
        }

        return issues
    }

    // MARK: - 文字の判定

    private static let forbiddenCharacters = Set<Unicode.Scalar>(["/", "\\", "¥", "<", ">", "?", "\"", "|", ":", "*"])

    private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        forbiddenCharacters.contains(scalar)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0000...0x001F, 0x007F...0x009F, 0x061C, 0x200B...0x200F,
             0x2028...0x202F, 0x2060, 0x2066...0x2069:
            return true
        default:
            return false
        }
    }

    /// CJK 互換漢字のうち、正規化で別の字に変わるもの。
    /// `﨑`（U+FA11）のように同じブロックでも正規化で変わらない字は含めない。
    private static func isCompatibilityIdeograph(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0xF900...0xFAFF, 0x2F800...0x2FA1F:
            return !String(scalar).precomposedStringWithCanonicalMapping.unicodeScalars
                .elementsEqual(String(scalar).unicodeScalars)
        default:
            return false
        }
    }

    // MARK: - 名前全体の判定

    private static let reservedNames: Set<String> = {
        var names: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for n in 1...9 {
            names.insert("COM\(n)")
            names.insert("LPT\(n)")
        }
        return names
    }()

    /// 大文字小文字と拡張子の有無を問わない。`CON .txt` のように拡張子の前の空白も無視する。
    private static func isReserved(_ name: String) -> Bool {
        var base = Substring(name.prefix { $0 != "." })
        while base.last == " " { base.removeLast() }
        return reservedNames.contains(base.uppercased())
    }

    /// 同じ階層で名前が一致する項目の添字（E6）。ZIP に入らない項目は対象にしない。
    private static func collisions(in items: [NameCheckItem], options: NameOptions) -> [Int] {
        // 親の階層はそのまま比べる。親どうしが衝突していれば、親の項目のほうで報告される。
        var groups: [[String]: [Int]] = [:]
        for (index, item) in items.enumerated() where !item.isExcludedLink {
            guard let name = item.path.last else { continue }
            groups[Array(item.path.dropLast()) + [collisionKey(name)], default: []].append(index)
        }
        return groups.values.filter { $0.count > 1 }.flatMap { $0 }.sorted()
    }

    /// 単純な NFC にそろえて比べる（macOS で解凍すると同じ名前になるため）。
    private static func collisionKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    // MARK: - ファイルの判定

    private static let resourceForkKeys: Set<URLResourceKey> = [.fileSizeKey, .totalFileSizeKey, .contentTypeKey]

    /// リソースフォークのみのファイルか（E7）。データフォークが 0 バイトでリソースフォークがあるファイル、
    /// および種類がフォントスーツケースのファイル。
    static func isResourceForkOnly(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: resourceForkKeys) else { return false }
        let dataSize = values.fileSize ?? 0
        let totalSize = values.totalFileSize ?? 0
        if dataSize == 0 && totalSize > 0 { return true }
        return values.contentType?.conforms(to: fontSuitcase) ?? false
    }

    private static let fontSuitcase = UTType(importedAs: "com.apple.font-suitcase")

    /// 種類がフォントか。スーツケースと PostScript Type 1 のプリンタフォントも含む。
    static func isFont(at url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey])
        return values?.contentType?.conforms(to: .font) ?? false
    }
}
