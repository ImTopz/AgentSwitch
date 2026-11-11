import XCTest
@testable import AgentSwitchKit

final class KeptFilesTests: XCTestCase {
    func testTheListAsTheMacGivesIt() throws {
        let json = #"{"tasks":[{"id":"t2","title":"导出报表","createdAt":1762828800000,"known":true,"files":[{"path":"in/a.csv","size":10,"mtime":1},{"path":"out/report.xlsx","size":2048,"mtime":2}]},{"id":"t1","title":"","createdAt":1,"known":false,"files":[{"path":"old.zip","size":5}]}],"bytes":2063,"keptDays":7}"#
        let kept = try JSONDecoder().decode(KeptFiles.self, from: Data(json.utf8))
        XCTAssertEqual(kept.count, 3)
        XCTAssertEqual(kept.keptDays, 7)
        XCTAssertEqual(kept.summary, "3 Files · \(ByteCountFormatter.string(fromByteCount: 2063, countStyle: .file))")
        // What was handed back first, what was attached after it.
        XCTAssertEqual(kept.tasks[0].files.map(\.path), ["out/report.xlsx", "in/a.csv"])
        XCTAssertEqual(kept.tasks[0].files.map(\.isDeliverable), [true, false])
        XCTAssertEqual(kept.tasks[0].heading, "导出报表")
        // A task no longer in the list: its id; a kept copy from before has no `out/` in front and is handed back.
        XCTAssertEqual(kept.tasks[1].heading, "Task t1")
        XCTAssertFalse(kept.tasks[1].known)
        XCTAssertTrue(kept.tasks[1].files[0].isDeliverable)
        XCTAssertTrue(try JSONDecoder().decode(KeptFiles.self, from: Data("{}".utf8)).isEmpty)
    }

    func testWhatARemovalLeft() {
        XCTAssertNil(KeptWords.left(busy: 0))
        XCTAssertEqual(KeptWords.left(busy: 2), "2 个进行中的任务的文件未删除。")
    }
}
