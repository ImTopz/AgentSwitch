import XCTest
@testable import AgentSwitchKit

/// Several sessions deleted at once (docs/terminal-v0.md §5 批量删除).
final class SessionsRemovalTests: XCTestCase {
    func testTheMacsAnswer() throws {
        let json = #"{"results":[{"harness":"claude-code","id":"c1","outcome":"deleted"},{"harness":"codex","id":"x1","outcome":"busy","error":"会话正在终端中打开，请先关闭终端。"},{"harness":"pi","id":"p1","outcome":"failed"},{"harness":"codex","id":"x2","outcome":"gone"}],"deleted":1,"busy":1,"gone":1,"failed":1}"#
        let removal = try JSONDecoder().decode(SessionsRemoval.self, from: Data(json.utf8))
        XCTAssertEqual(removal.count(.deleted), 1)
        XCTAssertEqual(removal.count(.busy), 1)
        // What stays on the Mac comes back to the list, named as the list names a session.
        XCTAssertEqual(removal.kept, ["codex/x1", "pi/p1"])
        XCTAssertEqual(SessionDeleteWords.left(removal), "已删除 1 个会话；1 个正在使用，未删除；1 个未能删除。")
    }

    func testOneByOneForAMacWithoutTheRoute() {
        XCTAssertEqual(SessionsRemoval.outcome(of: nil), .deleted)
        XCTAssertEqual(SessionsRemoval.outcome(of: APIError.http(status: 409, message: "会话正在使用中")), .busy)
        XCTAssertEqual(SessionsRemoval.outcome(of: APIError.http(status: 404, message: "no such session")), .gone)
        XCTAssertEqual(SessionsRemoval.outcome(of: APIError.http(status: 500, message: "")), .failed)
        XCTAssertEqual(SessionsRemoval.outcome(of: APIError.unreachable), .failed)
    }

    func testTheWords() {
        XCTAssertEqual(SessionDeleteWords.all(4), "Delete All 4 Sessions…")
        XCTAssertEqual(SessionDeleteWords.question(titles: ["a", "b"]), "删除「a」、「b」的记录？Mac 上这些会话的记录将被删除，无法恢复，也无法再继续。正在使用的会话不会删除。")
        XCTAssertEqual(SessionDeleteWords.question(titles: ["a", "b", "c", "d"]), "删除「a」、「b」、「c」等 4 个会话的记录？Mac 上这些会话的记录将被删除，无法恢复，也无法再继续。正在使用的会话不会删除。")
        XCTAssertNil(SessionDeleteWords.left(SessionsRemoval(results: [.init(harness: "codex", id: "x", outcome: .deleted), .init(harness: "codex", id: "y", outcome: .gone)])))
        XCTAssertEqual(SessionDeleteWords.left(SessionsRemoval(results: [.init(harness: "codex", id: "x", outcome: .busy)])), "1 个正在使用，未删除。")
    }
}
