import Foundation

/// 走査で見つけた項目。
nonisolated struct ScannedItem: Sendable {
    var url: URL
    /// 検査に渡す情報。`check.path` が ZIP のルートからの各階層の元の名前。
    var check: NameCheckItem
    /// データフォークのサイズ。
    var size: UInt64 = 0
    var attributes: ZipEntryAttributes

    var isIncluded: Bool { !check.isExcludedLink }
}

/// 走査で起きるエラー。
nonisolated enum ItemScannerError: Error {
    case readFailed(URL, underlying: Error)
}

/// ZIP に入れる項目の一覧を作る（仕様 §3）。UI に依存しない。
nonisolated enum ItemScanner {

    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey,
        .isHiddenKey, .contentModificationDateKey,
    ]

    /// 同じ階層は Finder 順、フォルダは中身より先に並ぶ。リンクなどの除外した項目も、警告のために含める。
    /// - Parameter onItem: 項目を1つ見つけるたびに、ここまでの件数を受け取る。
    static func scan(_ urls: [URL], onItem: (Int) -> Void = { _ in }) throws -> [ScannedItem] {
        var items: [ScannedItem] = []
        for url in sorted(urls) {
            try Task.checkCancellation()
            try visit(url, parentPath: [], into: &items, onItem: onItem)
        }
        return items
    }

    private static func visit(_ url: URL, parentPath: [String], into items: inout [ScannedItem], onItem: (Int) -> Void) throws {
        let values: URLResourceValues
        var status = stat()
        do {
            values = try url.resourceValues(forKeys: resourceKeys)
            guard lstat(url.path, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            throw ItemScannerError.readFailed(url, underlying: error)
        }

        let isTopLevel = parentPath.isEmpty
        // フォルダの中の不可視項目は黙って除外する。`isHidden` は `.` で始まる名前も含む。
        // ドロップした項目そのものは含める（仕様 §3）。
        if !isTopLevel && values.isHidden == true { return }

        let path = parentPath + [url.lastPathComponent]
        let attributes = ZipEntryAttributes(
            modificationDate: values.contentModificationDate ?? Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)),
            posixPermissions: UInt16(status.st_mode) & 0o7777)

        // リンク、エイリアス、通常のファイルでもフォルダでもないもの（FIFO など）は ZIP に入れず、警告で知らせる。
        let isLink = values.isSymbolicLink == true || values.isAliasFile == true
        let isDirectory = values.isDirectory == true
        guard !isLink, isDirectory || values.isRegularFile == true else {
            var check = NameCheckItem(path: path)
            check.isExcludedLink = true
            items.append(ScannedItem(url: url, check: check, attributes: attributes))
            onItem(items.count)
            return
        }

        if isDirectory {
            items.append(ScannedItem(url: url, check: NameCheckItem(path: path, isDirectory: true), attributes: attributes))
            onItem(items.count)
            try Task.checkCancellation()

            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(resourceKeys))
            } catch {
                throw ItemScannerError.readFailed(url, underlying: error)
            }
            for child in sorted(children) {
                try visit(child, parentPath: path, into: &items, onItem: onItem)
            }
        } else {
            let isResourceForkOnly = NameRules.isResourceForkOnly(at: url)
            let check = NameCheckItem(path: path, isResourceForkOnly: isResourceForkOnly,
                                      isFont: isResourceForkOnly && NameRules.isFont(at: url))
            items.append(ScannedItem(url: url, check: check, size: UInt64(status.st_size), attributes: attributes))
            onItem(items.count)
        }
    }

    /// Finder 順。比べて同じなら、順序を一定にするためスカラーで比べる。
    private static func sorted(_ urls: [URL]) -> [URL] {
        urls.sorted { a, b in
            let nameA = a.lastPathComponent, nameB = b.lastPathComponent
            switch nameA.localizedStandardCompare(nameB) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return nameA.unicodeScalars.lexicographicallyPrecedes(nameB.unicodeScalars)
            }
        }
    }
}
