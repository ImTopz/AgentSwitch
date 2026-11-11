import AgentSwitchMacCore
import SwiftUI

/// Every task's kept files together, pushed in the record's column from `[ Files ]` (docs/dispatch-v0.md “任务的文件”,
/// 2026-11-11, user: dispatch里加一个入口显示所有历史附件…集中查看和清理): how many there are and the room they take,
/// then each task's — what was asked, when, its files as the cards draw them (a click saves one to Downloads and opens
/// it) — with `[ Delete ]` for a task's and `[ Delete All ]` for everyone's. The tasks stay. Read again every poll
/// while shown.
struct KeptFilesPage: View {
    let model: DispatchModel
    let open: (DispatchRoute) -> Void
    let visible: Bool
    @Environment(MainWindowState.self) private var window
    @State private var deleting: Removal?

    /// What is asked about before it goes: one task's files, or everyone's.
    private struct Removal: Identifiable {
        let taskId: String?
        let question: String
        let detail: String
        var id: String { taskId ?? "*" }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let banner = model.banner { BannerLine(text: banner) { model.banner = nil } }
                if let kept = model.kept {
                    header(kept)
                    if kept.isEmpty {
                        Text(DispatchKeptWords.none).font(.system(size: 13)).foregroundStyle(Look.ink2).padding(.top, 24)
                    }
                    ForEach(kept.tasks) { task in section(task) }
                } else if let problem = model.keptError {
                    Text(problem).font(.system(size: 13)).foregroundStyle(Look.ink2).padding(.top, 40)
                } else {
                    BrailleSpinner().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(.top, 18)
            .padding(.bottom, 28)
            .dispatchColumn()
        }
        .onAppear { window.dispatchTitle = BarTitle("Files") }
        .task(id: visible) {
            guard visible else { return }
            await model.refreshKept()
            while visible && !Task.isCancelled {
                try? await Task.sleep(for: DispatchDefaults.pollInterval)
                guard !Task.isCancelled else { break }
                await model.refreshKept()
            }
        }
        .confirmationDialog(deleting?.question ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { pending in
            Button(pending.taskId == nil ? "Delete All" : "Delete", role: .destructive) { Task { await model.deleteKept(taskId: pending.taskId) } }
        } message: { pending in
            Text(pending.detail)
        }
    }

    private func header(_ kept: DispatchKeptFiles) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Files").font(.system(size: 20, weight: .semibold)).foregroundStyle(Look.ink)
            Text(kept.summary).mono(11.5).foregroundStyle(Look.ink2)
            Text(DispatchKeptWords.kept(days: kept.keptDays)).font(.system(size: 12)).foregroundStyle(Look.ink2)
            if !kept.isEmpty {
                Button {
                    deleting = Removal(taskId: nil, question: DispatchKeptWords.deleteAll(count: kept.count), detail: DispatchKeptWords.deleteAllBody)
                } label: { BracketLabel(word: "Delete All") }
                    .buttonStyle(BracketButtonStyle(role: .destructive))
                    .padding(.top, 4)
            }
            HairRule(color: Look.line).padding(.top, 8)
        }
    }

    private func section(_ task: DispatchKeptFiles.TaskFiles) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // The task itself, while it is still there to open.
                Button { if task.known { open(.task(task.id)) } } label: {
                    Text(task.heading).font(.system(size: 13, weight: .medium)).foregroundStyle(Look.ink).lineLimit(1).truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .disabled(!task.known)
                .help(task.known ? "Open Task" : "")
                Spacer(minLength: 8)
                Text(Self.when(task.createdAt)).mono(11).foregroundStyle(Look.faint)
                Button {
                    deleting = Removal(taskId: task.id, question: DispatchKeptWords.deleteTask(task.heading), detail: DispatchKeptWords.deleteTaskBody)
                } label: { BracketLabel(word: "Delete") }
                    .buttonStyle(BracketButtonStyle(role: .destructive, size: 11.5))
            }
            FlowLayout(spacing: 14, lineSpacing: 6) {
                ForEach(task.files) { file in
                    FileChip(file: file, taskId: task.id, model: model).opacity(file.isDeliverable ? 1 : 0.7)
                }
            }
        }
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
