import XCTest
@testable import AgentSwitchMacCore

/// docs/files-v0.md §12.2: the Files column's changes — what it asks the service, how it reads its refusals, a name
/// judged as it is typed, ⌘Z / ⇧⌘Z's two stacks, its sentences, and where a new row goes in the tree.
final class FilesChangesTests: XCTestCase {
    func testAsksTheServiceForEachChangeOnTheNodeTheClientIsOn() async throws {
        let transport = StubTransport { request in
            switch request.url!.path {
            case "/files/folder": return (201, #"{"path":"/Users/you/lumen/a/b","top":"/Users/you/lumen/a"}"#)
            case "/nodes/mini/files/file": return (201, #"{"path":"/Users/you/x.md","top":"/Users/you/x.md"}"#)
            case "/files/rename": return (200, #"{"path":"/Users/you/lumen/index.ts"}"#)
            case "/files/trash": return (200, #"{"moved":[{"path":"/Users/you/a.md","trashed":"/Users/you/.Trash/a.md"},{"path":"/Users/you/b.md","trashed":null}]}"#)
            default: return (200, #"{"path":"/Users/you/a.md"}"#)
            }
        }
        let here = DaemonClient(port: 4711, transport: transport)
        let folder = try await here.newFolder(path: "/Users/you/lumen/a/b")
        XCTAssertEqual(folder, FileMade(path: "/Users/you/lumen/a/b", top: "/Users/you/lumen/a"))
        let file = try await here.onNode("mini").newFile(path: "/Users/you/x.md")
        XCTAssertEqual(file.path, "/Users/you/x.md")
        let renamed = try await here.renameFile(path: "/Users/you/lumen/app.ts", name: "index.ts")
        XCTAssertEqual(renamed, "/Users/you/lumen/index.ts")
        let moved = try await here.trashFiles(paths: ["/Users/you/a.md", "/Users/you/b.md"])
        XCTAssertEqual(moved, [FileMoved(path: "/Users/you/a.md", trashed: "/Users/you/.Trash/a.md"), FileMoved(path: "/Users/you/b.md", trashed: nil)])
        let back = try await here.restoreFile(trashed: "/Users/you/.Trash/a.md", path: "/Users/you/a.md")
        XCTAssertEqual(back, "/Users/you/a.md")
        XCTAssertEqual(transport.requests.map { "\($0.httpMethod ?? "") \($0.url!.path)" }, [
            "POST /files/folder", "POST /nodes/mini/files/file", "POST /files/rename", "POST /files/trash", "POST /files/restore"])
        let rename = try JSONSerialization.jsonObject(with: transport.requests[2].httpBody!) as! [String: Any]
        XCTAssertEqual(rename["name"] as? String, "index.ts")
        XCTAssertEqual(rename["force"] as? Bool, false)
        let trash = try JSONSerialization.jsonObject(with: transport.requests[3].httpBody!) as! [String: Any]
        XCTAssertEqual(trash["paths"] as? [String], ["/Users/you/a.md", "/Users/you/b.md"])
        XCTAssertEqual(trash["permanent"] as? Bool, false)
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testReadsWhatARefusalSaysBesideItsCode() async throws {
        let transport = StubTransport { request in
            switch request.url!.path {
            case "/files/rename": return (409, #"{"error":"in-use","terminals":[{"id":"t1","name":"排序改成最近使用"}]}"#)
            case "/files/trash": return (409, #"{"error":"no-trash","paths":["/Volumes/NAS/big.iso"],"moved":[{"path":"/Users/you/a.md","trashed":"/Users/you/.Trash/a.md"}]}"#)
            default: return (403, #"{"error":"changes-off"}"#)
            }
        }
        let client = DaemonClient(port: 4711, transport: transport)
        do { _ = try await client.renameFile(path: "/Users/you/lumen", name: "lumen-2"); XCTFail("asked") } catch let refusal as FileChangeRefusal {
            XCTAssertEqual(refusal, FileChangeRefusal(status: 409, code: "in-use", terminals: [.init(id: "t1", name: "排序改成最近使用")]))
        }
        do { _ = try await client.trashFiles(paths: ["/Users/you/a.md", "/Volumes/NAS/big.iso"]); XCTFail("asked") } catch let refusal as FileChangeRefusal {
            XCTAssertEqual(refusal.code, "no-trash")
            XCTAssertEqual(refusal.paths, ["/Volumes/NAS/big.iso"])
            XCTAssertEqual(refusal.moved, [FileMoved(path: "/Users/you/a.md", trashed: "/Users/you/.Trash/a.md")])
        }
        do { _ = try await client.onNode("mini").newFolder(path: "/x/y"); XCTFail("refused") } catch let refusal as FileChangeRefusal {
            XCTAssertEqual(refusal.sentence(node: "Mac mini"), "Mac mini 不允许配对的设备修改文件。可在 Mac mini 的“设置 › Nodes”中打开。")
        }
        XCTAssertEqual(FileChangeRefusal(status: 403, code: "locked").sentence(), FilesWords.fixed)
        XCTAssertEqual(FileChangeRefusal(status: 403, code: "scope").sentence(node: "Mac mini"), "此文件夹不在 Mac mini 给这台设备的授权范围内。")
        // A listing says what is never moved; the switch says changes, and an older service is taken as on.
        let entry = try JSONDecoder().decode(FileEntry.self, from: Data(#"{"name":"you","kind":"dir","size":0,"mtime":1,"hidden":false,"fixed":true}"#.utf8))
        XCTAssertTrue(entry.fixed)
        XCTAssertFalse(entry.changeable)
        XCTAssertFalse(FileEntry(name: ".secret-gate", kind: .dir, locked: true).changeable)
        XCTAssertTrue(FileEntry(name: "lumen", kind: .dir).changeable)
        XCTAssertEqual(try JSONDecoder().decode(MeshSettings.self, from: Data(#"{"keyboard":true,"files":true}"#.utf8)).changes, true)
        XCTAssertEqual(try JSONDecoder().decode(MeshSettings.self, from: Data(#"{"keyboard":true,"files":true,"changes":false}"#.utf8)).changes, false)
    }

    func testJudgesANameAsItIsTyped() {
        let here: Set<String> = ["docs", "src", "src/app.ts", "README.md"]
        let taken = { here.contains($0) }
        XCTAssertEqual(FilesNameCheck.check("", taken: taken), .init(error: "请输入名称。"))
        XCTAssertEqual(FilesNameCheck.check("   ", taken: taken), .init(error: "请输入名称。"))
        XCTAssertEqual(FilesNameCheck.check("docs", taken: taken), .init(error: "此位置已有“docs”。请换一个名称。"))
        XCTAssertEqual(FilesNameCheck.check("src/app.ts", taken: taken), .init(error: "此位置已有“src/app.ts”。请换一个名称。"))
        XCTAssertEqual(FilesNameCheck.check("..", taken: taken), .init(error: "名称不能是“.”或“..”。"))
        XCTAssertEqual(FilesNameCheck.check("a/../b", taken: taken), .init(error: "名称不能是“.”或“..”。"))
        XCTAssertEqual(FilesNameCheck.check(" notes.md", taken: taken), .init(warning: "名称前后有空格。"))
        XCTAssertTrue(FilesNameCheck.check(" notes.md", taken: taken).ok)
        XCTAssertEqual(FilesNameCheck.check("src/utils/date.ts", taken: taken), .init())
        XCTAssertEqual(FilesNameCheck.check("fixtures", taken: taken).line, nil)
        // Renamed: a slash is no name; its own name is not taken by itself.
        XCTAssertEqual(FilesNameCheck.check("a/b", renaming: "app.ts", taken: taken), .init(error: "名称不能包含“/”。"))
        XCTAssertEqual(FilesNameCheck.check("README.md", renaming: "README.md", taken: taken), .init())
        XCTAssertEqual(FilesNameCheck.check("docs", renaming: "README.md", taken: taken).error, "此位置已有“docs”。请换一个名称。")
        // A rename selects as Finder does.
        XCTAssertEqual(FilesNameCheck.selected("app.ts", folder: false), NSRange(location: 0, length: 3))
        XCTAssertEqual(FilesNameCheck.selected("archive.tar.gz", folder: false), NSRange(location: 0, length: 11))
        XCTAssertEqual(FilesNameCheck.selected(".env", folder: false), NSRange(location: 0, length: 4))
        XCTAssertEqual(FilesNameCheck.selected("Makefile", folder: false), NSRange(location: 0, length: 8))
        XCTAssertEqual(FilesNameCheck.selected("v1.2", folder: true), NSRange(location: 0, length: 4))
        XCTAssertEqual(FilesNameCheck.selected("名字.md", folder: false), NSRange(location: 0, length: 2))
    }

    func testUndoAndRedoAreTwoStacksOfOppositeSteps() {
        var h = FilesHistory()
        h.did(.made(top: "/p/a", shown: "/p/a/b.ts"))
        h.did(.renamed(from: "/p/x", to: "/p/y"))
        XCTAssertEqual(h.takeUndo(), .renamed(from: "/p/x", to: "/p/y"))
        h.undone(.renamed(from: "/p/y", to: "/p/x"))
        XCTAssertEqual(h.redo, [.renamed(from: "/p/y", to: "/p/x")])
        XCTAssertEqual(h.takeRedo(), .renamed(from: "/p/y", to: "/p/x"))
        h.redone(.renamed(from: "/p/x", to: "/p/y"))
        XCTAssertEqual(h.undo, [.made(top: "/p/a", shown: "/p/a/b.ts"), .renamed(from: "/p/x", to: "/p/y")])
        _ = h.takeUndo()
        h.undone(.renamed(from: "/p/y", to: "/p/x"))
        // A fresh change: what was undone cannot be done again.
        h.did(.trashed([FileMoved(path: "/p/c", trashed: "/t/c")]))
        XCTAssertEqual(h.redo, [])
        XCTAssertNil(h.takeRedo())
        XCTAssertEqual(h.undo.count, 2)
    }

    func testSaysWhatWasDone() {
        XCTAssertEqual(FilesWords.trashed(["/Users/you/lumen/docs/logo.png"]), "已将“logo.png”移到废纸篓。⌘Z 可放回。")
        XCTAssertEqual(FilesWords.trashed(["/a", "/b", "/c"]), "已将 3 项移到废纸篓。⌘Z 可放回。")
        // `Download` (docs/files-v0.md §13).
        XCTAssertEqual(FilesWords.downloading(["/Users/you/out/report.xlsx"]), "正在下载“report.xlsx”…")
        XCTAssertEqual(FilesWords.downloaded(["/Users/you/Downloads/report.xlsx", "/Users/you/Downloads/b.md"]), "已下载 2 项到“下载”。")
        XCTAssertEqual(FilesWords.notDownloaded(node: "Mac mini"), "文件超过 Mac mini 给配对设备的上限，未下载。")
        let folder = URL(fileURLWithPath: "/Users/you/Downloads")
        let there: Set<String> = ["report.xlsx", "report 2.xlsx", "README", "README 2"]
        let free = { (name: String) in FilesDownloads.free(in: folder, name: name) { there.contains($0.lastPathComponent) }.lastPathComponent }
        XCTAssertEqual(free("report.xlsx"), "report 3.xlsx")
        XCTAssertEqual(free("new.xlsx"), "new.xlsx")
        XCTAssertEqual(free("README"), "README 3")
        XCTAssertEqual(FilesWords.putBack(["/a/logo.png"]), "已放回“logo.png”。")
        XCTAssertEqual(FilesWords.renamedBack("app.ts"), "已改回“app.ts”。")
        XCTAssertEqual(FilesWords.madeHidden(".env"), "已创建“.env”。它是隐藏文件，可在 ⋯ › Show Hidden Files 中显示。")
        XCTAssertEqual(FilesWords.notPutBack("/a/plan.md"), "原位置已有“plan.md”，未放回。可在废纸篓中手动放回。")
        XCTAssertEqual(FilesWords.inUse(terminal: "refreshToken 字段", renaming: false), "终端“refreshToken 字段”正在此文件夹中运行。移到废纸篓后，其中的 agent 仍会使用原来的路径，可能出错。")
        XCTAssertEqual(FilesWords.inUse(terminal: "x", renaming: true), "终端“x”正在此文件夹中运行。改名后，其中的 agent 仍会使用原来的路径，可能出错。")
        XCTAssertEqual(FilesWords.noTrash(["/Volumes/NAS/big.iso"]), "无法将“big.iso”移到废纸篓。要永久删除吗？此操作无法撤销。")
    }

    func testPutsANewRowFirstUnderItsFolderDrawnAsItsChildrenAre() {
        let level = { (path: String, names: [(String, FileEntry.Kind)]) in FileLevel(path: path, parent: nil, home: "/h", entries: names.map { FileEntry(name: $0.0, kind: $0.1) }) }
        let levels = [
            "/p": level("/p", [("docs", .dir), ("src", .dir), ("a.md", .file)]),
            "/p/src": level("/p/src", [("app.ts", .file)]),
            "/p/docs": level("/p/docs", []),
        ]
        let rows = FilesTree.rows(root: "/p", levels: levels, open: ["/p/src", "/p/docs"], order: .name, hidden: false)
        XCTAssertEqual(rows.map(\.path), ["/p/docs", "/p/src", "/p/src/app.ts", "/p/a.md"])
        XCTAssertEqual(FilesTree.slot(for: "/p", root: "/p", rows: rows), FilesTree.Slot(index: 0, depth: 0, stems: [], last: false))
        let inSrc = FilesTree.slot(for: "/p/src", root: "/p", rows: rows)
        XCTAssertEqual(inSrc, FilesTree.Slot(index: 2, depth: 1, stems: [false], last: false))
        XCTAssertEqual(inSrc?.twig, "│  ├─")
        // An empty open folder: the new row is its only one.
        XCTAssertEqual(FilesTree.slot(for: "/p/docs", root: "/p", rows: rows)?.twig, "│  └─")
        XCTAssertNil(FilesTree.slot(for: "/p/a.md", root: "/p", rows: rows))
    }
}
