import SwiftUI
import AppKit
import Combine

@main
struct DTPZipperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // ウインドウは AppDelegate が作る。`WindowGroup` はドロップされた URL ごとにウインドウを作るので使わない。
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {}
                CommandGroup(replacing: .newItem) {}
                // バンドルしたヘルプブックを自前のウインドウで開く。
                CommandGroup(replacing: .help) {
                    Button("DTP Zipper Help") {
                        appDelegate.openHelp()
                    }
                    .keyboardShortcut("?", modifiers: .command)
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ZipperHost {

    private let model = ZipperModel()
    private var cancellables: Set<AnyCancellable> = []

    private var dropWindow: NSWindow?
    private var progressWindow: NSWindow?
    private var issueWindow: NSWindow?
    private var helpWindowController: HelpWindowController?

    /// 起動処理が終わる前に届いた、アイコンへのドロップ。
    private var pendingURLs: [URL] = []
    private var didFinishLaunching = false

    override init() {
        super.init()
        // 状態復元を無効にする（AFVer と同じ）。
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    // MARK: - アプリ

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 単体テストの Host として起動したときは何もしない。
        if NSClassFromString("XCTestCase") != nil { return }

        model.host = self
        // ドロップでの起動かどうかを確かめるため、届いたイベントを処理してから始める。
        DispatchQueue.main.async { [self] in
            didFinishLaunching = true
            if pendingURLs.isEmpty {
                showDropWindow()
            } else {
                model.start(urls: pendingURLs, launchedByIconDrop: true)
                pendingURLs = []
            }
            model.$phase.sink { [weak self] _ in
                // `@Published` は値が変わる前に通知するので、変わった後で揃える。
                DispatchQueue.main.async { self?.syncWindows() }
            }.store(in: &cancellables)
            syncWindows()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if didFinishLaunching {
            // ドロップウインドウ使用中も受け付ける。処理中と問題一覧の表示中は `start` が無視する（仕様 §3）。
            model.start(urls: urls)
        } else {
            pendingURLs += urls
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 処理中は確認なしで中止し、一時ファイルを削除してから終了する（仕様 §6.1）。
        model.prepareToTerminate {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { dropWindow?.makeKeyAndOrderFront(nil) }
        return true
    }

    // MARK: - ヘルプ

    func openHelp() {
        if helpWindowController == nil {
            helpWindowController = HelpWindowController()
        }
        helpWindowController?.show()
    }

    // MARK: - Dock メニュー

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: String(localized: "Help"), action: #selector(dockHelpClicked(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func dockHelpClicked(_ sender: Any?) {
        openHelp()
    }

    // MARK: - ウインドウ

    /// 状態に合わせてウインドウを出す。
    private func syncWindows() {
        let isReviewing: Bool
        if case .reviewing = model.phase { isReviewing = true } else { isReviewing = false }

        if isReviewing {
            showIssueWindow()
        } else if let window = issueWindow {
            issueWindow = nil
            window.delegate = nil
            window.close()
        }

        if model.launchedByIconDrop {
            if model.isBusy && !isReviewing {
                showProgressWindow()
            } else {
                closeProgressWindow()
            }
        } else {
            closeProgressWindow()
            if dropWindow == nil { showDropWindow() }
        }
    }

    private func showDropWindow() {
        if let dropWindow {
            dropWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: DropView.windowSize.width, height: DropView.windowSize.height),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "DTP Zipper"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DropView(model: model))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("DropWindow")
        dropWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showProgressWindow() {
        guard progressWindow == nil else { return }
        let size = ProgressOnlyView.windowSize
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "DTP Zipper"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ProgressOnlyView(model: model))
        window.delegate = self
        window.center()
        progressWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeProgressWindow() {
        guard let window = progressWindow else { return }
        progressWindow = nil
        window.delegate = nil
        window.close()
    }

    private func showIssueWindow() {
        guard issueWindow == nil else { return }
        let size = IssueListView.defaultSize
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "Name Check")
        window.isReleasedWhenClosed = false
        window.contentMinSize = IssueListView.minimumSize
        window.contentView = NSHostingView(rootView: IssueListView(model: model))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("IssueWindow")
        issueWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === dropWindow {
            // 閉じるとアプリを終了する（v1 と同じ）。
            NSApp.terminate(nil)
            return false
        }
        // 問題一覧と進捗は［キャンセル］と同じ。
        model.cancel()
        return false
    }

    // MARK: - ZipperHost

    func showAlert(message: String, information: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = information
        alert.runModal()
    }

    func chooseDestination() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "The ZIP file can't be saved in the original folder. Choose where to save it.")
        panel.prompt = String(localized: "Save")
        return panel.runModal() == .OK ? panel.url : nil
    }

    func reveal(_ url: URL, placingNear source: URL?) {
        FinderReveal.select(url, placingNear: source)
    }

    func terminate() {
        NSApp.terminate(nil)
    }
}
