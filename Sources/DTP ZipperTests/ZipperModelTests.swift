import XCTest
@testable import DTP_Zipper

@MainActor
final class ZipperModelTests: XCTestCase {

    private final class Host: ZipperHost {
        var alerts: [String] = []
        var destination: URL?
        var askedForDestination = false
        var revealed: [URL] = []
        var revealSources: [URL?] = []
        var terminated = false
        func showAlert(message: String, information: String) { alerts.append(message) }
        func chooseDestination() -> URL? { askedForDestination = true; return destination }
        func reveal(_ url: URL, placingNear source: URL?) {
            revealed.append(url)
            revealSources.append(source)
        }
        func terminate() { terminated = true }
    }

    private var dir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var host: Host!
    private var model: ZipperModel!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ZipperModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suiteName = "ZipperModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        host = Host()
        model = ZipperModel(defaults: defaults)
        model.host = host
        model.encoding = .cp932
        model.autoQuit = false
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    /// 条件を満たすまで、メインスレッドの処理を進める。
    private func wait(_ condition: @escaping () -> Bool, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            if Date() > deadline {
                XCTFail("時間切れ: \(model.phase)", line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private var isFinished: Bool { if case .finished = model.phase { return true }; return false }
    private var isIdle: Bool { if case .idle = model.phase { return true }; return false }
    private var reviewed: ZipInspection? {
        if case .reviewing(let inspection, isChecking: false) = model.phase { return inspection }
        return nil
    }

    // MARK: - 設定

    func testDefaultSettings() {
        let fresh = ZipperModel(defaults: UserDefaults(suiteName: "ZipperModelTests-fresh-\(UUID().uuidString)")!)
        XCTAssertEqual(fresh.encoding, .utf8)
        XCTAssertTrue(fresh.autoQuit)
    }

    func testSettingsPersist() {
        model.encoding = .utf8
        let reloaded = ZipperModel(defaults: defaults)
        XCTAssertEqual(reloaded.encoding, .utf8)
        XCTAssertFalse(reloaded.autoQuit)
    }

    func testSettingKeysMatchSpec() {
        model.encoding = .utf8
        XCTAssertEqual(defaults.string(forKey: "nameEncoding"), "utf8")
        XCTAssertEqual(defaults.object(forKey: "autoQuit") as? Bool, false)
    }

    // MARK: - 流れ

    // MARK: - パスワード

    func testPasswordIsOffAndEmptyAtLaunch() {
        model.usesPassword = true
        model.password = "secret"
        let reloaded = ZipperModel(defaults: defaults)
        XCTAssertFalse(reloaded.usesPassword)
        XCTAssertEqual(reloaded.password, "")
    }

    func testDropIsRefusedWhenPasswordIsMissing() {
        model.usesPassword = true
        model.start(urls: [URL(fileURLWithPath: "/tmp/a.txt")])
        XCTAssertTrue(isIdle)
        XCTAssertEqual(model.passwordRequest, 1)
    }

    func testAllowedPasswordKeepsPrintableASCIIOnly() {
        XCTAssertEqual(ZipperModel.allowedPassword("Ab 1!~"), "Ab 1!~")
        XCTAssertEqual(ZipperModel.allowedPassword("パスaワ\u{FF41}b\tc\n"), "abc")
    }

    func testCompressWithPasswordEncrypts() async throws {
        model.usesPassword = true
        model.password = "pw"
        model.start(urls: [try file("a.txt")])
        await wait { self.isFinished }
        guard case .finished(let zip) = model.phase else { return XCTFail() }
        let bytes = try [UInt8](Data(contentsOf: zip))
        XCTAssertEqual(bytes[6] & 1, 1)   // ローカルヘッダの汎用フラグ bit 0
    }

    func testPasswordOffDoesNotEncrypt() async throws {
        model.password = "pw"   // チェックがオフなら使わない
        model.start(urls: [try file("a.txt")])
        await wait { self.isFinished }
        guard case .finished(let zip) = model.phase else { return XCTFail() }
        XCTAssertEqual(try [UInt8](Data(contentsOf: zip))[6] & 1, 0)
    }

    func testCleanItemsCompressAndFinish() async throws {
        model.start(urls: [try file("a.txt")])
        await wait { self.isFinished }
        guard case .finished(let zip) = model.phase else { return XCTFail() }
        XCTAssertEqual(zip.lastPathComponent, "a.txt.zip")
        XCTAssertFalse(host.terminated)
        XCTAssertEqual(host.revealed.map(\.lastPathComponent), ["a.txt.zip"])
        // 重ねる基準は、ZIP に入れた先頭の項目。
        XCTAssertEqual(host.revealSources.map { $0?.lastPathComponent }, ["a.txt"])
    }

    func testAutoQuitAndReveal() async throws {
        model.autoQuit = true
        model.start(urls: [try file("a.txt")])
        await wait { self.host.terminated }
        XCTAssertEqual(host.revealed.map(\.lastPathComponent), ["a.txt.zip"])
    }

    func testStopsShowReviewAndContinueIsRefused() async throws {
        model.start(urls: [try file("bad〜.txt")])
        await wait { self.reviewed != nil }
        XCTAssertEqual(reviewed?.hasStops, true)
        model.proceed()
        XCTAssertNotNil(reviewed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bad〜.txt.zip").path))
    }

    func testWarningsCanContinue() async throws {
        model.start(urls: [try file("表.txt")])
        await wait { self.reviewed != nil }
        XCTAssertEqual(reviewed?.issues.map(\.rule), [.trailing5C])
        model.proceed()
        await wait { self.isFinished }
    }

    func testRecheckAfterRenameProceedsToCompression() async throws {
        let bad = try file("bad〜.txt")
        model.start(urls: [bad])
        await wait { self.reviewed != nil }
        try FileManager.default.moveItem(at: bad, to: dir.appendingPathComponent("good.txt"))
        model.recheck()
        await wait { self.isFinished }
        guard case .finished(let zip) = model.phase else { return XCTFail() }
        XCTAssertEqual(zip.lastPathComponent, "good.txt.zip")
    }

    func testChangingOptionsInReviewRechecksWithoutCompressing() async throws {
        model.start(urls: [try file("①.txt")])
        await wait { self.reviewed != nil }
        XCTAssertEqual(reviewed?.hasStops, true)

        model.encoding = .utf8
        await wait { self.reviewed?.issues.isEmpty == true }
        XCTAssertEqual(reviewed?.options.encoding, .utf8)
        // 自動では圧縮へ進まず、［続行］で進む。
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("①.txt.zip").path))
        model.proceed()
        await wait { self.isFinished }
    }

    func testCancelReturnsToIdle() async throws {
        model.start(urls: [try file("bad〜.txt")])
        await wait { self.reviewed != nil }
        model.cancel()
        XCTAssertTrue(isIdle)
        XCTAssertFalse(host.terminated)
    }

    func testCancelAfterIconLaunchTerminates() async throws {
        model.start(urls: [try file("bad〜.txt")], launchedByIconDrop: true)
        await wait { self.reviewed != nil }
        XCTAssertTrue(model.launchedByIconDrop)
        model.cancel()
        XCTAssertTrue(host.terminated)
    }

    func testDropsAreIgnoredWhileReviewing() async throws {
        model.start(urls: [try file("bad〜.txt")])
        await wait { self.reviewed != nil }
        XCTAssertFalse(model.canAcceptDrop)
        model.start(urls: [try file("other.txt")])
        XCTAssertEqual(reviewed?.items.map(\.url.lastPathComponent), ["bad〜.txt"])
    }

    func testFinishedAcceptsNextDrop() async throws {
        model.start(urls: [try file("a.txt")])
        await wait { self.isFinished }
        XCTAssertTrue(model.canAcceptDrop)
        model.start(urls: [try file("b.txt")])
        await wait {
            if case .finished(let zip) = self.model.phase { return zip.lastPathComponent == "b.txt.zip" }
            return false
        }
    }

    func testAllExcludedShowsAlertAndReturnsToIdleEvenAfterIconLaunch() async throws {
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        model.start(urls: [link], launchedByIconDrop: true)
        await wait { !self.host.alerts.isEmpty }
        XCTAssertTrue(isIdle)
        XCTAssertFalse(model.launchedByIconDrop)
        XCTAssertFalse(host.terminated)
    }

    // MARK: - 保存先

    func testUnwritableDestinationAsksAndCompressesToChosenFolder() async throws {
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let url = locked.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let other = dir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        host.destination = other

        model.start(urls: [url])
        await wait { self.isFinished }
        XCTAssertTrue(host.askedForDestination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.appendingPathComponent("a.txt.zip").path))
    }

    func testCancellingDestinationReturnsToIdle() async throws {
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let url = locked.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        host.destination = nil

        model.start(urls: [url], launchedByIconDrop: true)
        await wait { self.host.askedForDestination }
        XCTAssertTrue(isIdle)
        XCTAssertFalse(host.terminated)
        XCTAssertFalse(model.launchedByIconDrop)
    }

    // MARK: - 終了

    func testPrepareToTerminateCancelsAndRemovesTemporaryFile() async throws {
        let root = dir.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = Data(repeating: 0x41, count: 8 << 20)
        for i in 0..<40 { try data.write(to: root.appendingPathComponent("f\(i)")) }

        model.start(urls: [root])
        await wait { if case .compressing = self.model.phase { return true }; return false }

        let finished = expectation(description: "done")
        model.prepareToTerminate { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 20)

        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names.filter { $0.hasSuffix(".tmp") || $0.hasSuffix(".zip") }, [])
    }

    func testPrepareToTerminateWhenIdleIsImmediate() {
        var done = false
        model.prepareToTerminate { done = true }
        XCTAssertTrue(done)
    }

    // MARK: - 表示

    func testHighlightMarksOnlyOffendingCharacters() {
        func row(_ name: String, offsets: [Int]) -> IssueRow {
            IssueRow(id: 0, issue: NameIssue(rule: .notPreserved, itemIndex: 0, name: name, scalarOffsets: offsets),
                     item: ScannedItem(url: dir, check: NameCheckItem(path: [name]),
                                       attributes: ZipEntryAttributes(modificationDate: Date(), posixPermissions: 0o644)))
        }
        func redText(_ value: AttributedString) -> String {
            value.runs.filter { $0.foregroundColor != nil }.map { String(value[$0.range].characters) }.joined()
        }
        let visible = row("a〜b", offsets: [1]).highlightedName
        XCTAssertEqual(String(visible.characters), "a〜b")
        XCTAssertEqual(redText(visible), "〜")

        // 見えない文字だけ `▁` にする。
        let invisible = row("a\u{200B}b", offsets: [1]).highlightedName
        XCTAssertEqual(String(invisible.characters), "a▁b")
        XCTAssertEqual(redText(invisible), "▁")
    }

    func testHighlightGivesColorEmojiBackground() {
        func row(_ name: String, offsets: [Int], rule: NameRule = .notPreserved) -> IssueRow {
            IssueRow(id: 0, issue: NameIssue(rule: rule, itemIndex: 0, name: name, scalarOffsets: offsets),
                     item: ScannedItem(url: dir, check: NameCheckItem(path: [name]),
                                       attributes: ZipEntryAttributes(modificationDate: Date(), posixPermissions: 0o644)))
        }
        func backgroundText(_ value: AttributedString) -> String {
            value.runs.filter { $0.backgroundColor != nil }.map { String(value[$0.range].characters) }.joined()
        }

        // カラー絵文字は文字色が効かないので背景を付ける。
        let emoji = row("a😀b", offsets: [1]).highlightedName
        XCTAssertEqual(String(emoji.characters), "a😀b")
        XCTAssertEqual(backgroundText(emoji), "😀")

        // 合成された絵文字は、ZWJ が問題の文字でなくても、まとまり全体に付ける。
        let family = "👨\u{200D}👩\u{200D}👧"
        let joined = row("a\(family)b", offsets: [1, 3, 5]).highlightedName
        XCTAssertEqual(String(joined.characters), "a\(family)b")
        XCTAssertEqual(backgroundText(joined), family)

        // 絵文字でない文字には付けない。
        XCTAssertEqual(backgroundText(row("a〜b", offsets: [1]).highlightedName), "")

        // 問題の文字でない絵文字には付けない。
        XCTAssertEqual(backgroundText(row("a😀b:", offsets: [3], rule: .forbiddenCharacter).highlightedName), "")

        // ZWJ だけが問題のときは、位置がわかるよう `▁` にする。
        let control = row("a\(family)b", offsets: [2, 4], rule: .controlCharacter).highlightedName
        XCTAssertEqual(String(control.characters), "a👨▁👩▁👧b")
        XCTAssertEqual(backgroundText(control), "")
    }
}
