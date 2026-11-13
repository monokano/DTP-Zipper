import XCTest
@testable import DTP_Zipper

final class ZipJobTests: XCTestCase {

    private var dir: URL!
    private let cp932 = NameOptions(encoding: .cp932)
    private let utf8 = NameOptions(encoding: .utf8)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ZipJobTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // 書き込み禁止のテストで変えた属性を戻してから削除する。
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - 補助

    @discardableResult
    private func file(_ path: String, _ content: String = "x") throws -> URL {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return url
    }

    @discardableResult
    private func folder(_ path: String) throws -> URL {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func setHidden(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isHidden = true
        try url.setResourceValues(values)
    }

    private func paths(_ items: [ScannedItem]) -> [String] {
        items.map { $0.check.path.joined(separator: "/") }
    }

    private func paths(in zip: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import sys,zipfile\nfor n in zipfile.ZipFile(sys.argv[1]).namelist(): print(n)", zip.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["PYTHONIOENCODING": "utf-8"]) { $1 }
        let output = dir.appendingPathComponent("list-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        process.standardOutput = handle
        try process.run()
        process.waitUntilExit()
        try handle.close()
        XCTAssertEqual(process.terminationStatus, 0)
        let text = try String(contentsOf: output, encoding: .utf8)
        try FileManager.default.removeItem(at: output)
        return text.split(separator: "\n").map(String.init)
    }

    private func visibleNames(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != ".DS_Store" }.sorted()
    }

    // MARK: - 走査

    func testScanOrderIsFinderOrderWithFoldersBeforeContents() throws {
        let root = try folder("root")
        try file("root/a10.txt")
        try file("root/a2.txt")
        try file("root/sub/z.txt")
        try file("root/b.txt")
        try folder("root/empty")

        let items = try ItemScanner.scan([root])
        XCTAssertEqual(paths(items), ["root", "root/a2.txt", "root/a10.txt", "root/b.txt", "root/empty", "root/sub", "root/sub/z.txt"])
    }

    func testScanInsideFolderExcludesHiddenAndDotItems() throws {
        let root = try folder("root")
        try file("root/visible.txt")
        try file("root/.DS_Store")
        try file("root/.dotfolder/inner.txt")
        try setHidden(file("root/hidden.txt"))
        try setHidden(file("root/Icon\r"))
        try setHidden(folder("root/hiddenFolder"))
        try file("root/hiddenFolder/inner.txt")

        XCTAssertEqual(paths(try ItemScanner.scan([root])), ["root", "root/visible.txt"])
    }

    func testDroppedHiddenAndDotItemsAreIncluded() throws {
        let dot = try file(".dot")
        let hidden = try file("hidden")
        try setHidden(hidden)
        XCTAssertEqual(Set(paths(try ItemScanner.scan([dot, hidden]))), [".dot", "hidden"])
    }

    func testIconFileNoLongerStopsCompression() async throws {
        // カスタムアイコン付きフォルダの `Icon\r` で圧縮が止まらない（A9）。
        let root = try folder("root")
        try setHidden(file("root/Icon\r"))
        let inspection = try await ZipJob(urls: [root]).inspect(options: cp932)
        XCTAssertEqual(inspection.issues.count, 0)
    }

    func testPackageIsTreatedAsFolder() throws {
        let app = try folder("Sample.app")
        try file("Sample.app/Contents/Info.plist")
        XCTAssertEqual(paths(try ItemScanner.scan([app])), ["Sample.app", "Sample.app/Contents", "Sample.app/Contents/Info.plist"])
    }

    private func makeAlias(_ path: String, to target: URL) throws -> URL {
        let url = dir.appendingPathComponent(path)
        let data = try target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(data, to: url)
        return url
    }

    func testLinksAndAliasesAreExcludedWithWarning() async throws {
        let root = try folder("root")
        let target = try file("target.txt")
        let targetFolder = try folder("targetFolder")
        try file("targetFolder/secret.txt")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linkFolder"), withDestinationURL: targetFolder)
        _ = try makeAlias("root/alias", to: target)
        try file("root/real.txt")

        let inspection = try await ZipJob(urls: [root]).inspect(options: cp932)
        XCTAssertEqual(paths(inspection.items), ["root", "root/alias", "root/link", "root/linkFolder", "root/real.txt"])
        XCTAssertEqual(inspection.issues.map(\.rule), [.excludedLink, .excludedLink, .excludedLink])
        XCTAssertFalse(inspection.hasStops)

        let zip = try await ZipJob(urls: [root]).compress(inspection)
        XCTAssertEqual(try paths(in: zip), ["root/", "root/real.txt"])
    }

    func testDroppedSymlinkAndAliasStayExcludedThroughBookmark() async throws {
        let target = try file("target.txt")
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let alias = try makeAlias("alias", to: target)

        let inspection = try await ZipJob(urls: [link, alias]).inspect(options: cp932)
        XCTAssertEqual(inspection.issues.map(\.rule), [.excludedLink, .excludedLink])
        XCTAssertTrue(inspection.isEmpty)
    }

    func testFIFOIsExcluded() async throws {
        let root = try folder("root")
        XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe").path, 0o644), 0)
        let inspection = try await ZipJob(urls: [root]).inspect(options: cp932)
        XCTAssertEqual(inspection.issues.map(\.rule), [.excludedLink])
    }

    func testAttributesComeFromFile() throws {
        let url = try file("a.txt", "hello")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o640, .modificationDate: date], ofItemAtPath: url.path)
        let item = try XCTUnwrap(ItemScanner.scan([url]).first)
        XCTAssertEqual(item.size, 5)
        XCTAssertEqual(item.attributes.posixPermissions, 0o640)
        XCTAssertEqual(item.attributes.modificationDate, date)
    }

    func testResourceForkOnlyFileIsStopped() async throws {
        let font = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("検証用/Windows非対応フォント/Futura")
        let inspection = try await ZipJob(urls: [font]).inspect(options: cp932)
        XCTAssertEqual(inspection.issues.map(\.rule), [.fontResourceForkOnly])
    }

    /// ファイルタイプを失ったフォントはフォントと認識できないが、E7 で止まる。
    func testFontWithoutFileTypeIsStopped() async throws {
        let font = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("検証用/Windows非対応フォント/Futura")
        let root = try folder("root")
        let copy = root.appendingPathComponent("Futura")
        try FileManager.default.copyItem(at: font, to: copy)
        XCTAssertEqual(removexattr(copy.path, "com.apple.FinderInfo", 0), 0)
        let inspection = try await ZipJob(urls: [root]).inspect(options: cp932)
        XCTAssertEqual(inspection.issues.map(\.rule), [.resourceForkOnly])
    }

    func testRecheckAfterRemovingFontLeavesOtherIssues() async throws {
        let font = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("検証用/Windows非対応フォント/Futura")
        let root = try folder("root")
        let copy = root.appendingPathComponent("Futura")
        try FileManager.default.copyItem(at: font, to: copy)
        _ = try file("root/bad〜.txt")
        let job = ZipJob(urls: [root])
        let first = try await job.inspect(options: cp932)
        XCTAssertEqual(Set(first.issues.map(\.rule)), [.fontResourceForkOnly, .notPreserved])

        // フォントをフォルダから外す。
        try FileManager.default.removeItem(at: copy)
        let second = try await job.inspect(options: cp932)
        XCTAssertEqual(second.issues.map(\.rule), [.notPreserved])
    }

    func testUnreadableFolderFailsWithItsName() async throws {
        let root = try folder("root")
        let locked = try folder("root/locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        do {
            _ = try await ZipJob(urls: [root]).inspect(options: cp932)
            XCTFail("エラーになるはず")
        } catch ItemScannerError.readFailed(let url, _) {
            XCTAssertEqual(url.lastPathComponent, "locked")
        }
    }

    // MARK: - 検査と順序

    func testStopsComeFirstAndKeepFinderOrder() async throws {
        let root = try folder("root")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("a-link"), withDestinationURL: dir)
        try file("root/b〜.txt")
        try file("root/c.")
        let inspection = try await ZipJob(urls: [root]).inspect(options: cp932)
        XCTAssertEqual(inspection.issues.map(\.rule), [.notPreserved, .trailingSpaceOrPeriod, .excludedLink])
    }

    func testOptionsChangeTheResult() async throws {
        let url = try file("①.txt")
        let job = ZipJob(urls: [url])
        let cp932Result = try await job.inspect(options: cp932)
        XCTAssertTrue(cp932Result.hasStops)
        let utf8Result = try await job.inspect(options: utf8)
        XCTAssertFalse(utf8Result.hasStops)
        XCTAssertFalse(utf8Result.hasWarnings)
    }

    func testRecheckFollowsRenamedItem() async throws {
        let original = try file("bad〜.txt")
        let job = ZipJob(urls: [original])
        let first = try await job.inspect(options: cp932)
        XCTAssertTrue(first.hasStops)

        // Finder で名前を直す。
        let renamed = dir.appendingPathComponent("good.txt")
        try FileManager.default.moveItem(at: original, to: renamed)

        let second = try await job.inspect(options: cp932)
        XCTAssertFalse(second.hasStops)
        XCTAssertEqual(paths(second.items), ["good.txt"])
        let zip = try await job.compress(second)
        XCTAssertEqual(zip.lastPathComponent, "good.txt.zip")
    }

    func testRecheckFollowsRenamedFolderAndRescansContents() async throws {
        let root = try folder("root.")
        let inner = try file("root./bad〜.txt")
        let job = ZipJob(urls: [root])
        let first = try await job.inspect(options: cp932)
        XCTAssertEqual(first.issues.count, 2)

        try FileManager.default.moveItem(at: inner, to: root.appendingPathComponent("good.txt"))
        try FileManager.default.moveItem(at: root, to: dir.appendingPathComponent("root"))
        let second = try await job.inspect(options: cp932)
        XCTAssertEqual(second.issues.count, 0)
        XCTAssertEqual(paths(second.items), ["root", "root/good.txt"])
    }

    func testMissingAndTrashedItemsAreDropped() async throws {
        let keep = try file("keep.txt")
        let gone = try file("gone.txt")
        let trashed = try file("trashed.txt")
        let job = ZipJob(urls: [keep, gone, trashed])
        try FileManager.default.removeItem(at: gone)
        let trash = try folder(".Trash")
        try FileManager.default.moveItem(at: trashed, to: trash.appendingPathComponent("trashed.txt"))

        let inspection = try await job.inspect(options: cp932)
        XCTAssertEqual(paths(inspection.items), ["keep.txt"])
    }

    // MARK: - 圧縮

    func testStopsPreventCompression() async throws {
        let url = try file("bad〜.txt")
        let job = ZipJob(urls: [url])
        let inspection = try await job.inspect(options: cp932)
        do {
            _ = try await job.compress(inspection)
            XCTFail("エラーになるはず")
        } catch ZipJobError.hasStops {}
        XCTAssertEqual(try visibleNames(dir), ["bad〜.txt"])
    }

    func testEmptyInspectionReportsNoItems() async throws {
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        let job = ZipJob(urls: [link])
        let inspection = try await job.inspect(options: cp932)
        XCTAssertTrue(inspection.isEmpty)
        XCTAssertNil(inspection.defaultDestination)
        do {
            _ = try await job.compress(inspection)
            XCTFail("エラーになるはず")
        } catch ZipJobError.noItems {}
    }

    func testSingleItemKeepsExtensionInZipName() async throws {
        let url = try file("sub/a.txt")
        let job = ZipJob(urls: [url])
        let zip = try await job.compress(try await job.inspect(options: cp932))
        XCTAssertEqual(zip.deletingLastPathComponent().lastPathComponent, "sub")
        XCTAssertEqual(zip.lastPathComponent, "a.txt.zip")
    }

    func testMultipleItemsUseArchiveNameAndFirstItemParent() async throws {
        let b = try file("two/b.txt")
        let a = try file("one/a.txt")
        let job = ZipJob(urls: [b, a])
        let zip = try await job.compress(try await job.inspect(options: cp932))
        // 保存先はドロップの先頭の親フォルダ。ZIP の中は Finder 順。
        XCTAssertEqual(zip.deletingLastPathComponent().lastPathComponent, "two")
        XCTAssertEqual(zip.lastPathComponent, String(localized: "Archive") + ".zip")
        XCTAssertEqual(try paths(in: zip), ["a.txt", "b.txt"])
    }

    func testExistingZipIsNotOverwrittenAndNumbered() async throws {
        let url = try file("a.txt")
        try file("a.txt.zip", "keep")
        try file("a.txt 2.zip", "keep")
        let job = ZipJob(urls: [url])
        let zip = try await job.compress(try await job.inspect(options: cp932))
        XCTAssertEqual(zip.lastPathComponent, "a.txt 3.zip")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a.txt.zip"), encoding: .utf8), "keep")
    }

    func testMimetypeIsFirstAndStored() async throws {
        let root = try folder("root")
        let mimetype = try file("root/mimetype", "application/epub+zip")
        let other = try file("root/a.txt", String(repeating: "a", count: 1000))
        let job = ZipJob(urls: [other, mimetype])
        let inspection = try await job.inspect(options: cp932)
        XCTAssertEqual(paths(ZipJob.writeOrder(inspection.items)), ["mimetype", "a.txt"])
        let zip = try await job.compress(inspection, destination: root)
        XCTAssertEqual(try paths(in: zip), ["mimetype", "a.txt"])
    }

    func testMimetypeInsideFolderIsNotSpecial() async throws {
        let root = try folder("root")
        try file("root/a.txt")
        try file("root/mimetype")
        let inspection = try await ZipJob(urls: [root]).inspect(options: cp932)
        XCTAssertEqual(paths(ZipJob.writeOrder(inspection.items)), ["root", "root/a.txt", "root/mimetype"])
    }

    func testUTF8KeepsNamesOutOfCP932() async throws {
        let url = try file("𠮷😀〜.txt")
        let job = ZipJob(urls: [url])
        let inspection = try await job.inspect(options: utf8)
        XCTAssertFalse(inspection.hasStops)
        let zip = try await job.compress(inspection)
        XCTAssertEqual(try paths(in: zip), ["𠮷😀〜.txt"])
    }

    func testNFDNameIsStoredAsNFCInCP932() async throws {
        // 元の名前が NFD でも、ZIP には NFC で入る。
        let url = try file("か\u{3099}.txt")
        let job = ZipJob(urls: [url])
        let zip = try await job.compress(try await job.inspect(options: cp932))
        let out = dir.appendingPathComponent("out")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, out.path]
        try ditto.run()
        ditto.waitUntilExit()
        let names = try FileManager.default.contentsOfDirectory(atPath: out.path)
        XCTAssertEqual(names.first.map { $0.unicodeScalars.map(\.value) }, "\u{304C}.txt".unicodeScalars.map(\.value))
    }

    func testProgressReachesTotal() async throws {
        let root = try folder("root")
        try file("root/a.txt", String(repeating: "a", count: 5000))
        try file("root/b.txt", String(repeating: "b", count: 7000))
        let job = ZipJob(urls: [root])
        let inspection = try await job.inspect(options: cp932)
        XCTAssertEqual(inspection.totalBytes, 12000)

        let last = LockedValue<(UInt64, UInt64)?>(nil)
        _ = try await job.compress(inspection) { progress in
            if case .compressing(let completed, let total, _) = progress { last.set((completed, total)) }
        }
        XCTAssertEqual(last.get()?.0, 12000)
        XCTAssertEqual(last.get()?.1, 12000)
    }

    // MARK: - 中止とエラー

    func testCancelRemovesTemporaryFile() async throws {
        let big = try folder("in")
        // 中断できるよう、十分な量を用意する。
        let data = Data(repeating: 0x41, count: 4 << 20)
        for i in 0..<20 { try data.write(to: big.appendingPathComponent("f\(i)")) }
        let out = try folder("out")

        let job = ZipJob(urls: [big])
        let inspection = try await job.inspect(options: cp932)
        let started = expectation(description: "started")
        started.assertForOverFulfill = false
        let task = Task {
            try await job.compress(inspection, destination: out) { _ in started.fulfill() }
        }
        await fulfillment(of: [started], timeout: 10)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("キャンセルされるはず")
        } catch is CancellationError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
    }

    func testCancelBeforeScanStops() async throws {
        let root = try folder("root")
        try file("root/a.txt")
        let job = ZipJob(urls: [root])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await job.inspect(options: self.cp932)
        }
        do {
            _ = try await task.value
            XCTFail("キャンセルされるはず")
        } catch is CancellationError {}
    }

    func testFileChangedDuringCompressionFailsAndCleansUp() async throws {
        let root = try folder("root")
        let target = try file("root/a.txt", "hello")
        let job = ZipJob(urls: [root])
        let inspection = try await job.inspect(options: cp932)
        try Data("changed size".utf8).write(to: target)
        do {
            _ = try await job.compress(inspection)
            XCTFail("エラーになるはず")
        } catch ZipWriterError.fileChanged(let url) {
            XCTAssertEqual(url.lastPathComponent, "a.txt")
        }
        XCTAssertEqual(try visibleNames(dir).filter { $0.hasSuffix(".tmp") }, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") || $0.hasSuffix(".zip") }, [])
    }

    func testUnwritableDestinationCanBeChosenAgain() async throws {
        let locked = try folder("locked")
        let url = try file("locked/a.txt")
        let job = ZipJob(urls: [url])
        let inspection = try await job.inspect(options: cp932)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        do {
            _ = try await job.compress(inspection)
            XCTFail("エラーになるはず")
        } catch ZipJobError.destinationNotWritable(let directory, _) {
            XCTAssertEqual(directory.lastPathComponent, "locked")
        }
        // 保存先を選び直す。
        let other = try folder("other")
        let zip = try await job.compress(inspection, destination: other)
        XCTAssertEqual(zip.deletingLastPathComponent().lastPathComponent, "other")
    }
}

private final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
}
