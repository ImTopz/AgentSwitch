import AgentSwitchMacCore
import AppKit
import SwiftUI

// The column's list (docs/files-v0.md §3.3): the pixel look's tree (`tree -F` in two-cell lines, `▸ ▾` only open and
// close), the classic look's folders one level at a time (Finder's list) and, wide, Finder's last two columns; either
// look's other view from `⋯`. A click selects (⌘ and ⇧ as Finder's), a double click opens, a right click is the system's
// menu; this Mac's files drag out to a pane as Finder's do.

struct FilesList: View {
    let files: FilesColumn
    @Environment(\.interfaceLook) private var look

    var body: some View {
        if let root = files.root {
            if let refusal = files.refusals[root] {
                FilesNote(text: refusal.sentence(node: files.nodeName), settings: refusal == .permission)
            } else if files.levels[root] == nil {
                FilesNote(text: "")
            } else if files.columns(classic: look.isClassic) {
                FilesColumns(files: files, root: root)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: look.isClassic ? 1 : 0) { rows(root) }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                        // The list's empty part: the shown folder's own menu (files-v0 §12.2).
                        .contentShape(Rectangle())
                        .contextMenu { FilesFolderMenu(files: files, folder: root) }
                }
                .scrollIndicators(.automatic)
            }
        } else {
            FilesNote(text: "")
        }
    }

    @ViewBuilder
    private func rows(_ root: String) -> some View {
        switch files.shown(classic: look.isClassic) {
        case .tree:
            if !look.isClassic, let up = files.levels[root]?.parent {
                FilesUpRow { files.go(to: up) }
            }
            let rows = files.treeRows()
            // A new item's row, while its name is typed: first under its folder (files-v0 §12.2).
            let adding = files.edit.flatMap { edit -> (FilesEdit, FilesTree.Slot)? in
                switch edit.kind {
                case .newFile(let dir), .newFolder(let dir): FilesTree.slot(for: dir, root: root, rows: rows).map { (edit, $0) }
                case .rename: nil
                }
            }
            if rows.isEmpty, adding == nil { FilesNote(text: "此文件夹为空。") }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                if let adding, adding.1.index == i { FilesNewRow(files: files, edit: adding.0, slot: adding.1).id("new") }
                if look.isClassic { ClassicTreeRow(files: files, row: row) } else { PixelTreeRow(files: files, row: row) }
            }
            if let adding, adding.1.index == rows.count { FilesNewRow(files: files, edit: adding.0, slot: adding.1).id("new") }
        case .folders:
            let entries = files.entries(of: root)
            let adding = files.edit.flatMap { edit -> FilesEdit? in
                switch edit.kind {
                case .newFile(let dir), .newFolder(let dir): dir == root ? edit : nil
                case .rename: nil
                }
            }
            if let adding { FilesNewRow(files: files, edit: adding).id("new") }
            if entries.isEmpty, adding == nil { FilesNote(text: "此文件夹为空。") }
            ForEach(entries, id: \.name) { entry in
                let path = FilesPath.join(root, entry.name)
                if look.isClassic { ClassicFolderRow(files: files, entry: entry, path: path) } else { PixelFolderRow(files: files, entry: entry, path: path) }
            }
        }
        if let level = files.levels[root], level.more > 0 {
            Text("▸ \(level.more.formatted()) More").font(.system(size: 11, design: look.isClassic ? .default : .monospaced)).foregroundStyle(Look.faint).padding(.horizontal, 12).padding(.vertical, 4)
        }
    }
}

/// A line in place of the list: empty, refused, or what cannot be read.
private struct FilesNote: View {
    let text: String
    var settings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !text.isEmpty { Text(text).font(.system(size: 12)).foregroundStyle(Look.ink2).fixedSize(horizontal: false, vertical: true) }
            if settings {
                Button { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!) } label: { BracketLabel(word: "Open System Settings") }
                    .buttonStyle(BracketButtonStyle(size: 12))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Clicks on a row: one selects (⌘, ⇧), the second of a double click opens.
@MainActor
private func clicked(_ files: FilesColumn, _ path: String, classic: Bool) {
    files.focusKeys()
    let event = NSApp.currentEvent
    let flags = event?.modifierFlags ?? []
    if (event?.clickCount ?? 1) >= 2, !flags.contains(.command), !flags.contains(.shift) { return files.open(path) }
    files.select(path, command: flags.contains(.command), shift: flags.contains(.shift), classic: classic)
}

extension View {
    /// A row's drag (this Mac's files: as Finder's, onto a pane or anywhere) and its right click.
    @ViewBuilder
    func filesRow(_ files: FilesColumn, _ path: String, entry: FileEntry) -> some View {
        let base = contentShape(Rectangle()).contextMenu { FilesRowMenu(files: files, path: path, entry: entry) }
        if files.local, !entry.locked {
            base.onDrag { NSItemProvider(contentsOf: URL(fileURLWithPath: path)) ?? NSItemProvider() }
        } else {
            base
        }
    }
}

/// The row's right click (files-v0 §3.3, §12.2): on what is selected when the row is among it, else on the row. What
/// does not apply is left out, not dimmed, and no keys are written (HIG Context menus); new items in a folder's menu
/// under what is used most, `Rename…` and `Move to Trash` last (VS Code's order).
private struct FilesRowMenu: View {
    let files: FilesColumn
    let path: String
    let entry: FileEntry

    var body: some View {
        let paths = files.selection.contains(path) ? files.selection : [path]
        if !entry.locked {
            if files.target() != nil { Button("Add to Reply") { files.addToReply(paths) } }
            if !entry.isFolder { Button("Quick Look") { files.select(path, classic: false); files.toggleQuickLook() } }
            Button("Open") { paths.forEach(files.open) }
            if entry.isFolder {
                Divider()
                Button("New File…") { files.startNew(folder: false, inside: path) }
                Button("New Folder…") { files.startNew(folder: true, inside: path) }
            }
            Divider()
            if files.local { Button("Show in Finder") { files.showInFinder(paths) } }
            // Another node's file onto this Mac (docs/files-v0.md §13); this Mac's are here already.
            if !files.local, !entry.isFolder { Button("Download") { files.download(paths) } }
            Button("Copy Path") { files.copyPaths(paths) }
            if files.relativeAvailable(paths) { Button("Copy Relative Path") { files.copyPaths(paths, relative: true) } }
            if entry.isFolder { Button("New Terminal Here") { files.newTerminal(entry.kind == .link ? entry.link?.target ?? path : path) } }
            if paths.allSatisfy({ files.entry($0)?.changeable ?? false }) {
                Divider()
                if paths.count == 1 { Button("Rename…") { files.startRename(path) } }
                Button("Move to Trash") { files.trash(paths) }
            }
        }
    }
}

/// The name, or the box it is typed in while the row is being renamed.
private struct FilesRenaming<Name: View>: View {
    let files: FilesColumn
    let path: String
    @ViewBuilder let name: Name

    var body: some View {
        if let edit = files.edit, edit.kind == .rename(path) { FilesNameBox(files: files, edit: edit) } else { name }
    }
}

/// The line under a row being renamed that says what is wrong with the name.
private struct FilesRenameCheck: View {
    let files: FilesColumn
    let path: String
    let indent: CGFloat

    var body: some View {
        if let edit = files.edit, edit.kind == .rename(path) { FilesCheckLine(files: files, edit: edit, indent: indent) }
    }
}

// MARK: - the pixel look

/// `../`: the level above.
private struct FilesUpRow: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Text("../").mono(12.5).foregroundStyle(Look.ink2)
            .padding(.leading, 12).frame(height: 22).frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? ListLook.hover : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { hovering = $0 }
    }
}

/// A row of the tree: `├─▸ src/`, its size and when it changed at the end, faint.
private struct PixelTreeRow: View {
    let files: FilesColumn
    let row: FilesTreeRow
    @State private var hovering = false

    var body: some View {
        let entry = row.entry
        let selected = files.selection.contains(row.path)
        VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 0) {
            Text(row.twig).foregroundStyle(Look.line)
            if entry.isFolder && !entry.locked {
                Text(row.open ? "▾" : "▸").foregroundStyle(Look.ink2)
                    .contentShape(Rectangle())
                    .onTapGesture { files.twist(row.path, all: NSEvent.modifierFlags.contains(.option)) }
            } else {
                Text("─").foregroundStyle(Look.line)
            }
            FilesRenaming(files: files, path: row.path) { PixelName(entry: entry) }.padding(.leading, ListLook.ch)
            Spacer(minLength: 8)
            PixelMeta(entry: entry, wide: files.width >= 300)
        }
        .font(.system(size: 12.5, design: .monospaced))
        .lineLimit(1)
        .padding(.leading, 12).padding(.trailing, 10)
        .frame(height: 22)
        .background(selected ? ListLook.selected : hovering ? ListLook.hover : Color.clear)
        .overlay(alignment: .leading) { if selected { Rectangle().fill(Color.signal).frame(width: 3) } }
        .filesRow(files, row.path, entry: entry)
        .onTapGesture { clicked(files, row.path, classic: false) }
        .onHover { hovering = $0 }
        .help(entry.locked ? FilesRefusal.locked.sentence() : row.path)
        FilesRenameCheck(files: files, path: row.path, indent: 12 + CGFloat(row.depth * 3 + 4) * ListLook.ch)
        }
    }
}

/// A row of a level, the pixel look's `As Folders`: the name, and `›` into a folder.
private struct PixelFolderRow: View {
    let files: FilesColumn
    let entry: FileEntry
    let path: String
    @State private var hovering = false

    var body: some View {
        let selected = files.selection.contains(path)
        VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 0) {
            FilesRenaming(files: files, path: path) { PixelName(entry: entry) }
            Spacer(minLength: 8)
            PixelMeta(entry: entry, wide: files.width >= 300)
            if entry.isFolder, !entry.locked {
                Text("›").foregroundStyle(Look.faint).padding(.leading, 8).contentShape(Rectangle()).onTapGesture { files.open(path) }
            }
        }
        .font(.system(size: 12.5, design: .monospaced))
        .lineLimit(1)
        .padding(.leading, 12).padding(.trailing, 10)
        .frame(height: 22)
        .background(selected ? ListLook.selected : hovering ? ListLook.hover : Color.clear)
        .overlay(alignment: .leading) { if selected { Rectangle().fill(Color.signal).frame(width: 3) } }
        .filesRow(files, path, entry: entry)
        .onTapGesture { clicked(files, path, classic: false) }
        .onHover { hovering = $0 }
        .help(entry.locked ? FilesRefusal.locked.sentence() : path)
        FilesRenameCheck(files: files, path: path, indent: 12)
        }
    }
}

/// `src/`, `→ ~/Documents`, `⌧`: the name as the tree writes it.
private struct PixelName: View {
    let entry: FileEntry

    var body: some View {
        let faint = entry.hidden || entry.dim || entry.locked
        HStack(spacing: 0) {
            Text(entry.name + (entry.isFolder ? "/" : ""))
                .fontWeight(entry.isFolder && !faint ? .bold : .regular)
                .foregroundStyle(faint ? Look.faint : Look.ink)
                .truncationMode(.middle)
            if let link = entry.link { Text(" → " + DisplayPath.short(link.target, home: NSHomeDirectory())).foregroundStyle(Look.faint).truncationMode(.middle) }
            if entry.locked { Text(" ⌧").foregroundStyle(Look.faint) }
        }
    }
}

/// `2.1K  Today 13:02`; a narrow column keeps the time alone.
private struct PixelMeta: View {
    let entry: FileEntry
    let wide: Bool

    var body: some View {
        HStack(spacing: 8) {
            if !entry.locked {
                if wide, !entry.isFolder { Text(FilesText.size(entry.size, short: true)).frame(minWidth: 30, alignment: .trailing) }
                Text(FilesText.date(entry.modified))
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Look.faint)
        .fixedSize()
    }
}

// MARK: - the classic look

/// A file's or a folder's line icon as Finder draws one (the folder in the accent).
struct FilesIcon: View {
    let entry: FileEntry
    var size: CGFloat = 15

    var body: some View {
        Image(systemName: Self.symbol(entry)).font(.system(size: size, weight: .regular))
            .foregroundStyle(entry.isFolder && !entry.locked ? Color.signal : Look.ink2)
            .frame(width: size + 5)
    }

    static func symbol(_ entry: FileEntry) -> String {
        if entry.locked { return "lock" }
        if entry.isFolder { return "folder" }
        if entry.kind == .link { return "link" }
        switch (entry.name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg": return "photo"
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tar", "tgz", "7z", "rar", "dmg": return "archivebox"
        case "mp3", "m4a", "wav", "aac", "flac": return "waveform"
        case "mp4", "mov", "m4v", "mkv", "webm": return "film"
        case "": return "doc"
        default: return "doc.text"
        }
    }
}

/// Finder's list, one level: icon, name, when it changed and its size, `›` into a folder (a single click there).
private struct ClassicFolderRow: View {
    let files: FilesColumn
    let entry: FileEntry
    let path: String
    /// In Finder's columns: which one, and whether this folder is the one the next column shows.
    var column: Int?
    var leads = false
    @State private var hovering = false

    var body: some View {
        let selected = files.selection.contains(path)
        let faint = entry.hidden || entry.dim || entry.locked
        let renaming = files.edit?.kind == .rename(path)
        VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 8) {
            FilesIcon(entry: entry).foregroundStyle(selected && !renaming ? Color.white : Look.ink2)
            FilesRenaming(files: files, path: path) {
                Text(entry.name).font(.system(size: 13)).foregroundStyle(selected ? Color.white : faint ? Look.faint : Look.ink).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if !entry.locked {
                Text(column == nil ? (entry.isFolder ? FilesText.date(entry.modified) : "\(FilesText.date(entry.modified)) · \(FilesText.size(entry.size, short: true))")
                                   : entry.isFolder ? "" : FilesText.size(entry.size, short: true))
                    .font(.system(size: 11.5)).foregroundStyle(selected ? Color.white.opacity(0.85) : Look.ink2).fixedSize()
            }
            if entry.isFolder, !entry.locked {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(selected ? Color.white.opacity(0.85) : Look.faint)
                    .frame(width: 14, height: 20).contentShape(Rectangle())
                    .onTapGesture { files.open(path) }
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: column == nil ? 30 : 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected && !renaming ? Color.signal : leads ? Look.raised : hovering ? ListLook.hover : Color.clear))
        .padding(.horizontal, 6)
        .filesRow(files, path, entry: entry)
        .onTapGesture {
            // Finder's columns: a click on a folder goes into it; in the left column, a file moves the row of columns back.
            if let column, entry.isFolder, !entry.locked { files.focusKeys(); files.open(path) }
            else if column == 0, !entry.locked, let up = FilesPath.parent(of: path) { files.go(to: up); files.select(path, classic: true) }
            else { clicked(files, path, classic: true) }
        }
        .onHover { hovering = $0 }
        .help(entry.locked ? FilesRefusal.locked.sentence() : path)
        FilesRenameCheck(files: files, path: path, indent: 48)
        }
    }
}

/// `As Tree` in the classic look: an outline with disclosure chevrons.
private struct ClassicTreeRow: View {
    let files: FilesColumn
    let row: FilesTreeRow
    @State private var hovering = false

    var body: some View {
        let entry = row.entry
        let renaming = files.edit?.kind == .rename(row.path)
        let selected = files.selection.contains(row.path) && !renaming
        let faint = entry.hidden || entry.dim || entry.locked
        VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 5) {
            Group {
                if entry.isFolder, !entry.locked {
                    Image(systemName: row.open ? "chevron.down" : "chevron.right").font(.system(size: 9.5, weight: .semibold))
                        .onTapGesture { files.twist(row.path, all: NSEvent.modifierFlags.contains(.option)) }
                } else { Color.clear }
            }
            .frame(width: 14).foregroundStyle(selected ? Color.white : Look.ink2)
            FilesIcon(entry: entry, size: 14).foregroundStyle(selected ? Color.white : Look.ink2)
            FilesRenaming(files: files, path: row.path) {
                Text(entry.name).font(.system(size: 13)).foregroundStyle(selected ? Color.white : faint ? Look.faint : Look.ink).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if !entry.isFolder, !entry.locked { Text(FilesText.size(entry.size, short: true)).font(.system(size: 11.5)).foregroundStyle(selected ? Color.white.opacity(0.85) : Look.ink2) }
        }
        .lineLimit(1)
        .padding(.leading, 8 + CGFloat(row.depth) * 16).padding(.trailing, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Color.signal : hovering ? ListLook.hover : Color.clear))
        .padding(.horizontal, 6)
        .filesRow(files, row.path, entry: entry)
        .onTapGesture { clicked(files, row.path, classic: true) }
        .onHover { hovering = $0 }
        FilesRenameCheck(files: files, path: row.path, indent: 14 + CGFloat(row.depth) * 16 + 38)
        }
    }
}

/// Finder's columns, the last two (files-v0 §3.3): the level above, the shown folder marked in it, and the shown folder.
private struct FilesColumns: View {
    let files: FilesColumn
    let root: String

    var body: some View {
        let up = files.levels[root]?.parent
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if let up {
                        ForEach(files.entries(of: up), id: \.name) { entry in
                            let path = FilesPath.join(up, entry.name)
                            ClassicFolderRow(files: files, entry: entry, path: path, column: 0, leads: path == root)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity)
            .onAppear { if let up, files.levels[up] == nil { files.refresh(up) } }
            .onChange(of: root) { if let up = files.levels[root]?.parent, files.levels[up] == nil { files.refresh(up) } }
            Rectangle().fill(Look.line).frame(width: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    let entries = files.entries(of: root)
                    let adding: FilesEdit? = files.edit.flatMap { edit in
                        switch edit.kind {
                        case .newFile(let dir), .newFolder(let dir): dir == root ? edit : nil
                        case .rename: nil
                        }
                    }
                    if let adding { FilesNewRow(files: files, edit: adding).id("new") }
                    if entries.isEmpty, adding == nil { FilesNote(text: "此文件夹为空。") }
                    ForEach(entries, id: \.name) { entry in
                        ClassicFolderRow(files: files, entry: entry, path: FilesPath.join(root, entry.name), column: 1)
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                .contentShape(Rectangle())
                .contextMenu { FilesFolderMenu(files: files, folder: root) }
            }
            .frame(maxWidth: .infinity)
        }
    }
}
