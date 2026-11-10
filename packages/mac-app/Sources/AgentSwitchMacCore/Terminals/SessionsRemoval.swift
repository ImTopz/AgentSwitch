import Foundation

// Several sessions deleted at once (docs/terminal-v0.md §5 批量删除): what the service said of each, which rows a
// click picks, and the page's words about it.

/// `POST /sessions/delete`'s answer: each session's outcome — `deleted`, `busy` (in use: left), `gone` (not there any
/// more), `failed` — and how many of each.
public struct SessionsRemoval: Decodable, Equatable, Sendable {
    public struct One: Decodable, Equatable, Sendable {
        public let harness: String
        public let id: String
        public let outcome: String
        public let error: String?

        public init(harness: String, id: String, outcome: String, error: String? = nil) {
            self.harness = harness
            self.id = id
            self.outcome = outcome
            self.error = error
        }
    }

    public let results: [One]
    public let deleted: Int
    public let busy: Int
    public let gone: Int
    public let failed: Int

    public init(results: [One]) {
        self.results = results
        func count(_ outcome: String) -> Int { results.filter { $0.outcome == outcome }.count }
        deleted = count("deleted")
        busy = count("busy")
        gone = count("gone")
        failed = count("failed")
    }

    /// What one `DELETE /sessions/:harness/:id` came to, for a node whose service has no batch route yet.
    public static func outcome(of error: Error?) -> One.Outcome {
        guard let error else { return .deleted }
        if case .http(let status, _) = error as? DaemonError, status == 409 { return .busy }
        if case .http(let status, _) = error as? DaemonError, status == 404 { return .gone }
        if case .notSupported = error as? DaemonError { return .gone }
        return .failed
    }
}

public extension SessionsRemoval.One {
    enum Outcome: String, Sendable { case deleted, busy, gone, failed }
}

/// The rows picked while the list is being selected in: a click takes a row in or out, with ⇧ every row from the one
/// clicked before to this one comes in.
public enum SessionPick {
    public static func clicked(_ id: String, picked: Set<String>, anchor: String?, order: [String], range: Bool) -> Set<String> {
        if range, let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
            return picked.union(order[min(from, to)...max(from, to)])
        }
        return picked.symmetricDifference([id])
    }
}

public enum SessionDeleteWords {
    /// A menu's or the foot's word: `Delete 3 Sessions…`.
    public static func delete(_ count: Int) -> String { count == 1 ? "Delete Session…" : "Delete \(count) Sessions…" }
    public static func selected(_ count: Int) -> String { "\(count) Selected" }

    public static func title(_ count: Int) -> String { "删除 \(count) 个会话？" }

    /// The first few by name, then how many in all: what is about to go is read before it goes.
    public static func body(titles: [String], named: Int = 3) -> String {
        let names = titles.prefix(named).map { "「\(TerminalListText.brief($0.isEmpty ? "无标题" : $0, columns: 28))」" }.joined(separator: "、")
        let which = titles.count > named ? "\(names)等 \(titles.count) 个会话" : names
        return "将删除\(which)的记录，此操作无法撤销。正在使用的会话不会删除。"
    }

    /// The line after: how many went, and what was left and why. Nil when there is nothing to say.
    public static func said(_ removal: SessionsRemoval) -> String? {
        var parts: [String] = []
        if removal.deleted > 0 { parts.append("已删除 \(removal.deleted) 个会话") }
        if removal.busy > 0 { parts.append("\(removal.busy) 个正在使用，未删除") }
        if removal.failed > 0 { parts.append("\(removal.failed) 个未能删除") }
        return parts.isEmpty ? nil : parts.joined(separator: "；") + "。"
    }
}
