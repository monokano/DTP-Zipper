import AppKit

/// Finder で項目を選択する。
///
/// macOS の「圧縮」と同じく、項目を含むウインドウが開いていればそのウインドウで、
/// デスクトップの項目ならデスクトップで選択したい。`NSWorkspace.activateFileViewerSelecting` と
/// Finder の `select` は、開いているウインドウでは選択できるが、デスクトップの項目では Desktop の新しいウインドウを開く。
/// そこでデスクトップの項目だけ、Finder の `desktop` の項目として `selection` に設定する（2026-11-06 実測）。
///
/// 圧縮元（`source`）を渡すと、macOS の「圧縮」と同じく ZIP を圧縮元のアイコンの斜め右下
/// （アイコンの大きさの半分ずつ右と下）に置く（2026-11-07 実測。64 なら 32、128 なら 64）。
/// 「名前」順や「グリッドに沿う」では位置を設定できない（-10006）ので、そのときは選択だけする。
///
/// 初回は「Finder を制御」の確認が出る。拒否されたときや失敗したときは `activateFileViewerSelecting` に戻す。
/// Apple Events の送信には Hardened Runtime の権限（`AUTOMATION_APPLE_EVENTS`）と
/// Info.plist の `NSAppleEventsUsageDescription` が必要。
enum FinderReveal {
    static func select(_ url: URL, placingNear source: URL? = nil) {
        if !run(script(for: url, placingNear: source)) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Finder に送る AppleScript。
    static func script(for url: URL, placingNear source: URL?) -> String {
        let folder = url.deletingLastPathComponent()
        let onDesktop = isDesktop(folder)
        let zipName = quoted(url.lastPathComponent)
        // デスクトップの項目は `desktop` の項目として扱う（フォルダとして扱うと新しいウインドウが開く）。
        let container = onDesktop ? "desktop" : "(POSIX file \(quoted(folder.path)) as alias)"
        let zip = "item \(zipName) of \(container)"

        var placement = ""
        if let source, samePath(source.deletingLastPathComponent(), folder) {
            let item = "item \(quoted(source.lastPathComponent)) of \(container)"
            let (options, positionProperty) = onDesktop
                ? ("icon view options of window of desktop", "desktop position")
                : ("icon view options of container window of \(container)", "position")
            placement = """
                try
                    set s to icon size of \(options)
                    set p to \(positionProperty) of \(item)
                    set \(positionProperty) of \(zip) to {(item 1 of p) + s div 2, (item 2 of p) + s div 2}
                end try
            """
        }

        let selectCommand = onDesktop ? "set selection to \(zip)" : "select \(zip)"
        // 作った直後は Finder がまだファイルを認識していないことがあるので、少し待つ。
        return """
        tell application "Finder"
            activate
            repeat with i from 1 to 10
                if exists \(zip) then exit repeat
                if i is 10 then error number -1728
                delay 0.1
            end repeat
        \(placement)
            \(selectCommand)
        end tell
        """
    }

    /// 成功したら true。
    private static func run(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            NSLog("DTP Zipper: Finder select failed: %@", error)
            return false
        }
        return true
    }

    /// デスクトップのフォルダか。
    private static func isDesktop(_ folder: URL) -> Bool {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            return false
        }
        return samePath(folder, desktop)
    }

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// AppleScript の文字列リテラルにする。
    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
