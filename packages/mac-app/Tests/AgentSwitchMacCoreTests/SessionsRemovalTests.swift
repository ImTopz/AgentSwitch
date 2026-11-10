import XCTest
@testable import AgentSwitchMacCore

/// Several sessions deleted at once (docs/terminal-v0.md §5 批量删除).
final class SessionsRemovalTests: XCTestCase {
    func testTheServicesAnswer() throws {
        let json = #"{"results":[{"harness":"claude-code","id":"c1","outcome":"deleted"},{"harness":"codex","id":"x1","outcome":"busy","error":"会话正在终端中打开，请先关闭终端。"}],"deleted":1,"busy":1,"gone":0,"failed":0}"#
        let removal = try JSONDecoder().decode(SessionsRemoval.self, from: Data(json.utf8))
        XCTAssertEqual(removal.deleted, 1)
        XCTAssertEqual(removal.busy, 1)
        XCTAssertEqual(removal.results[1].error, "会话正在终端中打开，请先关闭终端。")
        XCTAssertEqual(removal, SessionsRemoval(results: removal.results))
    }

    func testOneByOneForANodeWithoutTheRoute() {
        XCTAssertEqual(SessionsRemoval.outcome(of: nil), .deleted)
        XCTAssertEqual(SessionsRemoval.outcome(of: DaemonError.http(status: 409, message: "会话正在使用中")), .busy)
        XCTAssertEqual(SessionsRemoval.outcome(of: DaemonError.http(status: 404, message: "no such session")), .gone)
        XCTAssertEqual(SessionsRemoval.outcome(of: DaemonError.http(status: 500, message: "有 1 个记录文件未能删除。")), .failed)
        XCTAssertEqual(SessionsRemoval.outcome(of: DaemonError.unreachable("x")), .failed)
    }

    func testAClickPicksAndUnpicksAndShiftTakesTheRowsBetween() {
        let order = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(SessionPick.clicked("b", picked: ["a"], anchor: "a", order: order, range: false), ["a", "b"])
        XCTAssertEqual(SessionPick.clicked("a", picked: ["a", "b"], anchor: "b", order: order, range: false), ["b"])
        XCTAssertEqual(SessionPick.clicked("d", picked: ["b"], anchor: "b", order: order, range: true), ["b", "c", "d"])
        // Upwards too, and what was picked elsewhere stays.
        XCTAssertEqual(SessionPick.clicked("a", picked: ["c", "e"], anchor: "c", order: order, range: true), ["a", "b", "c", "e"])
        // The row clicked before is no longer listed: the click is a plain one.
        XCTAssertEqual(SessionPick.clicked("d", picked: ["b"], anchor: "z", order: order, range: true), ["b", "d"])
        XCTAssertEqual(SessionPick.clicked("d", picked: [], anchor: nil, order: order, range: true), ["d"])
    }

    func testTheWords() {
        XCTAssertEqual(SessionDeleteWords.delete(1), "Delete Session…")
        XCTAssertEqual(SessionDeleteWords.delete(5), "Delete 5 Sessions…")
        XCTAssertEqual(SessionDeleteWords.selected(3), "3 Selected")
        XCTAssertEqual(SessionDeleteWords.title(5), "删除 5 个会话？")
        XCTAssertEqual(SessionDeleteWords.body(titles: ["修首页", ""]), "将删除「修首页」、「无标题」的记录，此操作无法撤销。正在使用的会话不会删除。")
        XCTAssertEqual(SessionDeleteWords.body(titles: ["a", "b", "c", "d", "e"]), "将删除「a」、「b」、「c」等 5 个会话的记录，此操作无法撤销。正在使用的会话不会删除。")
        func removal(_ outcomes: [String]) -> SessionsRemoval { SessionsRemoval(results: outcomes.enumerated().map { .init(harness: "codex", id: "s\($0.offset)", outcome: $0.element) }) }
        XCTAssertEqual(SessionDeleteWords.said(removal(["deleted", "deleted"])), "已删除 2 个会话。")
        XCTAssertEqual(SessionDeleteWords.said(removal(["deleted", "busy", "failed", "gone"])), "已删除 1 个会话；1 个正在使用，未删除；1 个未能删除。")
        XCTAssertEqual(SessionDeleteWords.said(removal(["busy"])), "1 个正在使用，未删除。")
        XCTAssertNil(SessionDeleteWords.said(removal(["gone"])))
    }
}
