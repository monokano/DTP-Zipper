import Foundation

/// 処理の進捗。
nonisolated enum ZipJobProgress: Sendable {
    /// 走査中。見つけた項目の数。
    case scanning(itemCount: Int)
    /// 圧縮中。全体のバイト数基準。`path` は処理中の ZIP 内のパス。
    case compressing(completedBytes: UInt64, totalBytes: UInt64, path: String)
}

/// 処理で起きるエラー。`ZipWriterError` と `ItemScannerError` はそのまま通す。
nonisolated enum ZipJobError: Error {
    /// 保存先に書き込めない。保存先を選び直して `compress` を呼び直す（仕様 §5.1）。
    case destinationNotWritable(URL, underlying: Error)
    /// 検査で停止した項目があるので圧縮できない。
    case hasStops
    /// ZIP に入れる項目がない。
    case noItems
    /// 検査の後に状況が変わり、名前をバイト列にできない。
    case nameNotEncodable(String)
}

/// 検査の結果。
nonisolated struct ZipInspection: Sendable {
    let options: NameOptions
    let items: [ScannedItem]
    /// 停止を先に、その中は Finder 順に並ぶ。`itemIndex` は `items` の添字（仕様 §6.2）。
    let issues: [NameIssue]
    /// ZIP の保存先の既定値（先頭項目の親フォルダ）。項目がなければ nil。
    let defaultDestination: URL?
    /// 拡張子を除いた ZIP の名前。
    let archiveBaseName: String
    /// ZIP に入れる先頭の項目（`defaultDestination` の基になった項目）。Finder で ZIP をこの項目に重ねて置く。
    var firstItem: URL? = nil

    var hasStops: Bool { issues.contains { $0.rule.isStop } }
    var hasWarnings: Bool { issues.contains { !$0.rule.isStop } }
    /// すべて除外されて ZIP に入れる項目がない（仕様 §3）。
    var isEmpty: Bool { !items.contains(where: \.isIncluded) }
    var totalBytes: UInt64 { items.reduce(0) { $0 + $1.size } }
}

/// 走査、検査、圧縮の進行管理（UI に依存しない）。
///
/// 重い処理は呼び出し元のアクターの外で行う。`Task` をキャンセルすると `CancellationError` で中止し、
/// 一時ファイルを削除する。
nonisolated struct ZipJob: Sendable {

    /// ドロップされた項目。名前を直すと URL は無効になるので、ブックマークで追跡する（仕様 §6.2）。
    private struct Source: Sendable {
        let url: URL
        let bookmark: Data?
    }

    private let sources: [Source]

    init(urls: [URL]) {
        sources = urls.map { Source(url: $0, bookmark: try? $0.bookmarkData()) }
    }

    /// 走査と検査を行う。再チェックもこれを呼ぶ。
    @concurrent
    func inspect(options: NameOptions, progress: @Sendable (ZipJobProgress) -> Void = { _ in }) async throws -> ZipInspection {
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Scanning items")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        let urls = sources.compactMap(Self.currentURL)
        let throttle = ProgressThrottle()
        let items = try ItemScanner.scan(urls) { count in
            if throttle.shouldReport() { progress(.scanning(itemCount: count)) }
        }
        try Task.checkCancellation()

        let issues = NameRules.check(items.map(\.check), options: options)
        // 添字の順（Finder 順）を保ったまま、停止を先にする。
        let ordered = issues.filter { $0.rule.isStop } + issues.filter { !$0.rule.isStop }

        let includedTop = items.filter { $0.check.isTopLevel && $0.isIncluded }
        let first = urls.first { url in includedTop.contains { $0.url == url } }
        return ZipInspection(options: options, items: items, issues: ordered,
                             defaultDestination: first?.deletingLastPathComponent(),
                             archiveBaseName: Self.archiveBaseName(topLevel: includedTop),
                             firstItem: first)
    }

    /// 同じフォルダの一時ファイルへ書き、完了後に正式名へ変更する（仕様 §5.1）。
    /// - Parameters:
    ///   - destination: 保存先のフォルダ。nil なら既定値。
    ///   - password: ZIP 暗号のパスワード。nil なら暗号化しない。
    /// - Returns: 作成した ZIP の URL。
    @concurrent
    func compress(_ inspection: ZipInspection, destination: URL? = nil, password: String? = nil,
                  progress: @Sendable (ZipJobProgress) -> Void = { _ in }) async throws -> URL {
        guard !inspection.hasStops else { throw ZipJobError.hasStops }
        guard !inspection.isEmpty, let directory = destination ?? inspection.defaultDestination else {
            throw ZipJobError.noItems
        }
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Compressing items")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).zip.tmp")
        let writer: ZipWriter
        do {
            writer = try ZipWriter(url: temporary, password: password.map { Array($0.utf8) })
        } catch let ZipWriterError.writeFailed(_, underlying) {
            throw ZipJobError.destinationNotWritable(directory, underlying: underlying)
        }

        do {
            try write(inspection, to: writer, progress: progress)
            try writer.finish()
            try Task.checkCancellation()
            return try Self.moveToFinalName(temporary, directory: directory, baseName: inspection.archiveBaseName)
        } catch {
            writer.abort()
            throw error
        }
    }

    private func write(_ inspection: ZipInspection, to writer: ZipWriter, progress: @Sendable (ZipJobProgress) -> Void) throws {
        let options = inspection.options
        let total = inspection.totalBytes
        let throttle = ProgressThrottle()
        var completed: UInt64 = 0

        for item in Self.writeOrder(inspection.items) {
            try Task.checkCancellation()
            let path = NameEncoding.zipPath(item.check.path)
            guard let name = NameEncoding.encoded(zipPath: path, options: options) else {
                throw ZipJobError.nameNotEncodable(path)
            }
            progress(.compressing(completedBytes: completed, totalBytes: total, path: path))

            if item.check.isDirectory {
                try writer.addDirectory(name: name, attributes: item.attributes)
            } else {
                try writer.addFile(source: item.url, size: item.size, name: name, attributes: item.attributes,
                                   forceStored: Self.isMimetype(item)) { delta in
                    try Task.checkCancellation()
                    completed += delta
                    if throttle.shouldReport() {
                        progress(.compressing(completedBytes: completed, totalBytes: total, path: path))
                    }
                }
            }
        }
        progress(.compressing(completedBytes: total, totalBytes: total, path: ""))
    }

    // MARK: - 項目と名前

    /// 除外した項目を除き、最上位の `mimetype` というファイルを先頭にする（EPUB 用。仕様 §5.4）。
    static func writeOrder(_ items: [ScannedItem]) -> [ScannedItem] {
        let included = items.filter(\.isIncluded)
        return included.filter(isMimetype) + included.filter { !isMimetype($0) }
    }

    private static func isMimetype(_ item: ScannedItem) -> Bool {
        !item.check.isDirectory && item.check.path == ["mimetype"]
    }

    /// 単一項目は項目名（拡張子を残す）、複数項目は「アーカイブ」。
    private static func archiveBaseName(topLevel: [ScannedItem]) -> String {
        if topLevel.count == 1, let name = topLevel[0].check.path.last { return name }
        return String(localized: "Archive")
    }

    /// 今の URL。項目がなくなった、またはゴミ箱へ移されたときは nil。
    private static func currentURL(of source: Source) -> URL? {
        if let bookmark = source.bookmark {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &isStale) {
                // ブックマークはゴミ箱の中まで追跡する。
                return url.pathComponents.contains(".Trash") ? nil : url
            }
        }
        var status = stat()
        return lstat(source.url.path, &status) == 0 ? source.url : nil
    }

    /// `名前.zip`、`名前 2.zip`、`名前 3.zip` … の空いている名前へ移す。既存のファイルは上書きしない。
    private static func moveToFinalName(_ temporary: URL, directory: URL, baseName: String) throws -> URL {
        var number = 1
        while true {
            let name = number == 1 ? "\(baseName).zip" : "\(baseName) \(number).zip"
            let target = directory.appendingPathComponent(name)
            // RENAME_EXCL：確認と変更の間に同名のファイルができても上書きしない。
            if renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            guard errno == EEXIST else {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                throw ZipWriterError.writeFailed(target, underlying: error)
            }
            number += 1
        }
    }
}

/// 進捗の通知を間引く。
private nonisolated final class ProgressThrottle {
    private var last = DispatchTime(uptimeNanoseconds: 0)
    private static let interval: UInt64 = 50_000_000    // 50ms

    func shouldReport() -> Bool {
        let now = DispatchTime.now()
        guard now.uptimeNanoseconds - last.uptimeNanoseconds >= Self.interval else { return false }
        last = now
        return true
    }
}
