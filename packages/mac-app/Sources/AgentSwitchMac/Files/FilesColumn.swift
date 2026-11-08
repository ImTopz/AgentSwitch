import AgentSwitchMacCore
import AppKit
import SwiftUI

// The Files column (docs/files-v0.md; demo docs/design/concepts/files.html): the main window's own column on its right,
// above every page — open or not, beside the page or floating over it, where it is and what is open in it, by node.
// What it lists is the service's (`/files…`), on the node the window is on; the rules (locked places, a paired
// device's scope) are the service's too.

/// One file of the column given to an agent (Add to Reply, a drag): where it is on the node, and what the reply needs
/// to know of it.
struct FilesPick: Equatable, Sendable {
    let path: String
    let name: String
    let folder: Bool
    /// It may hold a password or a key (files-v0 §4): asked about before it goes in.
    let sensitive: Bool
    /// `path` is on the node the terminals are on (the Files column's); false: this Mac's, dropped from Finder.
    var onNode = true

    var image: Bool { !folder && TerminalDraft.isImage(name: name) }
}

/// Where `Add to Reply` puts what is selected (files-v0 §4): the pane in focus's reply box or its terminal, Dispatch's
/// input. Nil: the page has no reply box (Browser, Clash).
struct FilesTarget {
    /// What it is, for the button's help: the terminal's name, `Dispatch`.
    let name: String
    let give: ([FilesPick]) -> Void
}

/// A name being typed in place (docs/files-v0.md §12.2): a new file or folder in a folder, or an item's new name.
struct FilesEdit: Equatable {
    enum Kind: Equatable {
        case newFile(in: String)
        case newFolder(in: String)
        case rename(String)
    }

    let kind: Kind
    var text: String
    /// What the service said of the name last tried (a name the disk takes for one already there); gone once typed on.
    var refused: String?
    let id = UUID()

    var folder: Bool { if case .newFolder = kind { return true }; return false }
}

/// A question before a change goes on (docs/files-v0.md §12.2): only these are asked on the Mac.
struct FilesQuestion: Equatable {
    enum Kind: Equatable {
        case renameInUse(path: String, name: String)
        case trashInUse([String])
        case noTrash([String])
    }

    let kind: Kind
    let text: String

    /// What the box's head says, and its button that goes on.
    var head: String { if case .noTrash = kind { return "Move to Trash" }; return "In Use" }
    var go: String {
        switch kind {
        case .renameInUse: "Rename"
        case .trashInUse: "Move to Trash"
        case .noTrash: "Delete Permanently"
        }
    }
}

@MainActor
@Observable
final class FilesColumn {
    enum Arrangement: String { case tree, folders }

    /// Bounds of the column's width (files-v0 §2), and the page's least width beside it before it floats.
    static let widths: ClosedRange<CGFloat> = 240...560
    static let leastPage: CGFloat = 520
    /// From this width the classic look's folders are Finder's columns (files-v0 §3.3).
    static let columnsFrom: CGFloat = 460
    /// How often the folders on screen are asked again (the terminals' list's pace).
    static let poll: Duration = .seconds(3)

    // What is remembered, by node.
    private(set) var open = false
    var floating = false { didSet { keep("floating", floating) } }
    var width: CGFloat = 300 { didSet { keep("width", Double(width)) } }
    /// `As Tree` / `As Folders`; nil: the look's own (the pixel look's tree, the classic look's folders).
    var arrangement: Arrangement? { didSet { keep("arrangement", arrangement?.rawValue) } }
    var showHidden = false { didSet { keep("hidden", showHidden); refreshAll() } }
    var showPreview = true { didSet { keep("preview", showPreview) } }
    var previewShare: CGFloat = 0.45 { didSet { keep("previewShare", Double(previewShare)) } }
    var sort: FilesSort = .name { didSet { keep("sort", sort.rawValue) } }
    /// The folder shown (the tree's root, the level the folders show). Nil until the column first opens: home then.
    private(set) var root: String?
    private(set) var expanded: Set<String> = []
    private(set) var recent: [String] = []

    // What is on screen now.
    private(set) var levels: [String: FileLevel] = [:]
    private var versions: [String: String] = [:]
    private(set) var refusals: [String: FilesRefusal] = [:]
    private(set) var selection: [String] = []
    private var anchor: String?
    private(set) var back: [String] = []
    private(set) var forward: [String] = []
    /// The details of what is selected, once read (`/files/stat`).
    private(set) var details: [String: FileDetails] = [:]
    /// A text file's start, as the service gives it (every node's: Quick Look takes `.ts` for a video and draws its
    /// icon); another node's picture's small copy.
    private(set) var remoteText: FileTextPreview?
    private(set) var remoteImage: NSImage?
    /// The home folder the service says (the levels name it).
    private(set) var home: String?
    /// The path row being typed into (`Go to Folder…`).
    var going: String?
    /// Something went wrong that is not one folder's (a file could not be opened).
    private(set) var notice: String?

    // Changes (docs/files-v0.md §12.2).
    /// A name being typed in place.
    var edit: FilesEdit?
    /// The line at the column's foot for what was just done: moved to the Trash, put back, why not.
    private(set) var said: String?
    /// Asked before a change goes on: a folder a terminal runs in, or what the Trash would not take.
    private(set) var question: FilesQuestion?
    private(set) var history = FilesHistory()
    /// The look the column is drawn in (the key view says): where a new item goes depends on the view shown.
    @ObservationIgnored var classic = false

    /// The node the window is on (nil: this Mac) and its name, for what is said of its rules.
    let node: String?
    let nodeName: String
    private let client: () -> DaemonClient
    private let defaults: UserDefaults?
    /// Where `Add to Reply` lands now (the window says).
    var target: () -> FilesTarget? = { nil }
    /// The folder of the pane in focus (the window says): where `Copy Relative Path` starts and the bar's icon goes.
    var paneFolder: () -> String? = { nil }
    /// `New Terminal Here`.
    var newTerminal: (String) -> Void = { _ in }
    /// The keyboard back to the page (esc in the column beside the page).
    var focusPage: () -> Void = {}
    /// The view the list's keys come to (FilesKeyView): Quick Look and the keyboard go through it.
    @ObservationIgnored weak var keys: NSView?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var detailing: Task<Void, Never>?
    @ObservationIgnored private var active = false
    /// Where another node's files are fetched to for Quick Look and Open (removed when the column goes).
    @ObservationIgnored private lazy var downloads: URL = FileManager.default.temporaryDirectory.appendingPathComponent("agentswitch-files-\(UUID().uuidString.prefix(8))")

    init(node: String?, nodeName: String, client: @escaping () -> DaemonClient, defaults: UserDefaults?) {
        self.node = node
        self.nodeName = nodeName
        self.client = client
        self.defaults = defaults
        restore()
    }

    var local: Bool { node == nil }

    // MARK: remembered

    private func key(_ name: String) -> String { "files.\(node ?? "local").\(name)" }
    private func keep(_ name: String, _ value: Any?) { defaults?.set(value, forKey: key(name)) }

    private func restore() {
        guard let d = defaults else { return }
        open = d.bool(forKey: key("open"))
        floating = d.bool(forKey: key("floating"))
        if let w = d.object(forKey: key("width")) as? Double { width = min(max(CGFloat(w), Self.widths.lowerBound), Self.widths.upperBound) }
        arrangement = d.string(forKey: key("arrangement")).flatMap(Arrangement.init(rawValue:))
        showHidden = d.bool(forKey: key("hidden"))
        if d.object(forKey: key("preview")) != nil { showPreview = d.bool(forKey: key("preview")) }
        if let share = d.object(forKey: key("previewShare")) as? Double { previewShare = min(max(CGFloat(share), 0.15), 0.85) }
        sort = d.string(forKey: key("sort")).flatMap(FilesSort.init(rawValue:)) ?? .name
        root = d.string(forKey: key("root"))
        expanded = Set(d.stringArray(forKey: key("expanded")) ?? [])
        recent = d.stringArray(forKey: key("recent")) ?? []
    }

    private func keepPlace() {
        keep("root", root)
        keep("expanded", Array(expanded.prefix(200)))
        keep("recent", recent)
    }

    // MARK: open, closed, where

    /// The window shows the column, or another page of it: what is on screen is asked again while it is seen.
    func setActive(_ seen: Bool) {
        let was = active
        active = seen
        guard seen, open else { polling?.cancel(); polling = nil; return }
        if !was { if root == nil { go(to: nil) } else { refreshAll() } }
        watch()
    }

    /// The bar's icon, a pane's, ⌘⇧F: open at `folder` (or where it was, home the first time); open there already,
    /// closed.
    func toggle(at folder: String?) {
        if open, folder == nil || folder == root { close() } else { show(folder: folder) }
    }

    /// `Show in Files`: open at `folder`, or where it was.
    func show(folder: String?) {
        if !open {
            open = true
            keep("open", true)
        }
        if let folder { go(to: folder) } else if root == nil { go(to: nil) } else { refreshAll() }
        if active { watch() }
    }

    /// A file named elsewhere (an answer's file, docs/simple-view-v0.md §5.16): the column open at its folder with the
    /// file selected, so its preview shows and `Open`, `Download` and the rest are a right click away.
    func show(file path: String) {
        guard let folder = FilesPath.parent(of: path) else { return show(folder: nil) }
        show(folder: folder)
        Task { await reveal(path, reading: folder) }
    }

    /// The list takes the keyboard (a row clicked): its keys, and Quick Look's panel, go through it.
    func focusKeys() {
        guard let keys, let window = keys.window, window.firstResponder !== keys else { return }
        window.makeFirstResponder(keys)
    }

    /// The list has the keyboard.
    var hasKeys: Bool { keys.map { $0.window?.firstResponder === $0 } ?? false }

    func close() {
        open = false
        keep("open", false)
        polling?.cancel()
        polling = nil
        endQuickLook()
        focusPage()
    }

    /// The view in force: as asked, else the look's own.
    func shown(classic: Bool) -> Arrangement { arrangement ?? (classic ? .folders : .tree) }

    /// Finder's columns: the classic look's folders, wide.
    func columns(classic: Bool) -> Bool { classic && shown(classic: classic) == .folders && width >= Self.columnsFrom }

    /// A folder as the shown one (the path row, `../`, a double click, `Open`). Nil: where this viewer starts.
    func go(to folder: String?, history: Bool = true) {
        if folder == root, folder != nil { return refresh(folder!) }
        if history, let root { back.append(root); forward = [] }
        root = folder
        selection = []
        anchor = nil
        notice = nil
        said = nil
        edit = nil
        if let folder {
            recent = Array(([folder] + recent.filter { $0 != folder }).prefix(5))
            refresh(folder)
        } else {
            Task { await load(nil) }
        }
        keepPlace()
    }

    func goHome() { go(to: home ?? (local ? NSHomeDirectory() : nil)) }
    func goUp() { if let root, let up = levels[root]?.parent ?? FilesPath.parent(of: root) { go(to: up) } }
    func goBack() { guard let last = back.popLast() else { return }; if let root { forward.append(root) }; go(to: last, history: false) }
    func goForward() { guard let next = forward.popLast() else { return }; if let root { back.append(root) }; go(to: next, history: false) }

    /// `Go to Folder…`: the path row becomes a field; a path or `~/…`.
    func goTyped(_ text: String) {
        going = nil
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let base = home ?? NSHomeDirectory()
        let path = raw == "~" ? base : raw.hasPrefix("~/") ? base + raw.dropFirst(1) : raw
        guard path.hasPrefix("/") else { notice = "请输入以 / 或 ~ 开头的路径。"; return }
        go(to: (path as NSString).standardizingPath)
    }

    // MARK: the tree

    /// A folder's `▸` / `▾`; `all` (⌥-click): every folder under it too, as far as their levels have been read.
    func twist(_ path: String, all: Bool = false) {
        if expanded.contains(path) {
            expanded = all ? expanded.filter { !FilesPath.contains(path, $0) } : expanded.subtracting([path])
        } else {
            expanded.insert(path)
            refresh(innerOf(path))
            if all, let level = levels[innerOf(path)] {
                for entry in level.entries where entry.isFolder && !entry.locked { let p = FilesPath.join(path, entry.name); expanded.insert(p); refresh(innerOf(p)) }
            }
        }
        keepPlace()
    }

    /// The folder a path's children come from: a link's target.
    func innerOf(_ path: String) -> String {
        guard let parent = FilesPath.parent(of: path), let entry = levels[parent]?.entries.first(where: { $0.name == (path as NSString).lastPathComponent }),
              entry.kind == .link, let target = entry.link?.target else { return path }
        return target
    }

    func treeRows() -> [FilesTreeRow] {
        guard let root else { return [] }
        return FilesTree.rows(root: root, levels: levels, open: expanded, order: sort, hidden: showHidden)
    }

    /// A level's entries as shown: ordered, hidden ones only when asked.
    func entries(of folder: String) -> [FileEntry] {
        sort.sorted((levels[folder]?.entries ?? []).filter { showHidden || !$0.hidden })
    }

    /// What the keyboard walks, in order.
    func visible(classic: Bool) -> [String] {
        guard let root else { return [] }
        if shown(classic: classic) == .tree { return treeRows().map(\.path) }
        return entries(of: root).map { FilesPath.join(root, $0.name) }
    }

    func entry(_ path: String) -> FileEntry? {
        guard let parent = FilesPath.parent(of: path) else { return FileEntry(name: "/", kind: .dir) }
        let name = (path as NSString).lastPathComponent
        return (levels[parent] ?? levels[innerOf(parent)])?.entries.first { $0.name == name }
    }

    // MARK: selection

    /// A click: one; ⌘: one more or one less; ⇧: the run from the last one clicked.
    func select(_ path: String, command: Bool = false, shift: Bool = false, classic: Bool) {
        guard let entry = entry(path), !entry.locked else { return }
        said = nil
        if command {
            selection = selection.contains(path) ? selection.filter { $0 != path } : selection + [path]
            anchor = path
        } else if shift, let anchor {
            let order = visible(classic: classic)
            if let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: path) {
                selection = order[min(a, b)...max(a, b)].filter { !(self.entry($0)?.locked ?? true) }
            }
        } else {
            selection = [path]
            anchor = path
        }
        selected()
    }

    func selectAll(classic: Bool) {
        selection = visible(classic: classic).filter { !(entry($0)?.locked ?? true) }
        selected()
    }

    func clearSelection() { selection = []; selected() }

    /// ↑ ↓: the one before or after the last selected (⇧: the run grows).
    func move(_ step: Int, extend: Bool, classic: Bool) {
        let order = visible(classic: classic).filter { !(entry($0)?.locked ?? true) }
        guard !order.isEmpty else { return }
        let at = selection.last.flatMap { order.firstIndex(of: $0) }
        let next = at.map { min(max($0 + step, 0), order.count - 1) } ?? (step > 0 ? 0 : order.count - 1)
        if extend { select(order[next], shift: true, classic: classic) } else { selection = [order[next]]; anchor = order[next]; selected() }
    }

    func jump(toFirst first: Bool, classic: Bool) {
        let order = visible(classic: classic).filter { !(entry($0)?.locked ?? true) }
        guard let path = first ? order.first : order.last else { return }
        selection = [path]; anchor = path; selected()
    }

    /// Typed letters: the next entry whose name starts so.
    func typeahead(_ prefix: String, classic: Bool) {
        let order = visible(classic: classic)
        let names = order.map { ($0 as NSString).lastPathComponent }
        guard let i = FilesTypeahead.next(prefix, in: names, after: selection.last.flatMap { order.firstIndex(of: $0) }) else { return }
        selection = [order[i]]; anchor = order[i]; selected()
    }

    /// What is selected changed: its details, and another node's file's preview, are asked for.
    private func selected() {
        detailing?.cancel()
        remoteText = nil
        remoteImage = nil
        guard selection.count == 1, let path = selection.first else { return refreshQuickLook() }
        let client = client
        let remote = !local
        detailing = Task { [weak self] in
            guard let d = try? await client().fileDetails(path: path), !Task.isCancelled, let self else { return }
            self.details[path] = d
            if d.type == .text { self.remoteText = try? await client().fileTextPreview(path: path) }
            if remote, d.type == .image, let data = try? await client().fileThumbnail(path: path) { self.remoteImage = NSImage(data: data) }
        }
        refreshQuickLook()
    }

    var selectedSize: Int64 { selection.compactMap { entry($0)?.size }.reduce(0, +) }

    // MARK: reading

    /// The shown folder and the folders open under it on screen, asked again.
    private func refreshAll() {
        guard let root else { return }
        refresh(root)
        for row in treeRows() where row.open { refresh(FilesTree.inner(of: row)) }
    }

    func refresh(_ folder: String) { Task { await load(folder) } }

    /// One level read (again): unchanged since the version held, nothing more.
    private func load(_ folder: String?) async {
        do {
            let version = folder.flatMap { versions[$0] }
            guard let answer = try await client().fileLevel(path: folder, hidden: true, version: levels[folder ?? ""] == nil ? nil : version) else { return }
            let level = answer.value
            levels[level.path] = level
            versions[level.path] = answer.version
            refusals[level.path] = nil
            if home == nil { home = level.home }
            if folder == nil {
                // Where this viewer starts: the shown folder now.
                root = level.path
                recent = Array(([level.path] + recent.filter { $0 != level.path }).prefix(5))
                keepPlace()
            }
            // A selected entry that is gone goes from the selection.
            let gone = selection.filter { FilesPath.parent(of: $0) == level.path && entry($0) == nil }
            if !gone.isEmpty { selection.removeAll { gone.contains($0) } }
        } catch {
            guard let folder else { return }
            let refusal = FilesRefusal(error)
            // The service not answering once (a poll in a hiccup) leaves what is shown; its own refusal replaces it.
            if case .other = refusal, levels[folder] != nil { return }
            refusals[folder] = refusal
            levels[folder] = nil
            versions[folder] = nil
        }
    }

    private func watch() {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.poll)
                guard let self, !Task.isCancelled, self.open, self.active else { return }
                self.refreshAll()
            }
        }
    }

    // MARK: what is done to them

    /// The picks as `Add to Reply` gives them: the reason one may hold a password from the service where it said, else
    /// this Mac's own table for this Mac's files.
    func picks(_ paths: [String]) -> [FilesPick] {
        paths.compactMap { path in
            guard let e = entry(path), !e.locked else { return nil }
            let sensitive = details[path]?.sensitive != nil || (local && FilesSensitive.reason(path) != nil)
            return FilesPick(path: path, name: e.name, folder: e.isFolder, sensitive: sensitive)
        }
    }

    /// `Add to Reply` (the button, the menu, ⌥↩): what is selected (or `paths`) to the reply where it lands now.
    func addToReply(_ paths: [String]? = nil) {
        let chosen = picks(paths ?? selection)
        guard !chosen.isEmpty, let target = target() else { return }
        // Another node's files not told of yet: asked for first, so that one that may hold a password is asked about.
        let unknown = local ? [] : chosen.filter { details[$0.path] == nil }.map(\.path)
        guard !unknown.isEmpty else { return target.give(chosen) }
        let client = client
        Task { [weak self] in
            for path in unknown { if let d = try? await client().fileDetails(path: path) { self?.details[path] = d } }
            guard let self else { return }
            target.give(self.picks(chosen.map(\.path)))
        }
    }

    /// `Open`: a folder as the shown one; a file to its own application (another node's is fetched first).
    func open(_ path: String) {
        guard let e = entry(path), !e.locked else { return }
        if e.isFolder { return go(to: e.kind == .link ? e.link?.target ?? path : path) }
        if local { NSWorkspace.shared.open(URL(fileURLWithPath: path)); return }
        Task { [weak self] in
            guard let url = await self?.fetched(path) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    func openSelection() { for path in selection { open(path) } }

    /// `Download` (docs/files-v0.md §13): another node's files into this Mac's Downloads folder, as a browser saves —
    /// no panel; a name already there gets a number. Files only (a folder would have to be packed). The foot line
    /// says while they come and once they are here; one that could not come stops the rest.
    func download(_ paths: [String]) {
        guard !local else { return }
        let files = paths.filter { entry($0).map { !$0.isFolder && !$0.locked } ?? false }
        guard !files.isEmpty else { return }
        said = FilesWords.downloading(files)
        Task { [weak self] in
            guard let self else { return }
            var saved: [String] = []
            for path in files {
                let to = FilesDownloads.free(in: FilesDownloads.folder(), name: (path as NSString).lastPathComponent)
                do {
                    try await self.client().downloadFile(path: path, to: to)
                    // From another node, as a browser's download is marked: Gatekeeper looks at it before it runs.
                    try? DispatchQuarantine.mark(to)
                    saved.append(to.path)
                } catch {
                    let refusal = FilesRefusal(error)
                    self.said = refusal == .tooLarge ? FilesWords.notDownloaded(node: self.nodeName) : refusal.sentence(node: self.nodeName)
                    return
                }
            }
            self.said = FilesWords.downloaded(saved)
        }
    }

    func showInFinder(_ paths: [String]) {
        guard local else { return }
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }

    func copyPaths(_ paths: [String], relative: Bool = false) {
        let base = paneFolder()
        let text = paths.map { p in relative ? base.flatMap { FilesPath.relative(p, to: $0) } ?? p : p }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Every path is under the pane in focus's folder: `Copy Relative Path` means something.
    func relativeAvailable(_ paths: [String]) -> Bool {
        guard let base = paneFolder() else { return false }
        return paths.allSatisfy { FilesPath.relative($0, to: base) != nil }
    }

    /// Another node's file on this Mac, for Quick Look and Open: fetched into the column's own folder.
    private func fetched(_ path: String) async -> URL? {
        let size = entry(path)?.size ?? 0
        guard size <= 25 * 1024 * 1024 else { notice = FilesRefusal.tooLarge.sentence(); return nil }
        let to = downloads.appendingPathComponent(UUID().uuidString.prefix(8).description).appendingPathComponent((path as NSString).lastPathComponent)
        do { return try await client().downloadFile(path: path, to: to) } catch {
            notice = FilesRefusal(error).sentence(node: nodeName)
            return nil
        }
    }


    // MARK: changes (docs/files-v0.md §12.2)

    /// Where `+`, ⌥⌘N and ⇧⌘N put a new item: in the tree as VS Code does (in the one selected folder, beside the one
    /// selected file, else in the shown folder), in the folders as Finder does (the level shown).
    private func newItemFolder() -> String? {
        guard let root else { return nil }
        guard shown(classic: classic) == .tree, !columns(classic: classic), selection.count == 1, let path = selection.first, let e = entry(path) else { return root }
        return e.isFolder ? path : FilesPath.parent(of: path) ?? root
    }

    /// `New File…` / `New Folder…`: a row with a box for its name, where it will be (`inside` a folder's menu named).
    func startNew(folder: Bool, inside: String? = nil) {
        guard let root, let dir = inside ?? newItemFolder() else { return }
        if shown(classic: classic) == .tree, !columns(classic: classic) {
            if dir != root { expanded.insert(dir); refresh(innerOf(dir)); keepPlace() }
        } else if dir != root {
            go(to: dir)
        }
        said = nil
        question = nil
        edit = FilesEdit(kind: folder ? .newFolder(in: dir) : .newFile(in: dir), text: "")
    }

    /// `Rename…`, ↩: the name becomes a box. What holds AgentSwitch's places is not renamed here.
    func startRename(_ path: String) {
        guard let e = entry(path) else { return }
        guard e.changeable else { said = FilesWords.fixed; return }
        said = nil
        question = nil
        edit = FilesEdit(kind: .rename(path), text: e.name)
    }

    func cancelEdit() {
        edit = nil
        focusKeys()
    }

    /// The typed name as the column can judge it: a name read in the folder is taken (the service judges the rest,
    /// a disk that does not tell case apart among it).
    func check(_ edit: FilesEdit) -> FilesNameCheck.Result {
        if let refused = edit.refused { return FilesNameCheck.Result(error: refused) }
        switch edit.kind {
        case .rename(let path):
            let name = (path as NSString).lastPathComponent
            return FilesNameCheck.check(edit.text, renaming: name) { self.taken($0, in: FilesPath.parent(of: path) ?? "/") }
        case .newFile(let dir), .newFolder(let dir):
            return FilesNameCheck.check(edit.text) { self.taken($0, in: dir) }
        }
    }

    private func taken(_ relative: String, in dir: String) -> Bool {
        var folder = innerOf(dir)
        let parts = relative.split(separator: "/").map(String.init)
        for (i, part) in parts.enumerated() {
            guard let e = levels[folder]?.entries.first(where: { $0.name == part }) else { return false }
            if i == parts.count - 1 || !e.isFolder { return true }
            folder = e.kind == .link ? e.link?.target ?? FilesPath.join(folder, part) : FilesPath.join(folder, part)
        }
        return false
    }

    /// ↩ in the box, or the box left with a good name (VS Code): the change is asked for. False: the name will not do.
    @discardableResult
    func commitEdit() -> Bool {
        guard let edit else { return true }
        guard check(edit).ok else { return false }
        self.edit = nil
        focusKeys()
        let name = edit.text.trimmingCharacters(in: .whitespaces)
        if case .rename(let path) = edit.kind, name == (path as NSString).lastPathComponent { return true }
        Task { await self.apply(edit, name: name) }
        return true
    }

    private func apply(_ edit: FilesEdit, name: String, force: Bool = false) async {
        do {
            switch edit.kind {
            case .newFile(let dir), .newFolder(let dir):
                let path = FilesPath.join(dir, name.split(separator: "/").joined(separator: "/"))
                let made: FileMade
                if case .newFile = edit.kind { made = try await client().newFile(path: path) } else { made = try await client().newFolder(path: path) }
                // The tree shows the new one where it is, the folders the first new thing in the level shown.
                let shown = shown(classic: classic) == .tree && !columns(classic: classic) ? made.path : FilesPath.join(dir, String(name.split(separator: "/").first ?? Substring(name)))
                await reveal(shown, reading: dir)
                history.did(.made(top: made.top, shown: shown))
                let base = (made.path as NSString).lastPathComponent
                if base.hasPrefix("."), !showHidden { said = FilesWords.madeHidden(base) }
            case .rename(let path):
                let to = try await client().renameFile(path: path, name: name, force: force)
                moved(from: path, to: to)
                await reveal(to, reading: FilesPath.parent(of: to) ?? "/")
                history.did(.renamed(from: path, to: to))
            }
        } catch let refusal as FileChangeRefusal {
            if refusal.code == "in-use", case .rename(let path) = edit.kind {
                question = FilesQuestion(kind: .renameInUse(path: path, name: name), text: FilesWords.inUse(terminal: refusal.terminals.first?.name ?? "", renaming: true))
            } else if refusal.code == "exists" {
                // A name the disk takes for one already there (a case apart): the box again, saying so.
                self.edit = FilesEdit(kind: edit.kind, text: edit.text, refused: "此位置已有“\(name)”。请换一个名称。")
            } else {
                said = refusal.sentence(node: nodeName)
            }
        } catch {
            said = FilesRefusal(error).sentence(node: nodeName)
        }
    }

    /// `Move to Trash`, ⌘⌫: not asked (HIG Alerts: a delete that can be undone); asked only when a terminal runs in a
    /// folder, or the Trash will not take something.
    func trash(_ paths: [String]) {
        let paths = paths.filter { entry($0) != nil }
        guard !paths.isEmpty else { return }
        guard paths.allSatisfy({ entry($0)?.changeable ?? false }) else { said = FilesWords.fixed; return }
        question = nil
        Task { await self.trashNow(paths, force: false, permanent: false) }
    }

    private func trashNow(_ paths: [String], force: Bool, permanent: Bool) async {
        do {
            let moved = try await client().trashFiles(paths: paths, permanent: permanent, force: force)
            await gone(moved.map(\.path))
            if !permanent { history.did(.trashed(moved)) }
            said = permanent ? FilesWords.deleted(moved.map(\.path)) : FilesWords.trashed(moved.map(\.path))
        } catch let refusal as FileChangeRefusal {
            switch refusal.code {
            case "in-use":
                question = FilesQuestion(kind: .trashInUse(paths), text: FilesWords.inUse(terminal: refusal.terminals.first?.name ?? "", renaming: false))
            case "no-trash":
                if !refusal.moved.isEmpty { await gone(refusal.moved.map(\.path)); history.did(.trashed(refusal.moved)) }
                question = FilesQuestion(kind: .noTrash(refusal.paths), text: FilesWords.noTrash(refusal.paths))
            default:
                said = refusal.sentence(node: nodeName)
            }
        } catch {
            said = FilesRefusal(error).sentence(node: nodeName)
        }
    }

    /// The answer to the question: `Move to Trash` / `Rename` / `Delete Permanently`, or `Cancel`.
    func answer(_ yes: Bool) {
        guard let question else { return }
        self.question = nil
        focusKeys()
        guard yes else { return }
        switch question.kind {
        case .renameInUse(let path, let name): Task { await apply(FilesEdit(kind: .rename(path), text: name), name: name, force: true) }
        case .trashInUse(let paths): Task { await trashNow(paths, force: true, permanent: false) }
        case .noTrash(let paths): Task { await trashNow(paths, force: true, permanent: true) }
        }
    }

    /// ⌘Z: the last change taken back.
    func undo() {
        guard edit == nil, let step = history.takeUndo() else { return }
        Task {
            if let opposite = await self.reverse(step) { self.history.undone(opposite) }
        }
    }

    /// ⇧⌘Z: the last change taken back, done again.
    func redo() {
        guard edit == nil, let step = history.takeRedo() else { return }
        Task {
            if let opposite = await self.reverse(step) { self.history.redone(opposite) }
        }
    }

    /// One step's opposite done; the step that takes that back in turn, or nil when it could not be done.
    private func reverse(_ step: FilesStep) async -> FilesStep? {
        do {
            switch step {
            case .made(let top, _):
                let moved = try await client().trashFiles(paths: [top], force: true)
                await gone([top])
                said = FilesWords.undoneMade(top)
                return .trashed(moved)
            case .renamed(let from, let to):
                let name = (from as NSString).lastPathComponent
                let back = try await client().renameFile(path: to, name: name, force: true)
                moved(from: to, to: back)
                await reveal(back, reading: FilesPath.parent(of: back) ?? "/")
                said = FilesWords.renamedBack(name)
                return .renamed(from: to, to: back)
            case .trashed(let moved):
                var back: [FileMoved] = []
                var why: String?
                for m in moved {
                    guard let trashed = m.trashed else { why = FilesWords.lostInTrash(m.path); continue }
                    do { _ = try await client().restoreFile(trashed: trashed, path: m.path); back.append(m) }
                    catch let refusal as FileChangeRefusal where refusal.code == "exists" { why = FilesWords.notPutBack(m.path) }
                }
                for parent in Set(back.compactMap { FilesPath.parent(of: $0.path) }) { await load(parent) }
                if let first = back.first { await reveal(first.path, reading: FilesPath.parent(of: first.path) ?? "/") }
                selection = back.map(\.path).filter { entry($0) != nil }
                selected()
                said = why ?? FilesWords.putBack(back.map(\.path))
                return back.isEmpty ? nil : .restored(back)
            case .restored(let moved):
                let again = try await client().trashFiles(paths: moved.map(\.path), force: true)
                await gone(again.map(\.path))
                said = FilesWords.trashed(again.map(\.path))
                return .trashed(again)
            }
        } catch let refusal as FileChangeRefusal {
            said = refusal.sentence(node: nodeName)
        } catch {
            said = FilesRefusal(error).sentence(node: nodeName)
        }
        return nil
    }

    /// Paths gone from where they were: out of the selection and the open folders, their levels read again.
    private func gone(_ paths: [String]) async {
        selection.removeAll { p in paths.contains { FilesPath.contains($0, p) } }
        expanded = expanded.filter { p in !paths.contains { FilesPath.contains($0, p) } }
        for parent in Set(paths.compactMap { FilesPath.parent(of: $0) }) { await load(parent) }
        keepPlace()
        selected()
    }

    /// `from` is `to` now: what the column keeps of it follows.
    private func moved(from: String, to: String) {
        let follow = { (p: String) -> String in p == from ? to : FilesPath.contains(from, p) ? to + p.dropFirst(from.count) : p }
        expanded = Set(expanded.map(follow))
        selection = selection.map(follow)
        if let root, FilesPath.contains(from, root) { self.root = follow(root) }
        keepPlace()
    }

    /// Shown and selected (HIG Undo: show the result): the folders above it open in the tree, its level the shown one
    /// in the folders. `reading`: its folder, read again first.
    private func reveal(_ path: String, reading folder: String) async {
        guard let root, let parent = FilesPath.parent(of: path) else { return }
        await load(folder)
        if shown(classic: classic) == .tree, !columns(classic: classic), FilesPath.contains(root, parent) {
            var chain: [String] = []
            var q = parent
            while q != root, FilesPath.contains(root, q) { chain.append(q); guard let up = FilesPath.parent(of: q) else { break }; q = up }
            for f in chain.reversed() { expanded.insert(f); await load(innerOf(f)) }
            keepPlace()
        } else if parent != root {
            go(to: parent)
            await load(parent)
        }
        guard entry(path) != nil else { return }
        selection = [path]
        anchor = path
        selected()
    }

    // MARK: Quick Look

    /// What the Quick Look panel shows, in the order selected: this Mac's files as they are, another node's fetched.
    private(set) var lookItems: [URL] = []

    var quickLooking: Bool { QLPanelHost.isOpen(for: self) }

    func toggleQuickLook() {
        if quickLooking { return endQuickLook() }
        let files = selection.filter { !(entry($0)?.isFolder ?? true) }
        guard !files.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            var urls: [URL] = []
            for path in files { if self.local { urls.append(URL(fileURLWithPath: path)) } else if let url = await self.fetched(path) { urls.append(url) } }
            self.lookItems = urls
            QLPanelHost.open(for: self)
        }
    }

    private func refreshQuickLook() {
        guard quickLooking else { return }
        let files = selection.filter { !(entry($0)?.isFolder ?? true) }
        if local {
            lookItems = files.map { URL(fileURLWithPath: $0) }
            QLPanelHost.reload()
        }
    }

    func endQuickLook() { QLPanelHost.close(for: self) }

    func stop() {
        polling?.cancel()
        detailing?.cancel()
        endQuickLook()
        try? FileManager.default.removeItem(at: downloads)
    }

    #if DEBUG
    /// A design preview's column: levels as given, nothing asked of a service.
    func stage(root: String, levels: [FileLevel], expanded: Set<String> = [], selection: [String] = [], details: [FileDetails] = [], open: Bool = true, refused: FilesRefusal? = nil) {
        self.open = open
        self.root = root
        if let refused { refusals[root] = refused }
        for level in levels { self.levels[level.path] = level }
        self.expanded = expanded
        self.selection = selection
        self.home = levels.first?.home
        for d in details { self.details[d.path] = d }
    }

    func stageRemote(text: FileTextPreview?, image: NSImage?) { remoteText = text; remoteImage = image }

    /// The box the Mac asks with, as a refusal would put it up (a probe with no terminal running to refuse for).
    func stageQuestion(_ question: FilesQuestion) { self.question = question }
    #endif
}
