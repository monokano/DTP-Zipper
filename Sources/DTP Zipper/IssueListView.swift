import SwiftUI
import AppKit

/// 問題一覧のタブ。フォントと名前は対処法が違うので分ける（仕様 §6.2）。
enum IssueTab: Hashable {
    case fonts
    case names
}

/// 問題一覧ウインドウ（仕様 §6.2）。
struct IssueListView: View {
    static let minimumSize = CGSize(width: 500, height: 400)
    /// 最初に開くときのサイズ。
    static let defaultSize = CGSize(width: 640, height: 480)

    @ObservedObject var model: ZipperModel
    @State private var tab: IssueTab
    @State private var selection = Set<IssueRow.ID>()

    init(model: ZipperModel, tab: IssueTab = .fonts) {
        self.model = model
        _tab = State(initialValue: tab)
    }

    private var inspection: ZipInspection? {
        if case .reviewing(let inspection, _) = model.phase { return inspection }
        return nil
    }

    private var isChecking: Bool {
        if case .reviewing(_, let checking) = model.phase { return checking }
        return false
    }

    private var rows: [IssueRow] {
        guard let inspection else { return [] }
        return inspection.issues.enumerated().map { IssueRow(id: $0.offset, issue: $0.element, item: inspection.items[$0.element.itemIndex]) }
    }

    /// E7 はフォントと認識できないファイルも含めて、フォントのタブに入れる（対処法が同じため）。
    private var fontRows: [IssueRow] { rows.filter { $0.issue.rule.isResourceForkOnly } }
    private var nameRows: [IssueRow] { rows.filter { !$0.issue.rule.isResourceForkOnly } }
    /// フォントと、それ以外の項目が両方あるときだけタブを出す。
    private var hasTabs: Bool { !fontRows.isEmpty && !nameRows.isEmpty }

    /// 表示するタブ。再チェックで片方がなくなれば、残っている方を表示する。
    private var visibleTab: IssueTab {
        if fontRows.isEmpty { return .names }
        if nameRows.isEmpty { return .fonts }
        return tab
    }

    private var visibleRows: [IssueRow] { visibleTab == .fonts ? fontRows : nameRows }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if visibleTab == .names {
                HStack {
                    Text("Encoding:")
                    EncodingPopup(model: model)
                }
            }
            table
            footer
        }
        .padding(16)
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
    }

    private var hasStops: Bool { inspection?.hasStops ?? false }
    private var hasIssues: Bool { !(inspection?.issues.isEmpty ?? true) }
    private var hasNameStops: Bool { nameRows.contains { $0.issue.rule.isStop } }

    private var header: some View {
        HStack(spacing: 12) {
            statusIcon
            headerText
        }
    }

    /// 停止は赤、警告のみは黄色。問題がなければ出さない。
    @ViewBuilder
    private var statusIcon: some View {
        if hasStops {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 38))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .red)
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
        } else if hasIssues {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.black, .yellow)
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
        }
    }

    private var headerText: some View {
        VStack(alignment: .leading, spacing: 4) {
            if hasTabs {
                Text("Some items can't be compressed.")
                    .font(.headline)
                Picker("Issue Type", selection: $tab) {
                    Text("Fonts (\(fontRows.count))").tag(IssueTab.fonts)
                    Text("Names (\(nameRows.count))").tag(IssueTab.names)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.vertical, 4)
                explanation
            } else if !fontRows.isEmpty {
                Text("Some fonts would break when compressed.")
                    .font(.headline)
                explanation
            } else if hasStops {
                Text("Contains inappropriate names.")
                    .font(.headline)
                explanation
            } else if hasIssues {
                Text("Please review these warnings.")
                    .font(.headline)
                explanation
            } else {
                Text("No problems were found.")
                    .font(.headline)
                Text("Click Continue to compress.")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 表示中の項目への対処法。
    @ViewBuilder
    private var explanation: some View {
        if visibleTab == .fonts {
            Text("They would break if zipped for Windows. Use the standard macOS compression.")
        } else if hasNameStops {
            Text("These names may become garbled when extracted.")
        } else {
            Text("You can continue, but check the items below first.")
        }
    }

    private var table: some View {
        Table(visibleRows, selection: $selection) {
            TableColumn("Name") { row in
                HStack(alignment: .top, spacing: 4) {
                    Image(nsImage: row.icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    nameText(row)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
            }
            .width(min: 100, ideal: 120)
            TableColumn("Problem") { row in
                Text(row.issue.message)
                    .foregroundColor(row.issue.rule.isStop ? .primary : .secondary)
                    .lineLimit(4)
            }
            .width(min: 160, ideal: 200)
            TableColumn("") { row in
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([row.item.url])
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .width(90)
        }
        .contextMenu(forSelectionType: IssueRow.ID.self) { ids in
            if !ids.isEmpty {
                Button("Show in Finder") { reveal(ids) }
            }
        } primaryAction: { ids in
            reveal(ids)
        }
    }

    /// 名前。macOS 15 以降は絵文字の背景を自前で描き、上下に拡げる。
    @ViewBuilder
    private func nameText(_ row: IssueRow) -> some View {
        if #available(macOS 15, *) {
            row.highlightedText
                .textRenderer(EmojiHighlightRenderer())
        } else {
            Text(row.highlightedName)
        }
    }

    private var footer: some View {
        HStack {
            if isChecking {
                ProgressView()
                    .controlSize(.small)
                Text("Checking…")
                    .foregroundStyle(.secondary)
            } else {
                Text(model.options.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { model.cancel() }
                .keyboardShortcut(.cancelAction)
            Button("Check Again") { model.recheck() }
                .disabled(isChecking)
            Button("Continue") { model.proceed() }
                .keyboardShortcut(.defaultAction)
                .disabled(isChecking || hasStops)
        }
    }

    private func reveal(_ ids: Set<IssueRow.ID>) {
        let urls = rows.filter { ids.contains($0.id) }.map(\.item.url)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
}

/// 一覧の1行。1項目に複数の問題があれば行を分ける。
struct IssueRow: Identifiable {
    let id: Int
    let issue: NameIssue
    let item: ScannedItem

    /// Finder と同じアイコン。
    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: item.url.path)
    }

    /// 問題の文字を赤で示す。文字はそのまま表示し、制御文字のように見えないものだけ赤い `▁` にする。
    /// カラー絵文字は文字色が効かないので、赤い背景で示す。
    var highlightedName: AttributedString {
        let marked = Set(issue.scalarOffsets)
        var result = AttributedString()
        var plain = String.UnicodeScalarView()

        func flush() {
            if !plain.isEmpty {
                result += AttributedString(String(plain))
                plain = String.UnicodeScalarView()
            }
        }

        func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
            scalar.properties.generalCategory == .control
                || scalar.properties.generalCategory == .format
                || scalar.properties.generalCategory == .lineSeparator
                || scalar.properties.generalCategory == .paragraphSeparator
                || scalar == " "
        }

        var offset = 0
        for character in issue.name {
            let scalars = Array(character.unicodeScalars)
            let start = offset
            offset += scalars.count

            // 合成された絵文字（肌色、ZWJ など）は分けずに、まとまり全体へ背景を付ける。
            // 見えない文字だけが問題のときは、その位置がわかるよう下の処理で `▁` にする。
            let hasVisibleMark = scalars.indices.contains { marked.contains(start + $0) && !isInvisible(scalars[$0]) }
            if hasVisibleMark && Self.usesColorGlyphs(character) {
                flush()
                var emoji = AttributedString(String(character))
                emoji.foregroundColor = .red
                emoji.backgroundColor = Self.emojiHighlight
                result += emoji
                continue
            }

            for (index, scalar) in scalars.enumerated() {
                if marked.contains(start + index) {
                    flush()
                    var red = AttributedString(isInvisible(scalar) ? "▁" : String(scalar))
                    red.foregroundColor = .red
                    result += red
                } else if scalar.properties.generalCategory == .control {
                    // 赤で示さない制御文字も、そのままでは行が崩れるので記号にする。
                    flush()
                    result += AttributedString("▁")
                } else {
                    plain.append(scalar)
                }
            }
        }
        flush()
        return result
    }

    /// カラー絵文字を示す背景色。ダークでは背景に沈むので濃くする。
    static let emojiHighlight = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor.systemRed.withAlphaComponent(isDark ? 0.85 : 0.6)
    })

    /// `highlightedName` と同じ内容。絵文字の背景は属性ではなく目印にして、`EmojiHighlightRenderer` で描く。
    @available(macOS 15, *)
    var highlightedText: Text {
        let name = highlightedName
        var result = Text(verbatim: "")
        for run in name.runs {
            var piece = AttributedString(name[run.range])
            let text: Text
            if run.backgroundColor != nil {
                piece.backgroundColor = nil
                text = Text(piece).customAttribute(EmojiHighlightAttribute())
            } else {
                text = Text(piece)
            }
            result = Text("\(result)\(text)")
        }
        return result
    }

    /// カラーのグリフ（Apple Color Emoji など）で描かれる文字か。
    /// `☺` のように、絵文字でも白黒で描かれる文字は文字色が効くので、実際に使われるフォントで判定する。
    private static func usesColorGlyphs(_ character: Character) -> Bool {
        guard character.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0x7F }) else { return false }
        let text = NSAttributedString(string: String(character),
                                      attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        let line = CTLineCreateWithAttributedString(text)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return false }
        return runs.contains { run in
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName] else { return false }
            let font = value as! CTFont
            return CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
        }
    }
}

/// 赤い背景を付ける絵文字の目印。
@available(macOS 15, *)
struct EmojiHighlightAttribute: TextAttribute {}

/// 絵文字の背景を、文字の高さより上下に拡げた角丸で描く。
/// 属性の背景色は行の高さに固定され、拡げられないため。
@available(macOS 15, *)
struct EmojiHighlightRenderer: TextRenderer {
    /// 上下に拡げる量。折り返したときに隣の行へ重ならない範囲にする。
    static let verticalOutset: CGFloat = 3
    static let horizontalOutset: CGFloat = 1
    static let cornerRadius: CGFloat = 4

    var displayPadding: EdgeInsets {
        EdgeInsets(top: Self.verticalOutset, leading: Self.horizontalOutset,
                   bottom: Self.verticalOutset, trailing: Self.horizontalOutset)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line where run[EmojiHighlightAttribute.self] != nil {
                let rect = run.typographicBounds.rect
                    .insetBy(dx: -Self.horizontalOutset, dy: -Self.verticalOutset)
                context.fill(Path(roundedRect: rect, cornerRadius: Self.cornerRadius),
                             with: .color(IssueRow.emojiHighlight))
            }
        }
        for line in layout {
            context.draw(line)
        }
    }
}

extension NameIssue {
    /// 問題の説明。E2 は文字の種類ごとの文言にする。
    var message: String {
        notPreservedKind?.message ?? rule.message
    }
}

extension NotPreservedKind {
    /// 問題の説明。ヘルプ「問題の内容と対処」の「文字化けのおそれがある文字」の見出しと同じ。
    var message: String {
        switch self {
        case .platformDependent:
            return String(localized: "Platform-dependent character or similar")
        case .differsByPlatform:
            return String(localized: "Character incompatible between Windows and Mac")
        case .notInShiftJIS:
            return String(localized: "Character not in Shift_JIS")
        case .userDefined:
            return String(localized: "User-defined character")
        }
    }
}

extension NameRule {
    /// 問題の説明。
    var message: String {
        switch self {
        case .forbiddenCharacter:
            return String(localized: "Character not allowed on Windows")
        case .notPreserved:
            return String(localized: "Character that may be garbled")
        case .controlCharacter:
            return String(localized: "Control character")
        case .reservedName:
            return String(localized: "Reserved name on Windows")
        case .trailingSpaceOrPeriod:
            return String(localized: "Ends with a space or period")
        case .nameCollision:
            return String(localized: "Same name except for case at the same level")
        case .fontResourceForkOnly:
            return String(localized: "Font whose data would be lost")
        case .resourceForkOnly:
            return String(localized: "File whose data would be lost")
        case .trailing5C:
            return String(localized: "May not extract correctly. Putting it in a folder avoids this")
        case .longPath:
            return String(localized: "Path too long")
        case .excludedLink:
            return String(localized: "Aliases and symbolic links aren't included in the ZIP file")
        case .compatibilityIdeograph:
            return String(localized: "Compatibility ideograph (may change to a unified ideograph)")
        }
    }
}
