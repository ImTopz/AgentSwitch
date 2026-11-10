import XCTest
@testable import AgentSwitchMacCore

/// A task's live events over the local API (ported from the Kit's EventStreamTests): replay then follow, reconnect from
/// the last seq without duplicates, end on a terminal event or an ended task, fail on a refusal, give up on silence.
final class DispatchEventStreamTests: XCTestCase {
    private typealias F = DispatchFixture
    private let fast = DispatchReconnectPolicy(initial: .milliseconds(5), maximum: .milliseconds(20))

    private static func detail(_ status: String) -> Data {
        F.json(["id": "t1", "createdAt": 0, "updatedAt": 0, "status": status, "task": "x", "approvals": []])
    }

    private func client(_ transport: DispatchFakeTransport) throws -> DaemonClient {
        let home = TestSupport.tempDir("events")
        let token = home.appendingPathComponent(DaemonClient.tokenFileName)
        try "tok-123".write(to: token, atomically: true, encoding: .utf8)
        return DaemonClient(port: 4811, transport: transport, tokenFile: token)
    }

    func testReplayThenFollowUntilTerminal() async throws {
        let transport = DispatchFakeTransport.streaming({ _, _ in
            (200, [F.frame(1, "queued"), F.frame(2, "text", ["text": "hi"]), Data(": ping\n\n".utf8), F.frame(3, "done", ["result": "ok"])], nil)
        })
        var got: [Int64] = []
        for try await event in try client(transport).taskEvents(taskId: "t1", after: 0, policy: fast) { got.append(event.seq) }
        XCTAssertEqual(got, [1, 2, 3])
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:4811/tasks/t1/events?after=0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123", "the local API wants the token on the stream too")
        XCTAssertEqual(request.timeoutInterval, fast.idleTimeout)
    }

    func testFramesSplitAcrossChunksAndForeignOrBrokenFramesAreSkipped() async throws {
        let whole = F.frame(2, "text", ["text": "第一行"])
        let transport = DispatchFakeTransport.streaming({ _, _ in
            (200, [F.frame(1, "text", task: "other"), Data("event: text\ndata: {not json}\n\n".utf8),
                   whole.prefix(17), whole.dropFirst(17), F.frame(3, "failed", ["error": "x"])], nil)
        })
        var got: [Int64] = []
        for try await event in try client(transport).taskEvents(taskId: "t1", after: 0, policy: fast) { got.append(event.seq) }
        XCTAssertEqual(got, [2, 3])
    }

    func testReconnectsFromTheLastSeqWithoutDuplicates() async throws {
        let transport = DispatchFakeTransport.streaming({ _, n in
            switch n {
            case 0: return (200, [F.frame(5, "text"), F.frame(6, "text")], DaemonError.unreachable("connection lost"))
            case 1: throw URLError(.networkConnectionLost)
            default: return (200, [F.frame(6, "text"), F.frame(7, "failed", ["error": "x"])], nil)
            }
        }, handler: { _, _ in (200, Self.detail("running")) })
        var got: [Int64] = []
        for try await event in try client(transport).taskEvents(taskId: "t1", after: 4, policy: fast) { got.append(event.seq) }
        XCTAssertEqual(got, [5, 6, 7])
        let queries = transport.requests.filter { $0.url?.path.hasSuffix("/events") == true }.map { $0.url?.query ?? "" }
        XCTAssertEqual(queries, ["after=4", "after=6", "after=6"])
    }

    func testStopsWhenTheTaskIsAlreadyOver() async throws {
        let transport = DispatchFakeTransport.streaming({ _, _ in (200, [], nil) }, handler: { _, _ in (200, Self.detail("cancelled")) })
        var count = 0
        for try await _ in try client(transport).taskEvents(taskId: "t1", after: 9, policy: fast) { count += 1 }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(transport.lines, ["GET /tasks/t1/events?after=9", "GET /tasks/t1"])
    }

    func testAClosedStreamOfARunningTaskIsFollowedAgain() async throws {
        let transport = DispatchFakeTransport.streaming({ _, n in
            n == 0 ? (200, [F.frame(1, "text")], nil) : (200, [F.frame(2, "done")], nil)
        }, handler: { _, _ in (200, Self.detail("running")) })
        var got: [Int64] = []
        for try await event in try client(transport).taskEvents(taskId: "t1", after: 0, policy: fast) { got.append(event.seq) }
        XCTAssertEqual(got, [1, 2])
        XCTAssertEqual(transport.lines, ["GET /tasks/t1/events?after=0", "GET /tasks/t1", "GET /tasks/t1/events?after=1"])
    }

    func testARefusalEndsWithAnError() async throws {
        let transport = DispatchFakeTransport.streaming({ _, _ in (404, [F.json(["error": "not found"])], nil) })
        do {
            for try await _ in try client(transport).taskEvents(taskId: "t1", after: 0, policy: fast) {}
            XCTFail("expected 404")
        } catch {
            XCTAssertEqual(error as? DaemonError, .http(status: 404, message: "not found"))
        }
        let unauthorized = DispatchFakeTransport.streaming({ _, _ in (401, [F.json(["error": "unauthorized"])], nil) })
        do {
            for try await _ in try client(unauthorized).taskEvents(taskId: "t1", after: 0, policy: fast) {}
            XCTFail("expected 401")
        } catch {
            XCTAssertEqual(error as? DaemonError, .http(status: 401, message: "unauthorized"))
        }
    }

    func testSilenceCountsAsADroppedConnection() async {
        let (silent, sink) = AsyncThrowingStream<Data, Error>.makeStream()
        defer { sink.finish() }
        do {
            for try await _ in DaemonClient.idleGuarded(silent, limit: .milliseconds(50)) {}
            XCTFail("expected the idle limit")
        } catch {
            XCTAssertEqual(error as? DaemonError, .unreachable(DaemonClient.idleMessage))
            XCTAssertTrue((error as? DaemonError)?.isNetworkFailure == true, "silence reconnects rather than failing the page")
        }
    }

    /// Every stream the app follows goes to one host and holds its connection. A URL session left as it comes gives a
    /// host six: the seventh stream waited for one until its time ran out, and the pane it was for stood still
    /// (2026-11-10, user: 简略模式我刚才发的消息被吃掉了).
    func testMoreStreamsThanAURLSessionGivesAHostByDefault() async throws {
        XCTAssertGreaterThanOrEqual(URLSessionStreamTransport.configuration().httpMaximumConnectionsPerHost, 64)
        let server = HoldingServer()
        defer { server.stop() }
        let transport = URLSessionStreamTransport()
        let wanted = 12
        let answered = DispatchLock(0)
        let streams = (0..<wanted).map { n in
            Task {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/stream/\(n)")!)
                request.timeoutInterval = 20
                guard let (response, body) = try? await transport.stream(request), response.statusCode == 200 else { return }
                for try await _ in body { answered.withLock { $0 += 1 }; break }
                // Held open, as a followed stream is, until the test is over.
                try? await Task.sleep(for: .seconds(30))
            }
        }
        defer { streams.forEach { $0.cancel() } }
        let all = await TestSupport.waitUntil(timeout: 10) { answered.withLock { $0 } == wanted }
        XCTAssertTrue(all, "only \(answered.withLock { $0 }) of \(wanted) streams were answered while the others were held")
    }

    func testBackoff() {
        let p = DispatchReconnectPolicy(initial: .seconds(1), maximum: .seconds(15))
        XCTAssertEqual((1...6).map { p.delay(afterFailures: $0) }, [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(15)])
        XCTAssertEqual(p.delay(afterFailures: 0), .zero)
    }

    func testEventsTouchingTheTaskAndItsApprovals() {
        XCTAssertTrue(F.event(1, "approval_request").touchesApprovals)
        XCTAssertTrue(F.event(1, "done").endsStream)
        XCTAssertTrue(F.event(1, "dispatched").touchesTask)
        XCTAssertFalse(F.event(1, "text").touchesTask)
        XCTAssertEqual(F.event(7, "text", task: "t9").id, "t9#7")
    }
}

/// A loopback server that answers every connection as an event stream and never ends it: one comment at once, then
/// silence, the connection held until the server stops.
final class HoldingServer: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private let lock = NSLock()
    private var clients: [Int32] = []

    init() {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(sock, 64)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) } }
        fd = sock
        port = Int(UInt16(bigEndian: addr.sin_port))
        Thread { [self] in serve() }.start()
    }

    private func serve() {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            lock.withLock { clients.append(client) }
            Thread {
                _ = LoopbackSocket.readHead(client, limit: 8192, timeout: 2)
                let ping = ": ping\n\n"
                let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n\(String(ping.utf8.count, radix: 16))\r\n\(ping)\r\n"
                _ = LoopbackSocket.sendAll(client, Data(head.utf8))
            }.start()
        }
    }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
        lock.withLock { clients.forEach { close($0) }; clients = [] }
    }
}
