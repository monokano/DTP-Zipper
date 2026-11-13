import XCTest
import SwiftUI
@testable import DTP_Zipper

/// 画面を PNG に描き出す（`ui-snapshot` スキルの目視確認用）。アセットを読むためアプリを Host にして実行する。
/// 出力先を環境変数で指定したときだけ動く：
/// `TEST_RUNNER_DTP_ZIPPER_SNAPSHOT_DIR=<フォルダ> xcodebuild test ... -only-testing:"DTP ZipperTests/UISnapshotTests"`
@MainActor
final class UISnapshotTests: XCTestCase {

    private var output: URL!
    private var models: [ZipperModel] = []

    override func setUp() async throws {
        let path = ProcessInfo.processInfo.environment["DTP_ZIPPER_SNAPSHOT_DIR"]
        try XCTSkipIf(path == nil, "DTP_ZIPPER_SNAPSHOT_DIR が未指定")
        output = URL(fileURLWithPath: path!)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    private func makeModel(_ phase: ZipperModel.Phase, encoding: NameEncodingKind = .cp932) -> ZipperModel {
        let suite = "UISnapshotTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = ZipperModel(defaults: defaults)
        model.encoding = encoding
        model.phase = phase
        models.append(model)
        return model
    }

    /// 実物と同じくウインドウに入れて描く。画面の外に置くので見えない。
    private func render<V: View>(_ view: V, size: CGSize, name: String) throws {
        for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "DTP Zipper"
            window.appearance = NSAppearance(named: appearanceName)
            window.contentView = NSHostingView(rootView: view)
            window.orderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))

            let frame = try XCTUnwrap(window.contentView?.superview)
            frame.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: rep)
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent("\(name)-\(suffix).png"))
            window.orderOut(nil)
        }
    }

    // MARK: - ドロップウインドウ

    func testDropWindowStates() throws {
        let zip = URL(fileURLWithPath: "/tmp/とても長いファイル名のサンプルデータ 入稿用 最終版 2026年11月.indd.zip")
        let path = "入稿データ/リンク画像/とても長いフォルダ名のサンプル/さらに深いフォルダ/写真 001 修正済み 最終版.psd"
        let states: [(String, ZipperModel)] = [
            ("drop-idle", makeModel(.idle, encoding: .utf8)),
            ("drop-idle-sjis", makeModel(.idle)),
            ("drop-password", {
                let model = makeModel(.idle, encoding: .utf8)
                model.usesPassword = true
                model.password = "Abc123!"
                return model
            }()),
            ("drop-scanning", makeModel(.scanning(itemCount: 1234))),
            ("drop-compressing", makeModel(.compressing(completedBytes: 45, totalBytes: 100, path: path))),
            ("drop-finished", makeModel(.finished(zip))),
        ]
        for (name, model) in states {
            try render(DropView(model: model), size: DropView.windowSize, name: name)
        }
    }

    func testProgressOnlyWindow() throws {
        let path = "入稿データ/リンク画像/写真 001.psd"
        let model = makeModel(.compressing(completedBytes: 30, totalBytes: 100, path: path))
        try render(ProgressOnlyView(model: model), size: ProgressOnlyView.windowSize, name: "progress-only")
    }

    // MARK: - 問題一覧

    private func item(_ path: [String], directory: Bool = false, link: Bool = false, font: Bool = false, forkOnly: Bool = false) -> ScannedItem {
        var check = NameCheckItem(path: path, isDirectory: directory)
        check.isExcludedLink = link
        check.isResourceForkOnly = font || forkOnly
        check.isFont = font
        return ScannedItem(url: URL(fileURLWithPath: "/tmp/" + path.joined(separator: "/")), check: check,
                           attributes: ZipEntryAttributes(modificationDate: Date(), posixPermissions: 0o644))
    }

    private func inspection(_ items: [ScannedItem], options: NameOptions = NameOptions(encoding: .cp932)) -> ZipInspection {
        let issues = NameRules.check(items.map(\.check), options: options)
        return ZipInspection(options: options, items: items,
                             issues: issues.filter { $0.rule.isStop } + issues.filter { !$0.rule.isStop },
                             defaultDestination: URL(fileURLWithPath: "/tmp"), archiveBaseName: "Archive")
    }

    func testIssueWindowWithStops() throws {
        let items = [
            item(["入稿データ"], directory: true),
            item(["入稿データ", "案内〜地図.indd"]),
            item(["入稿データ", "①写真㈱.psd"]),
            item(["入稿データ", "CON.txt"]),
            item(["入稿データ", "末尾にピリオド."]),
            item(["入稿データ", "見えない\u{200B}文字.txt"]),
            item(["入稿データ", "A.txt"]),
            item(["入稿データ", "a.txt"]),
            item(["入稿データ", "リンク"], link: true),
            item(["表紙.indd"]),
        ]
        let model = makeModel(.reviewing(inspection(items), isChecking: false))
        try render(IssueListView(model: model), size: CGSize(width: 760, height: 480), name: "issues-stops")
    }

    func testIssueWindowWithEmoji() throws {
        let items = [
            item(["入稿データ"], directory: true),
            item(["入稿データ", "表紙😀最終.indd"]),
            item(["入稿データ", "家族👨\u{200D}👩\u{200D}👧と👍🏽.psd"]),
            item(["入稿データ", "旗🇯🇵と記号☺〜.txt"]),
        ]
        let model = makeModel(.reviewing(inspection(items), isChecking: false))
        try render(IssueListView(model: model), size: CGSize(width: 760, height: 480), name: "issues-emoji")
    }

    func testIssueWindowWithFontsAndNames() throws {
        let items = [
            item(["入稿データ"], directory: true),
            item(["入稿データ", "Helvetica"], font: true),
            item(["入稿データ", "リュウミン L-KL"], font: true),
            item(["入稿データ", "案内〜地図.indd"]),
            item(["入稿データ", "CON.txt"]),
            item(["入稿データ", "リンク"], link: true),
        ]
        let reviewed = inspection(items)
        try render(IssueListView(model: makeModel(.reviewing(reviewed, isChecking: false))),
                   size: CGSize(width: 760, height: 480), name: "issues-tabs-fonts")
        try render(IssueListView(model: makeModel(.reviewing(reviewed, isChecking: false)), tab: .names),
                   size: CGSize(width: 760, height: 480), name: "issues-tabs-names")
    }

    func testIssueWindowWithFontsOnly() throws {
        let model = makeModel(.reviewing(inspection([item(["Helvetica"], font: true)]), isChecking: false))
        try render(IssueListView(model: model), size: IssueListView.minimumSize, name: "issues-fonts")
    }

    func testIssueWindowWithOtherResourceForkFile() throws {
        let model = makeModel(.reviewing(inspection([item(["古いアプリ"], forkOnly: true)]), isChecking: false))
        try render(IssueListView(model: model), size: IssueListView.minimumSize, name: "issues-fork-only")
    }

    /// アイコンは実物から取るので、実際のフォルダとファイルで描く。
    func testIssueWindowWithRealIcons() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("フォルダ〜")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["写真〜.jpg", "案内〜.pdf", "文書〜.txt", "とても長いファイル名のサンプルデータ 入稿用 最終版〜 2026年11月.indd"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        let inspection = try await ZipJob(urls: [folder]).inspect(options: NameOptions(encoding: .cp932))
        let model = makeModel(.reviewing(inspection, isChecking: false))
        try render(IssueListView(model: model), size: IssueListView.minimumSize, name: "issues-icons")
    }

    /// 問題の列はドラッグで幅を変えられ、ウインドウの幅を変えると名前と問題の列が伸縮する。
    func testIssueWindowColumns() throws {
        func tableView(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for subview in view.subviews {
                if let table = tableView(in: subview) { return table }
            }
            return nil
        }

        let model = makeModel(.reviewing(inspection([item(["案内〜.txt"])]), isChecking: false))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 760, height: 480),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: IssueListView(model: model))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        let table = try XCTUnwrap(tableView(in: try XCTUnwrap(window.contentView)))
        XCTAssertTrue(table.allowsColumnResizing)
        let name = table.tableColumns[0], problem = table.tableColumns[1]
        XCTAssertTrue(problem.resizingMask.contains(.userResizingMask))
        XCTAssertEqual(problem.minWidth, 160)
        let nameWidth = name.width, problemWidth = problem.width

        window.setContentSize(CGSize(width: 900, height: 480))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertGreaterThan(name.width, nameWidth)
        XCTAssertGreaterThanOrEqual(problem.width, problemWidth)
    }

    func testIssueWindowWithWarnings() throws {
        let long = String(repeating: "長いフォルダ", count: 40)
        let items = [item(["表紙.indd"]), item([long], directory: true), item([long, "長いパス.txt"]), item(["リンク"], link: true)]
        let model = makeModel(.reviewing(inspection(items), isChecking: false))
        try render(IssueListView(model: model), size: CGSize(width: 760, height: 480), name: "issues-warnings")
        try render(IssueListView(model: model), size: IssueListView.minimumSize, name: "issues-warnings-minimum")
        try render(IssueListView(model: model), size: IssueListView.defaultSize, name: "issues-warnings-default")
    }

    func testIssueWindowWhileChecking() throws {
        let model = makeModel(.reviewing(inspection([item(["案内〜.txt"])]), isChecking: true))
        try render(IssueListView(model: model), size: IssueListView.minimumSize, name: "issues-checking")
    }

    func testIssueWindowWithoutProblems() throws {
        let model = makeModel(.reviewing(inspection([item(["a.txt"])]), isChecking: false))
        try render(IssueListView(model: model), size: IssueListView.minimumSize, name: "issues-clean")
    }
}
