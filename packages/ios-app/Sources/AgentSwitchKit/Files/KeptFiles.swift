import Foundation

/// Every task's files kept in the Mac's data folder (`GET /attachments`; docs/dispatch-v0.md “任务的文件”, 2026-11-11,
/// user: dispatch里加一个入口显示所有历史附件…集中查看和清理): what each task handed back and what was attached to it,
/// newest task first, with the room they take and how long they are kept.
public struct KeptFiles: Decodable, Sendable, Equatable {
    public struct TaskFiles: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        /// The first line of what was asked; empty for a task no longer in the list.
        public let title: String
        /// Milliseconds since 1970.
        public let createdAt: Double
        public let known: Bool
        public let files: [TaskFile]

        public init(id: String, title: String, createdAt: Double, known: Bool = true, files: [TaskFile]) {
            self.id = id
            self.title = title
            self.createdAt = createdAt
            self.known = known
            self.files = files
        }

        private enum CodingKeys: String, CodingKey { case id, title, createdAt, known, files }
        private struct Entry: Decodable { let path: String; let size: Int64? }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
            createdAt = (try? c.decodeIfPresent(Double.self, forKey: .createdAt)) ?? 0
            known = (try? c.decodeIfPresent(Bool.self, forKey: .known)) ?? false
            // `in/` is what the user attached; anything else was handed back. Those first, then by path.
            files = ((try? c.decodeIfPresent([Entry].self, forKey: .files)) ?? [])
                .map { TaskFile(path: $0.path, size: $0.size ?? 0, isDeliverable: !$0.path.hasPrefix("in/")) }
                .sorted { ($0.isDeliverable ? 0 : 1, $0.path) < ($1.isDeliverable ? 0 : 1, $1.path) }
        }

        public var heading: String { title.isEmpty ? "Task \(id)" : title }
        public var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
    }

    public let tasks: [TaskFiles]
    public let bytes: Int64
    public let keptDays: Int

    public init(tasks: [TaskFiles], bytes: Int64? = nil, keptDays: Int = 7) {
        self.tasks = tasks
        self.bytes = bytes ?? tasks.reduce(0) { $0 + $1.bytes }
        self.keptDays = keptDays
    }

    private enum CodingKeys: String, CodingKey { case tasks, bytes, keptDays }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tasks = (try? c.decodeIfPresent([TaskFiles].self, forKey: .tasks)) ?? []
        self.init(tasks: tasks, bytes: try? c.decodeIfPresent(Int64.self, forKey: .bytes),
                  keptDays: Int(((try? c.decodeIfPresent(Double.self, forKey: .keptDays)) ?? 7).rounded()))
    }

    public var count: Int { tasks.reduce(0) { $0 + $1.files.count } }
    public var isEmpty: Bool { count == 0 }

    /// `12 Files · 3.4 MB`.
    public var summary: String {
        "\(count) \(count == 1 ? "File" : "Files") · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }
}

/// `DELETE /attachments[/:id]` → `{removed, busy}`.
public struct KeptRemoval: Decodable, Sendable, Equatable {
    public let removed: Int
    public let busy: Int
}

/// The page's sentences (the Mac's DispatchKeptWords).
public enum KeptWords {
    public static let none = "还没有文件。任务交回的文件和你发送的附件会列在这里。"
    public static func kept(days: Int) -> String { "文件保存在 Mac 上 AgentSwitch 的数据文件夹中，\(days) 天后自动清理。删除文件不会删除任务。" }
    public static func deleteAll(count: Int) -> String { "删除全部 \(count) 个文件？所有任务交回的文件和附件都将从 Mac 上删除，无法恢复。任务本身保留，进行中的任务的文件不会删除。" }
    public static func deleteTask(_ heading: String) -> String { "删除「\(heading)」的文件？这个任务交回的文件和附件都将从 Mac 上删除，无法恢复。任务本身保留。" }
    public static func left(busy: Int) -> String? { busy > 0 ? "\(busy) 个进行中的任务的文件未删除。" : nil }
    public static let unsupported = "此 Mac 上的 AgentSwitch 版本较旧，不支持集中查看文件。"
}

extension AgentSwitchAPI {
    /// Every task's kept files together.
    public func keptFiles() async throws -> KeptFiles { try await get(["attachments"]) }

    /// One task's kept files (409 while it is at work), or with nil everyone's.
    @discardableResult
    public func deleteKeptFiles(taskId: String?) async throws -> KeptRemoval {
        try await perform("DELETE", ["attachments"] + (taskId.map { [$0] } ?? []), query: [], body: nil)
    }
}
