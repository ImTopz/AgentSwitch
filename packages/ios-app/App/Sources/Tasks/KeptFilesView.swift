import AgentSwitchKit
import SwiftUI

/// Where the Dispatch page's `Files` goes.
struct KeptFilesRoute: Hashable {}

/// Every task's kept files together (docs/dispatch-v0.md “任务的文件”, 2026-11-11, user: dispatch里加一个入口显示所有历史
/// 附件…集中查看和清理): how many there are and the room they take on the Mac, then each task's — what was asked, when,
/// its files as a task page lists them (a tap downloads one and opens the system preview) — with `Delete` for a task's
/// and `Delete All` for everyone's. The tasks stay.
struct KeptFilesView: View {
    let openTask: (String) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.interfaceLook) private var look
    @State private var kept: KeptFiles?
    @State private var problem: String?
    @State private var said: String?
    @State private var deleting: Removal?
    @State private var opener = TaskFileOpener()

    /// What is asked about before it goes: one task's files, or with no id everyone's.
    struct Removal: Equatable {
        let taskId: String?
        let message: String
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if let said { Text(said).font(.footnote).foregroundStyle(Theme.waiting) }
                if let kept {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kept.summary).mono(12).foregroundStyle(.secondary)
                        Text(KeptWords.kept(days: kept.keptDays)).font(.footnote).foregroundStyle(.secondary)
                    }
                    if kept.isEmpty { Text(KeptWords.none).font(.footnote).foregroundStyle(.secondary).padding(.top, 24) }
                    ForEach(kept.tasks) { task in section(task) }
                } else if let problem {
                    Text(problem).font(.footnote).foregroundStyle(.secondary).padding(.top, 40)
                } else {
                    BrailleSpinner(color: .secondary).frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
        }
        .background(Theme.base)
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if let kept { deleting = Removal(taskId: nil, message: KeptWords.deleteAll(count: kept.count)) }
                } label: {
                    Text("Delete All").font(look.isClassic ? .body : .system(size: 15, weight: .medium, design: .monospaced))
                }
                .tint(Theme.failed)
                .disabled(kept?.isEmpty ?? true)
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .taskFilePreview(opener)
        .pixelBox(item: $deleting) { pending in
            PixelBox(head: pending.taskId == nil ? "Delete All" : "Delete", tone: .red, message: pending.message,
                     actions: [.init(label: "Delete", role: .destructive) { Task { await remove(pending.taskId) } }])
        }
    }

    private func section(_ task: KeptFiles.TaskFiles) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { if task.known { openTask(task.id) } } label: {
                    Text(task.heading).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(1)
                }
                .buttonStyle(.plain)
                .disabled(!task.known)
                Spacer(minLength: 6)
                Text(Self.when(task.createdAt)).mono(11).foregroundStyle(.secondary)
                Button("Delete") { deleting = Removal(taskId: task.id, message: KeptWords.deleteTask(task.heading)) }
                    .mono(12).tint(Theme.failed)
            }
            TaskFilesSection(taskId: task.id, files: task.files, opener: opener, titled: false)
        }
    }

    private func load() async {
        // The sample screens have no Mac to ask.
        if let sample = model.demoKeptFiles { kept = sample; return }
        guard let api = model.api else { return }
        do {
            kept = try await api.keptFiles()
            problem = nil
        } catch APIError.http(status: 404, _) {
            problem = KeptWords.unsupported
        } catch {
            if kept == nil { problem = error.localizedDescription }
            model.handle(error)
        }
    }

    private func remove(_ taskId: String?) async {
        guard let api = model.api else { return }
        do {
            let removal = try await api.deleteKeptFiles(taskId: taskId)
            said = taskId == nil ? KeptWords.left(busy: removal.busy) : nil
        } catch {
            said = error.localizedDescription
            model.handle(error)
        }
        await load()
    }

    /// `11/09 14:32`, this year's; the year before it otherwise.
    static func when(_ ms: Double, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MM/dd HH:mm" : "yyyy/MM/dd HH:mm"
        return f.string(from: date)
    }
}
