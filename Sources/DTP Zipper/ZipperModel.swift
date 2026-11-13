import Foundation
import Combine

/// モデルが画面や OS に頼む操作。単体テストでは差し替える。
protocol ZipperHost: AnyObject {
    func showAlert(message: String, information: String)
    /// 保存先のフォルダを選ばせる。キャンセルなら nil。
    func chooseDestination() -> URL?
    /// Finder で選択する。`source` を渡すと、同じフォルダにあれば ZIP をそのアイコンの斜め右下に重ねて置く。
    func reveal(_ url: URL, placingNear source: URL?)
    func terminate()
}

/// アプリの状態と処理の流れ（仕様 §3）。
final class ZipperModel: ObservableObject {

    enum Phase {
        case idle
        case scanning(itemCount: Int)
        case compressing(completedBytes: UInt64, totalBytes: UInt64, path: String)
        case finished(URL)
        /// 問題一覧を表示中。`isChecking` は検査のやり直し中。
        case reviewing(ZipInspection, isChecking: Bool)
    }

    /// 設定のキー（仕様 §6.5）。
    private enum Key {
        static let nameEncoding = "nameEncoding"
        static let autoQuit = "autoQuit"
    }

    @Published var phase: Phase = .idle
    /// 未起動時のアイコンへのドロップで始まった処理か。true の間は進捗のみ表示する（仕様 §3）。
    @Published private(set) var launchedByIconDrop = false

    @Published var encoding: NameEncodingKind { didSet { optionsChanged() } }
    @Published var autoQuit: Bool { didSet { defaults.set(autoQuit, forKey: Key.autoQuit) } }
    /// パスワード付き ZIP にするか。保存せず、起動するたびにオフで始まる。
    @Published var usesPassword = false
    /// ZIP 暗号のパスワード。保存しない。使える文字は ASCII の印字可能文字だけ（`allowedPassword`）。
    @Published var password = ""
    /// パスワードがオンで空のままドロップされた。ドロップウインドウが入力欄へ移動する合図。
    @Published private(set) var passwordRequest = 0

    weak var host: ZipperHost?

    private let defaults: UserDefaults
    private var job: ZipJob?
    private var task: Task<Void, Never>?
    /// キャンセルしたが、一時ファイルの削除が済んでいないかもしれない処理。
    private var cancelledTasks: [Task<Void, Never>] = []
    /// 古い処理からの通知を無視するための番号。
    private var generation = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        encoding = NameEncodingKind(rawValue: defaults.string(forKey: Key.nameEncoding) ?? "") ?? .utf8
        autoQuit = defaults.object(forKey: Key.autoQuit) as? Bool ?? true
    }

    /// ⚠️ 既定のアクター分離が MainActor だと、deinit は最低OS 13.5 向けの互換処理
    /// （`swift_task_deinitOnExecutorMainActorBackDeploy`）を通り、そこで異常終了する（macOS 15.8.1 で実測）。
    nonisolated deinit {}

    // MARK: - 状態

    var options: NameOptions {
        NameOptions(encoding: encoding)
    }

    /// ドロップを受け付けるか。処理中と問題一覧の表示中は無視する（仕様 §3）。
    var canAcceptDrop: Bool {
        switch phase {
        case .idle, .finished: return true
        case .scanning, .compressing, .reviewing: return false
        }
    }

    /// 設定を変更できないか（ドロップウインドウの設定は処理中は無効）。
    var isBusy: Bool { !canAcceptDrop }

    // MARK: - 操作

    /// パスワードがオンなのに空か。このときはドロップを受け付けない。
    var isPasswordMissing: Bool { usesPassword && password.isEmpty }

    /// 入力されたパスワードから、使えない文字を除く。
    ///
    /// Windows はパスワードを ANSI コードページ（日本語版は CP932）のバイト列として扱い、macOS や他のアプリは
    /// UTF-8 として扱うので、ASCII 以外の文字は環境によって一致しない。そこで ASCII の印字可能文字（空白を含む）に限る。
    static func allowedPassword(_ text: String) -> String {
        String(text.unicodeScalars.filter { (0x20...0x7E).contains($0.value) }.map(Character.init))
    }

    /// 処理を始める。受け付けない状態なら何もしない。
    /// - Parameter launchedByIconDrop: 未起動時のアイコンへのドロップか。
    func start(urls: [URL], launchedByIconDrop: Bool = false) {
        guard canAcceptDrop, !urls.isEmpty else { return }
        if isPasswordMissing {
            passwordRequest += 1
            return
        }
        self.launchedByIconDrop = launchedByIconDrop
        job = ZipJob(urls: urls)
        phase = .scanning(itemCount: 0)
        runInspection(proceedIfClean: true)
    }

    /// 進捗や問題一覧の［キャンセル］。ドロップ待ちへ戻る。アイコンへのドロップで起動した場合は終了する。
    func cancel() {
        generation += 1
        if launchedByIconDrop {
            // 処理の中止と一時ファイルの削除は `prepareToTerminate` が待つ。
            host?.terminate()
            return
        }
        if let task {
            task.cancel()
            cancelledTasks.append(task)
        }
        task = nil
        returnToIdle()
    }

    /// ［再チェック］。同じ項目を走査し直し、問題がなくなれば圧縮へ進む。
    func recheck() {
        guard case .reviewing(let inspection, _) = phase else { return }
        phase = .reviewing(inspection, isChecking: true)
        runInspection(proceedIfClean: true)
    }

    /// ［続行］。警告のみのときに使う。
    func proceed() {
        guard case .reviewing(let inspection, isChecking: false) = phase, !inspection.hasStops else { return }
        compress(inspection, destination: nil)
    }

    /// 終了の準備。処理中なら中止して、一時ファイルの削除が済んでから `done` を呼ぶ。
    func prepareToTerminate(done: @escaping () -> Void) {
        generation += 1
        let running = cancelledTasks + [task].compactMap { $0 }
        guard !running.isEmpty else {
            done()
            return
        }
        running.forEach { $0.cancel() }
        task = nil
        cancelledTasks = []
        Task {
            for task in running { await task.value }
            done()
        }
    }

    // MARK: - 処理

    private func optionsChanged() {
        defaults.set(encoding.rawValue, forKey: Key.nameEncoding)
        // 問題一覧で設定を変えたら検査をやり直す。設定を続けて変えられるよう、自動では圧縮へ進まない。
        if case .reviewing(let inspection, _) = phase {
            phase = .reviewing(inspection, isChecking: true)
            runInspection(proceedIfClean: false)
        }
    }

    private func runInspection(proceedIfClean: Bool) {
        guard let job else { return }
        generation += 1
        let current = generation
        let options = self.options
        task?.cancel()
        task = Task { [weak self] in
            do {
                let inspection = try await job.inspect(options: options) { [weak self] progress in
                    self?.post(progress, generation: current)
                }
                self?.inspectionFinished(inspection, generation: current, proceedIfClean: proceedIfClean)
            } catch {
                self?.failed(error, generation: current)
            }
        }
    }

    private func inspectionFinished(_ inspection: ZipInspection, generation current: Int, proceedIfClean: Bool) {
        guard current == generation else { return }
        task = nil
        if inspection.isEmpty {
            host?.showAlert(message: String(localized: "There are no items to compress."),
                            information: String(localized: "All items were excluded."))
            launchedByIconDrop = false
            returnToIdle()
        } else if inspection.issues.isEmpty && proceedIfClean {
            compress(inspection, destination: nil)
        } else {
            phase = .reviewing(inspection, isChecking: false)
        }
    }

    private func compress(_ inspection: ZipInspection, destination: URL?) {
        guard let job else { return }
        // 圧縮を始めた時点のパスワードを使う。
        let zipPassword = usesPassword && !password.isEmpty ? password : nil
        generation += 1
        let current = generation
        phase = .compressing(completedBytes: 0, totalBytes: inspection.totalBytes, path: "")
        task = Task { [weak self] in
            do {
                let zip = try await job.compress(inspection, destination: destination, password: zipPassword) { [weak self] progress in
                    self?.post(progress, generation: current)
                }
                self?.compressionFinished(zip, source: inspection.firstItem, generation: current)
            } catch ZipJobError.destinationNotWritable {
                self?.destinationNotWritable(inspection, generation: current)
            } catch {
                self?.failed(error, generation: current)
            }
        }
    }

    private func compressionFinished(_ zip: URL, source: URL?, generation current: Int) {
        guard current == generation else { return }
        task = nil
        // 常に Finder で選択する。以前の設定 `revealInFinder` は読まない。
        // 保存先を選び直したときは元の項目と別のフォルダなので、重ねない（FinderReveal 側で判定）。
        host?.reveal(zip, placingNear: source)
        if autoQuit {
            host?.terminate()
        } else {
            launchedByIconDrop = false
            phase = .finished(zip)
        }
    }

    /// 保存先を選ばせる。キャンセルならドロップ待ちへ戻る（仕様 §5.1）。
    private func destinationNotWritable(_ inspection: ZipInspection, generation current: Int) {
        guard current == generation else { return }
        task = nil
        if let directory = host?.chooseDestination() {
            compress(inspection, destination: directory)
        } else {
            launchedByIconDrop = false
            returnToIdle()
        }
    }

    private func failed(_ error: Error, generation current: Int) {
        guard current == generation else { return }
        task = nil
        if !(error is CancellationError) {
            let (message, information) = Self.describe(error)
            host?.showAlert(message: message, information: information)
        }
        launchedByIconDrop = false
        returnToIdle()
    }

    private func returnToIdle() {
        phase = .idle
        job = nil
    }

    /// 処理のスレッドから受け取った進捗をメインスレッドで反映する。順序を保つため DispatchQueue を使う。
    private nonisolated func post(_ progress: ZipJobProgress, generation current: Int) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, current == self.generation else { return }
                switch progress {
                case .scanning(let count):
                    // 検査のやり直し中は、問題一覧の表示を保つ。
                    if case .scanning = self.phase { self.phase = .scanning(itemCount: count) }
                case .compressing(let completed, let total, let path):
                    if case .compressing = self.phase {
                        self.phase = .compressing(completedBytes: completed, totalBytes: total, path: path)
                    }
                }
            }
        }
    }

    // MARK: - エラーの文言

    /// エラーの見出しと説明。ファイル名と理由を示す（仕様 §5.5）。
    private static func describe(_ error: Error) -> (String, String) {
        func reason(_ url: URL, _ underlying: Error) -> String {
            url.path + "\n" + underlying.localizedDescription
        }
        switch error {
        case ItemScannerError.readFailed(let url, let underlying):
            return (String(localized: "The item could not be read."), reason(url, underlying))
        case ZipWriterError.readFailed(let url, let underlying):
            return (String(localized: "The file could not be read."), reason(url, underlying))
        case ZipWriterError.fileChanged(let url):
            return (String(localized: "The file changed while it was being compressed."), url.path)
        case ZipWriterError.writeFailed(let url, let underlying):
            return (String(localized: "The ZIP file could not be written."), reason(url, underlying))
        case ZipWriterError.compressionFailed(let url, let code):
            return (String(localized: "The file could not be compressed."), "\(url.path)\n(\(code))")
        case ZipWriterError.nameTooLong:
            return (String(localized: "A path is too long to store in a ZIP file."), "")
        case ZipJobError.nameNotEncodable(let path):
            return (String(localized: "A name could not be converted."), path)
        default:
            return (String(localized: "The ZIP file could not be created."), error.localizedDescription)
        }
    }
}
