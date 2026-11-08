import Foundation

/// `Download` in the Files column (docs/files-v0.md §13): another node's files into this Mac's Downloads folder, as a
/// browser saves them — no panel asked; a name already there gets a number (`report 2.xlsx`), as Finder names a copy.
public enum FilesDownloads {
    /// The user's Downloads folder.
    public static func folder() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    /// `name` in `folder`, or the first of `name 2`, `name 3`… not there (`taken`: whether a path is; the disk by default).
    public static func free(in folder: URL, name: String, taken: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let first = folder.appendingPathComponent(name)
        guard taken(first) else { return first }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for n in 2... {
            let next = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            if !taken(next) { return next }
        }
        return first
    }
}
