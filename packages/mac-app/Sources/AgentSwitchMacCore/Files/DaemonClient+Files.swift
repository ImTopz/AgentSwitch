import Foundation

// The Files column's routes (docs/files-v0.md §7.1), on whichever node the client is on: this Mac's own service, or
// another node's through it (`onNode`), where that node's switch and the scope it gives this Mac apply.

extension DaemonClient {
    static func query(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~/"))) ?? path
    }

    /// `GET /files`: one folder's level; nil `path` for where this viewer starts (home, or its scope's first folder).
    /// Unchanged since `version`: nil (a 304).
    public func fileLevel(path: String?, hidden: Bool, version: String? = nil) async throws -> Versioned<FileLevel>? {
        var route = "/files?hidden=\(hidden ? 1 : 0)"
        if let path { route += "&path=\(Self.query(path))" }
        guard let answer = try await callUnlessUnchanged(route, version: version) else { return nil }
        return Versioned(value: try decode(FileLevel.self, answer.value), version: answer.version)
    }

    /// `GET /files/stat`: one entry's details.
    public func fileDetails(path: String) async throws -> FileDetails {
        try decode(FileDetails.self, try await call("GET", "/files/stat?path=\(Self.query(path))"))
    }

    /// `GET /files/preview`: the start of a text file.
    public func fileTextPreview(path: String) async throws -> FileTextPreview {
        try decode(FileTextPreview.self, try await call("GET", "/files/preview?path=\(Self.query(path))"))
    }

    /// `GET /files/thumbnail`: a picture's small copy (JPEG on a Mac).
    public func fileThumbnail(path: String) async throws -> Data {
        try await call("GET", "/files/thumbnail?path=\(Self.query(path))", accept: "image/*")
    }

    /// `GET /files/content`: the file's bytes, written to `destination` (for Quick Look of a file that is not on this
    /// Mac, and `Download`). Another node gives a phone 200 MB at most, a paired Mac the whole file.
    @discardableResult
    public func downloadFile(path: String, to destination: URL) async throws -> URL {
        let data = try await call("GET", "/files/content?path=\(Self.query(path))", accept: "*/*", timeout: 120)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// `PUT /devices/:id/files`: what of this Mac's files a paired device may read. Always this Mac's own service.
    public func setDeviceFiles(id: String, scope: FileScope) async throws -> FileScope {
        struct Answer: Decodable { let files: FileScope }
        let data = try await onNode(nil).call("PUT", "/devices/\(Self.segment(id))/files", body: try JSONEncoder().encode(scope))
        return try decode(Answer.self, data).files
    }

    /// `call` with another `Accept`: a picture or bytes, not JSON.
    func call(_ method: String, _ path: String, accept: String, timeout: TimeInterval? = nil) async throws -> Data {
        var request = request(method, path)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let timeout { request.timeoutInterval = timeout }
        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try await transport.send(request) } catch let error as DaemonError { throw error } catch {
            throw DaemonError.unreachable(error.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw DaemonError.http(status: response.statusCode, message: DaemonClient.errorMessage(data))
        }
        return data
    }
}
