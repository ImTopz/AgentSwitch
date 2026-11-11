import XCTest
@testable import AgentSwitchMacCore

final class DispatchKeptFilesTests: XCTestCase {
    // 2026-11-11, user: dispatch里加一个入口显示所有历史附件…集中查看和清理.
    func testTheListAsTheServiceGivesIt() throws {
        let json = #"{"tasks":[{"id":"t2","title":"导出报表","createdAt":1762828800000,"known":true,"files":[{"path":"in/a.csv","size":10,"mtime":1},{"path":"out/report.xlsx","size":2048,"mtime":2}]},{"id":"t1","title":"","createdAt":1,"known":false,"files":[{"path":"old.zip","size":5}]}],"bytes":2063,"keptDays":7}"#
        let kept = try JSONDecoder().decode(DispatchKeptFiles.self, from: Data(json.utf8))
        XCTAssertEqual(kept.count, 3)
        XCTAssertEqual(kept.keptDays, 7)
        XCTAssertEqual(kept.summary, "3 Files · \(ByteCountFormatter.string(fromByteCount: 2063, countStyle: .file))")
        // What was handed back first, what was attached after it.
        XCTAssertEqual(kept.tasks[0].files.map(\.path), ["out/report.xlsx", "in/a.csv"])
        XCTAssertEqual(kept.tasks[0].files.map(\.isDeliverable), [true, false])
        XCTAssertEqual(kept.tasks[0].files[0].modified, 2)
        // A task no longer in the list: its id; a kept copy from before has no `out/` in front and is handed back.
        XCTAssertEqual(kept.tasks[1].heading, "Task t1")
        XCTAssertFalse(kept.tasks[1].known)
        XCTAssertTrue(kept.tasks[1].files[0].isDeliverable)
        XCTAssertTrue(try JSONDecoder().decode(DispatchKeptFiles.self, from: Data("{}".utf8)).isEmpty)
        XCTAssertEqual(DispatchKeptFiles(tasks: [.init(id: "a", title: "x", createdAt: 0, files: [DispatchTaskFile(path: "out/a", size: 1, isDeliverable: true)])]).summary.hasPrefix("1 File ·"), true)
    }

    func testWhatARemovalLeft() throws {
        XCTAssertNil(DispatchKeptWords.left(busy: 0))
        XCTAssertEqual(DispatchKeptWords.left(busy: 2), "2 个进行中的任务的文件未删除。")
        XCTAssertEqual(try JSONDecoder().decode(DispatchKeptRemoval.self, from: Data(#"{"removed":3,"busy":1}"#.utf8)), DispatchKeptRemoval(removed: 3, busy: 1))
    }

    // A click saves into Downloads; a name taken there gets a number, and nothing is replaced.
    func testADownloadTakesAFreeName() {
        let folder = URL(fileURLWithPath: "/d")
        XCTAssertEqual(FilesDownloads.free(in: folder, name: "report.xlsx", taken: { _ in false }).lastPathComponent, "report.xlsx")
        XCTAssertEqual(FilesDownloads.free(in: folder, name: "report.xlsx", taken: { ["report.xlsx", "report 2.xlsx"].contains($0.lastPathComponent) }).lastPathComponent, "report 3.xlsx")
    }
}
