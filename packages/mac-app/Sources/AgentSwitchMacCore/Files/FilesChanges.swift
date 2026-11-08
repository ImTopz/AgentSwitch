import Foundation

// The Files column's changes (docs/files-v0.md §12.2; daemon src/api/fileChanges.ts): a new folder or file named in
// place, a new name, the Trash and back out of it, and ⌘Z / ⇧⌘Z over them. The service holds the rules (what is never
// moved, a folder a terminal runs in, a paired device's switch and scope) and says them; the column words them.

/// `POST /files/folder` and `/files/file`: where the new one is, and the first folder made on the way (what an undo
/// takes away: `a/b/c.ts` made `a`).
public struct FileMade: Decodable, Equatable, Sendable {
    public let path: String
    public let top: String
    public init(path: String, top: String) { self.path = path; self.top = top }
}

/// One item `POST /files/trash` moved: where it was, and where in the Trash it went (nil: deleted outright, or the
/// service could not tell; such a one cannot be put back from here).
public struct FileMoved: Codable, Equatable, Sendable {
    public let path: String
    public let trashed: String?
    public init(path: String, trashed: String?) { self.path = path; self.trashed = trashed }
}

/// The service's refusal of a change, with what it says beside the code: the terminals running in a folder
/// (`in-use`), what the Trash would not take and what it took before that (`no-trash`).
public struct FileChangeRefusal: Error, Equatable, Sendable {
    public struct Terminal: Decodable, Equatable, Sendable {
        public let id: String
        public let name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    public let status: Int
    public let code: String
    public var terminals: [Terminal] = []
    /// `no-trash`: the paths left where they are.
    public var paths: [String] = []
    /// `no-trash`: what went to the Trash before it.
    public var moved: [FileMoved] = []

    public init(status: Int, code: String, terminals: [Terminal] = [], paths: [String] = [], moved: [FileMoved] = []) {
        self.status = status
        self.code = code
        self.terminals = terminals
        self.paths = paths
        self.moved = moved
    }

    /// From the answer's body: `{error, terminals?, paths?, moved?}`; a body that is not one, its text as the code.
    public init(status: Int, body: Data) {
        struct Body: Decodable {
            let error: String?
            let terminals: [Terminal]?
            let paths: [String]?
            let moved: [FileMoved]?
        }
        let b = try? JSONDecoder().decode(Body.self, from: body)
        self.init(status: status, code: b?.error ?? DaemonClient.errorMessage(body), terminals: b?.terminals ?? [], paths: b?.paths ?? [], moved: b?.moved ?? [])
    }

    /// The sentence the column shows for a refusal no question follows (`node`: whose files these are).
    public func sentence(node: String = "这台 Mac") -> String {
        switch code {
        case "exists": "此位置已有同名的项目。请换一个名称。"
        case "locked": FilesWords.fixed
        case "bad-name": "名称不能为空、不能是“.”或“..”，也不能包含“/”。"
        case "changes-off": "\(node) 不允许配对的设备修改文件。可在 \(node) 的“设置 › Nodes”中打开。"
        case "not-trash": "此项已不在废纸篓中。"
        default: FilesRefusal(code: code).sentence(node: node)
        }
    }
}

extension DaemonClient {
    /// `POST /files/folder {path}`: a new folder (and the folders on the way).
    public func newFolder(path: String) async throws -> FileMade {
        try decode(FileMade.self, try await change("/files/folder", ["path": path]))
    }

    /// `POST /files/file {path}`: a new empty file (and the folders on the way).
    public func newFile(path: String) async throws -> FileMade {
        try decode(FileMade.self, try await change("/files/file", ["path": path]))
    }

    /// `POST /files/rename {path, name, force}`: another name in the same folder; `force` once asked about a folder a
    /// terminal runs in. The new path.
    public func renameFile(path: String, name: String, force: Bool = false) async throws -> String {
        struct Answer: Decodable { let path: String }
        return try decode(Answer.self, try await change("/files/rename", ["path": path, "name": name, "force": force])).path
    }

    /// `POST /files/trash {paths, permanent, force}`: to the Trash (deleted outright only with `permanent`, after the
    /// Trash would not take them).
    public func trashFiles(paths: [String], permanent: Bool = false, force: Bool = false) async throws -> [FileMoved] {
        struct Answer: Decodable { let moved: [FileMoved] }
        return try decode(Answer.self, try await change("/files/trash", ["paths": paths, "permanent": permanent, "force": force])).moved
    }

    /// `POST /files/restore {trashed, path}`: back out of the Trash where it was (⌘Z).
    public func restoreFile(trashed: String, path: String) async throws -> String {
        struct Answer: Decodable { let path: String }
        return try decode(Answer.self, try await change("/files/restore", ["trashed": trashed, "path": path])).path
    }

    /// One change: JSON in; a refusal thrown as `FileChangeRefusal`, with all the service said.
    private func change(_ path: String, _ body: [String: Any]) async throws -> Data {
        var request = request("POST", path)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90
        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try await transport.send(request) } catch let error as DaemonError { throw error } catch {
            throw DaemonError.unreachable(error.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 404, DaemonClient.jsonError(data) == nil { throw DaemonError.notSupported("POST \(path)") }
            throw FileChangeRefusal(status: response.statusCode, body: data)
        }
        return data
    }
}

/// A name typed in place, checked as it is typed (docs/files-v0.md §12.2; VS Code's explorer): an error stops ↩, a
/// warning does not.
public enum FilesNameCheck {
    public struct Result: Equatable, Sendable {
        public let error: String?
        public let warning: String?
        public init(error: String? = nil, warning: String? = nil) { self.error = error; self.warning = warning }
        public var ok: Bool { error == nil }
        /// The line under the box: the error, else the warning, else nothing.
        public var line: String? { error ?? warning }
    }

    /// `text` for a new item in a folder (`renaming` nil) or as `renaming`'s new name. `taken`: whether a name (or a
    /// path under the folder, `a/b`) is there already, as far as the column has read; a disk that does not tell case
    /// apart is the service's to answer.
    public static func check(_ text: String, renaming: String? = nil, taken: (String) -> Bool) -> Result {
        let name = text.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return Result(error: "请输入名称。") }
        if renaming != nil, name.contains("/") { return Result(error: "名称不能包含“/”。") }
        let parts = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.isEmpty || parts.contains(where: { $0 == "." || $0 == ".." }) { return Result(error: "名称不能是“.”或“..”。") }
        let joined = parts.joined(separator: "/")
        if joined != renaming, taken(joined) { return Result(error: "此位置已有“\(joined)”。请换一个名称。") }
        if text != text.trimmingCharacters(in: .whitespaces) { return Result(warning: "名称前后有空格。") }
        return Result()
    }

    /// What a rename selects first, as Finder does: a file's name before its extension, a folder's whole name.
    public static func selected(_ name: String, folder: Bool) -> NSRange {
        let whole = NSRange(location: 0, length: (name as NSString).length)
        guard !folder else { return whole }
        let dot = (name as NSString).range(of: ".", options: .backwards)
        return dot.location != NSNotFound && dot.location > 0 ? NSRange(location: 0, length: dot.location) : whole
    }
}

/// One change, as ⌘Z and ⇧⌘Z know it (docs/files-v0.md §12.2). Each is undone by doing its opposite, and that opposite
/// is itself a step: what undoing it does is the first done again. So the two stacks hold steps alike.
public enum FilesStep: Equatable, Sendable {
    /// Something new: `top` is what taking it back moves to the Trash; `shown` what was selected.
    case made(top: String, shown: String)
    /// `to` was `from`; taken back, renamed again the other way.
    case renamed(from: String, to: String)
    /// To the Trash: where each was and where it went; taken back, put back out of it.
    case trashed([FileMoved])
    /// Put back out of the Trash; taken back, to the Trash again.
    case restored([FileMoved])
}

/// The column's ⌘Z and ⇧⌘Z: many steps, this column's alone, gone when the app quits.
public struct FilesHistory: Equatable, Sendable {
    public private(set) var undo: [FilesStep] = []
    public private(set) var redo: [FilesStep] = []
    public init() {}

    /// A step done afresh: what was undone before it cannot be done again.
    public mutating func did(_ step: FilesStep) { undo.append(step); redo = [] }
    public mutating func takeUndo() -> FilesStep? { undo.popLast() }
    /// A step taken back: `opposite` (what was done to take it back) is what ⇧⌘Z undoes in turn.
    public mutating func undone(_ opposite: FilesStep) { redo.append(opposite) }
    public mutating func takeRedo() -> FilesStep? { redo.popLast() }
    /// Done again: `opposite` is what ⌘Z takes back next.
    public mutating func redone(_ opposite: FilesStep) { undo.append(opposite) }
}

/// The column's sentences for what was done (ui-v0 §7: whole sentences in formal Chinese).
public enum FilesWords {
    public static let fixed = "此文件夹中有 AgentSwitch 的凭据，不能在这里改名或移到废纸篓。"

    /// `“logo.png”`, or ` 3 项` for several (a space before a number in a Chinese sentence).
    public static func named(_ paths: [String]) -> String {
        paths.count == 1 ? "“\((paths[0] as NSString).lastPathComponent)”" : " \(paths.count) 项"
    }

    public static func trashed(_ paths: [String]) -> String { "已将\(named(paths))移到废纸篓。⌘Z 可放回。" }
    public static func deleted(_ paths: [String]) -> String { "已永久删除\(named(paths))。" }
    public static func putBack(_ paths: [String]) -> String { "已放回\(named(paths))。" }
    public static func renamedBack(_ name: String) -> String { "已改回“\(name)”。" }
    public static func undoneMade(_ path: String) -> String { "已将“\((path as NSString).lastPathComponent)”移到废纸篓。" }
    public static func notPutBack(_ path: String) -> String { "原位置已有“\((path as NSString).lastPathComponent)”，未放回。可在废纸篓中手动放回。" }
    public static func lostInTrash(_ path: String) -> String { "找不到“\((path as NSString).lastPathComponent)”在废纸篓中的位置，未放回。可在废纸篓中手动放回。" }
    public static func madeHidden(_ name: String) -> String { "已创建“\(name)”。它是隐藏文件，可在 ⋯ › Show Hidden Files 中显示。" }

    // `Download` (docs/files-v0.md §13): while another node's files come, once they are in Downloads, and why not.
    public static func downloading(_ paths: [String]) -> String { "正在下载\(named(paths))…" }
    public static func downloaded(_ paths: [String]) -> String { "已下载\(named(paths))到“下载”。" }
    public static func notDownloaded(node: String) -> String { "文件超过 \(node) 给配对设备的上限，未下载。" }

    /// The question before a folder a terminal runs in is renamed or moved.
    public static func inUse(terminal: String, renaming: Bool) -> String {
        "终端“\(terminal)”正在此文件夹中运行。\(renaming ? "改名后" : "移到废纸篓后")，其中的 agent 仍会使用原来的路径，可能出错。"
    }

    /// The question when the Trash would not take something.
    public static func noTrash(_ paths: [String]) -> String {
        "无法将\(named(paths))移到废纸篓。要永久删除吗？此操作无法撤销。"
    }
}

extension FilesTree {
    /// Where a new item's row goes in the tree while its name is typed (files-v0 §12.2): first under `folder` (at the
    /// top when it is `root`), one step deeper, drawn with the stems the folder's own children would have.
    public struct Slot: Equatable, Sendable {
        public let index: Int
        public let depth: Int
        public let stems: [Bool]
        /// Nothing else in that folder: `└─`.
        public let last: Bool
        public var twig: String { stems.map { $0 ? "   " : "│  " }.joined() + (last ? "└─" : "├─") }
    }

    public static func slot(for folder: String, root: String, rows: [FilesTreeRow]) -> Slot? {
        if folder == root { return Slot(index: 0, depth: 0, stems: [], last: !rows.contains { $0.depth == 0 }) }
        guard let i = rows.firstIndex(where: { $0.path == folder && $0.open }) else { return nil }
        let row = rows[i]
        let hasChildren = rows.indices.contains(i + 1) && rows[i + 1].depth > row.depth
        return Slot(index: i + 1, depth: row.depth + 1, stems: row.stems + [row.last], last: !hasChildren)
    }
}
