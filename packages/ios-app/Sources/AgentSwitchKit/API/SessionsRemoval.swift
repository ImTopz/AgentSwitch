import Foundation

// Several sessions deleted at once (docs/terminal-v0.md §5 批量删除; the Mac's SessionsRemoval.swift, in this package:
// packages share nothing): what the Mac said of each, and the tab's words about it.

/// `POST /sessions/delete`'s answer: each session's outcome — `deleted`, `busy` (in use: left), `gone` (not there any
/// more), `failed`.
public struct SessionsRemoval: Decodable, Equatable, Sendable {
    public enum Outcome: String, Sendable { case deleted, busy, gone, failed }

    public struct One: Decodable, Equatable, Sendable {
        public let harness: String
        public let id: String
        public let outcome: String
        public let error: String?

        public init(harness: String, id: String, outcome: Outcome, error: String? = nil) {
            self.harness = harness
            self.id = id
            self.outcome = outcome.rawValue
            self.error = error
        }
    }

    public let results: [One]

    public init(results: [One]) { self.results = results }

    private enum CodingKeys: String, CodingKey { case results }

    public func count(_ outcome: Outcome) -> Int { results.filter { $0.outcome == outcome.rawValue }.count }
    /// The sessions still on the Mac — in use, or not deleted for another reason — as `SessionSummary.id` names them.
    public var kept: Set<String> { Set(results.filter { $0.outcome == Outcome.busy.rawValue || $0.outcome == Outcome.failed.rawValue }.map { "\($0.harness)/\($0.id)" }) }

    /// What one `DELETE /sessions/:harness/:id` came to, for a Mac whose service has no batch route yet.
    public static func outcome(of error: Error?) -> Outcome {
        guard let error else { return .deleted }
        if case .http(let status, _) = error as? APIError { return status == 409 ? .busy : status == 404 ? .gone : .failed }
        return .failed
    }
}

public enum SessionDeleteWords {
    public static func all(_ count: Int) -> String { count == 1 ? "Delete Session…" : "Delete All \(count) Sessions…" }

    /// The first few by name, then how many in all: what is about to go is read before it goes.
    public static func question(titles: [String], named: Int = 3) -> String {
        let names = titles.prefix(named).map { "「\($0)」" }.joined(separator: "、")
        let which = titles.count > named ? "\(names)等 \(titles.count) 个会话" : names
        return "删除\(which)的记录？Mac 上这些会话的记录将被删除，无法恢复，也无法再继续。正在使用的会话不会删除。"
    }

    /// What was left and why, after the rest went; nil when all of them went.
    public static func left(_ removal: SessionsRemoval) -> String? {
        var parts: [String] = []
        let busy = removal.count(.busy), failed = removal.count(.failed)
        if busy > 0 { parts.append("\(busy) 个正在使用，未删除") }
        if failed > 0 { parts.append("\(failed) 个未能删除") }
        guard !parts.isEmpty else { return nil }
        let deleted = removal.count(.deleted)
        return ((deleted > 0 ? ["已删除 \(deleted) 个会话"] : []) + parts).joined(separator: "；") + "。"
    }
}
