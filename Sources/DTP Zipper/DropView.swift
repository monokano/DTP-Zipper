import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// ドロップウインドウ（仕様 §6.1）。
struct DropView: View {
    static let windowSize = CGSize(width: 400, height: 280)

    @ObservedObject var model: ZipperModel
    @State private var isTargeted = false
    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            statusArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(dropHighlight)
                .padding(12)
            settings
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .disabled(model.isBusy)
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            guard model.canAcceptDrop else { return false }
            Self.loadURLs(from: providers) { urls in model.start(urls: urls) }
            return true
        }
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(isTargeted && model.canAcceptDrop ? Color.accentColor : Color.clear, lineWidth: 3)
            .background(RoundedRectangle(cornerRadius: 10).fill(isTargeted && model.canAcceptDrop ? Color.accentColor.opacity(0.12) : Color.clear))
    }

    @ViewBuilder
    private var statusArea: some View {
        switch model.phase {
        case .idle, .reviewing:
            waiting(label: Text("Drop Folders or Files"))
        case .scanning, .compressing:
            ProgressContent(model: model)
                .padding(.horizontal, 16)
        case .finished(let zip):
            VStack(spacing: 12) {
                Image("DropIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                Text("The ZIP file was created.")
                Button("Show in Finder") {
                    model.host?.reveal(zip, placingNear: nil)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func waiting(label: Text) -> some View {
        VStack(spacing: 12) {
            Image("DropIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 130, height: 130)
            label
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }

    /// 下部の設定（仕様 §6.1）。ラベルは付けず、2行に並べる。
    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            EncodingPopup(model: model)
            HStack(spacing: 12) {
                Toggle("Quit When Done", isOn: $model.autoQuit)
                    .fixedSize()
                HStack(spacing: 6) {
                    Toggle("Password", isOn: $model.usesPassword)
                        .fixedSize()
                    // 相手に伝える文字なので、隠さずに表示する（打ち間違いに気づけるように）。
                    TextField("", text: $model.password)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .focused($isPasswordFocused)
                        .disabled(!model.usesPassword)
                        .accessibilityLabel(Text("Password"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: model.usesPassword) { isOn in
            if isOn { isPasswordFocused = true }
        }
        .onChange(of: model.password) { text in
            let allowed = ZipperModel.allowedPassword(text)
            if allowed != text {
                model.password = allowed
                NSSound.beep()
            }
        }
        .onChange(of: model.passwordRequest) { _ in
            // パスワードがオンで空のままドロップされた。入力を促す。
            NSSound.beep()
            isPasswordFocused = true
        }
    }

    /// ドロップされた順に URL を集める。
    private static func loadURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        var results = [URL?](repeating: nil, count: providers.count)
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    results[index] = url
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            completion(results.compactMap { $0 })
        }
    }
}

/// エンコーディングのポップアップと、選択中の項目の注記。ドロップウインドウと問題一覧で共通。ラベルは呼び出し側で並べる。
struct EncodingPopup: View {
    @ObservedObject var model: ZipperModel

    var body: some View {
        HStack(spacing: 8) {
            Picker("Encoding:", selection: $model.encoding) {
                Text("UTF-8").tag(NameEncodingKind.utf8)
                Text("Shift_JIS").tag(NameEncodingKind.cp932)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 100)
            HStack(spacing: 4) {
                if isCaution {
                    cautionIcon
                }
                note
                    .font(.caption)
                    .foregroundStyle(isCaution ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    /// Shift_JIS は前回の選択が残るので、気づかずに圧縮しないよう目立たせる。
    private var isCaution: Bool { model.encoding == .cp932 }

    /// 黄色の三角に黒の `!`。`!` が抜きにならないよう 2 色で描く。注記より大きい通常の文字サイズにする。
    private var cautionIcon: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.body)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.black, .yellow)
            .accessibilityHidden(true)
    }

    private var note: Text {
        switch model.encoding {
        case .utf8: return Text("Full support on Windows 8+")
        case .cp932: return Text("For older apps like Lhaplus")
        }
    }
}

/// 走査中と圧縮中の表示。
struct ProgressContent: View {
    @ObservedObject var model: ZipperModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.phase {
            case .scanning(let count):
                Text("Scanning…")
                ProgressView()
                    .progressViewStyle(.linear)
                Text("\(count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .compressing(let completed, let total, let path):
                Text("Compressing…")
                ProgressView(value: total == 0 ? 0 : Double(completed) / Double(total))
                    .progressViewStyle(.linear)
                Text(path.isEmpty ? " " : path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            default:
                EmptyView()
            }
            HStack {
                Text(model.options.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}

/// アイコンへのドロップで起動したときの、進捗のみのウインドウ（仕様 §3）。
struct ProgressOnlyView: View {
    static let windowSize = CGSize(width: 420, height: 130)

    @ObservedObject var model: ZipperModel

    var body: some View {
        ProgressContent(model: model)
            .padding(16)
            .frame(width: Self.windowSize.width, height: Self.windowSize.height)
    }
}

extension NameOptions {
    /// どの設定で処理しているかの表示（仕様 §6.1）。
    var summary: String {
        switch encoding {
        case .cp932: return "Shift_JIS"
        case .utf8: return "UTF-8"
        }
    }
}
