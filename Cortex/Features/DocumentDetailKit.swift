import SwiftUI
import AppKit

// MARK: - DocumentDetailKit
//
// Shared chrome for the library document detail pane (Skills / Agents / Commands /
// Rules via ConfigBrowser): the glass-pill mode toggle (preview / edit), the floating
// Save/Cancel bar shown while editing, the responsive bottom status footer, and the
// file operations behind Save / Delete / Make Global. Kept in one file so every
// browser shares identical sizing and behavior.

// MARK: - File operations
//
// Read-write actions on the backing file. Destructive ops use the Trash (reversible)
// rather than unlink, so a mis-click is always recoverable.

enum ConfigFileOps {
    /// Write edited markdown back to the item's file, atomically.
    static func save(_ item: ConfigItem, content: String) throws {
        try content.write(toFile: item.path, atomically: true, encoding: .utf8)
    }

    /// Move the item to the Trash. A skill is a folder (skills/<name>/SKILL.md), so we
    /// trash the whole skill directory; single-file items (agents/commands/rules) trash
    /// just the file. Returns the original path and the resulting Trash URL so the delete
    /// is undoable (see `restore`).
    @discardableResult
    static func trash(_ item: ConfigItem) throws -> (original: String, trashed: URL) {
        let target = item.kind == .skill
            ? (item.path as NSString).deletingLastPathComponent
            : item.path
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: target), resultingItemURL: &resulting)
        return (target, (resulting as URL?) ?? URL(fileURLWithPath: target))
    }

    /// Undo a `trash`: move the item back from the Trash to where it lived. Used by the
    /// "Undo" action in the post-delete toast.
    static func restore(from trashed: URL, to original: String) throws {
        try FileManager.default.moveItem(at: trashed, to: URL(fileURLWithPath: original))
    }

    /// Whether "Make Global" applies: a project-scoped skill that isn't already global.
    static func canMakeGlobal(_ item: ConfigItem) -> Bool {
        item.kind == .skill && !item.isGlobal
    }

    /// Copy a project skill's folder into ~/.claude/skills/<name>/. If a global copy
    /// already exists it's moved to the Trash first (so the replace is reversible).
    static func makeGlobal(_ item: ConfigItem) throws {
        guard canMakeGlobal(item) else { return }
        let fm = FileManager.default
        let skillDir = (item.path as NSString).deletingLastPathComponent   // .../skills/<name>
        let name = (skillDir as NSString).lastPathComponent
        let globalSkills = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/skills")
        try fm.createDirectory(atPath: globalSkills, withIntermediateDirectories: true)
        let dest = (globalSkills as NSString).appendingPathComponent(name)
        if fm.fileExists(atPath: dest) {
            try fm.trashItem(at: URL(fileURLWithPath: dest), resultingItemURL: nil)
        }
        try fm.copyItem(atPath: skillDir, toPath: dest)
    }
}

// MARK: - Arrow cursor over the editor

extension View {
    /// Force the regular arrow cursor while the pointer is over this view, overriding an
    /// underlying NSTextView's I-beam. `onContinuousHover` fires on every mouse move so
    /// `NSCursor.arrow.set()` re-wins after the text view re-asserts its cursor (a
    /// `.pointerStyle`, or a per-button modifier with gaps between buttons, leaves the
    /// I-beam flickering through). Apply to the whole control cluster, not each button.
    func arrowCursorWhileHovering() -> some View {
        onContinuousHover { phase in
            if case .active = phase { NSCursor.arrow.set() }
        }
    }
}

// MARK: - Document mode toggle (preview / edit)
//
// The LEFT glass pill: an eye (rendered markdown preview, the default) and a pencil
// (enter the in-app editor). Sized to MATCH the actions pill exactly (30x26 buttons,
// 4pt padding) so the two groups are the same size across the app.

struct DocumentModeToggle: View {
    var isEditing: Bool
    var showPreview: () -> Void
    var beginEdit: () -> Void

    // Shared namespace so the selected-segment "thumb" slides between eye and pencil
    // (the same matchedGeometryEffect technique as the home segmented control).
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 2) {
            // Preview (eye): active when not editing.
            modeButton(icon: "eye", active: !isEditing, help: "Preview", action: showPreview)
            // Edit (pencil): active while editing.
            modeButton(icon: "pencil", active: isEditing, help: "Edit", action: beginEdit)
        }
        .padding(4)
        .glassPill()
    }

    private func modeButton(icon: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.28)) { action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 30, height: 26)
                .background {
                    // The selected segment carries the thumb; the shared
                    // matchedGeometryEffect id slides it between segments. Apple's
                    // segmented-control look: soft raised capsule + hairline + shadow.
                    if active {
                        Capsule()
                            .fill(Theme.cardRaised)
                            .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 1))
                            .shadow(color: .black.opacity(0.10), radius: 1, y: 0.5)
                            .matchedGeometryEffect(id: "modeThumb", in: thumb)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Document source toggle (preview / source)
//
// The read-only counterpart to DocumentModeToggle for documents with no editor (e.g.
// Instructions, Memory, Plugins): an eye (rendered markdown preview) and a code glyph
// (raw source). Same glass-pill chrome + sliding thumb so every detail pane's toolbar
// matches the editable browsers exactly.

struct DocumentSourceToggle: View {
    @Binding var showSource: Bool

    // Shared namespace so the selected-segment "thumb" slides between eye and code.
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 2) {
            // Preview (eye): active when showing the rendered markdown.
            modeButton(icon: "eye", active: !showSource, help: "Preview") { showSource = false }
            // Source (code): active when showing the raw markdown source.
            modeButton(
                icon: "chevron.left.forwardslash.chevron.right",
                active: showSource,
                help: "Source"
            ) { showSource = true }
        }
        .padding(4)
        .glassPill()
    }

    private func modeButton(icon: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.28)) { action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 30, height: 26)
                .background {
                    if active {
                        Capsule()
                            .fill(Theme.cardRaised)
                            .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 1))
                            .shadow(color: .black.opacity(0.10), radius: 1, y: 0.5)
                            .matchedGeometryEffect(id: "sourceThumb", in: thumb)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Floating Save / Cancel bar
//
// Shown bottom-trailing while editing. Save commits to disk (⌘S), Cancel discards
// (Esc). A glass pill so it floats over the editor like the rest of the toolbar.

struct EditSaveCancelBar: View {
    var isSaving: Bool
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 12).frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .disabled(isSaving)

            Button(action: onSave) {
                HStack(spacing: 6) {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    }
                    Text("Save")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 28)
                .background(Capsule().fill(Theme.accent))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(isSaving)
        }
        .padding(5)
        .glassPill()
        // One cursor region over the whole bar (no per-button gaps), keeping the regular
        // arrow cursor instead of the editor's I-beam bleeding through.
        .arrowCursorWhileHovering()
    }
}

// MARK: - Document footer (status bar)
//
// The pinned bottom status bar for the read-only document view (matches the reference
// screenshot): a kind badge, the source-tool glyph, the file path, size, a scope glyph,
// and the last-edited time. Responsive: when the pane is narrow the badge label and the
// inner separators are dropped and the timestamp becomes a short date instead of a long
// relative phrase.

struct DocumentFooter: View {
    @Environment(AppModel.self) private var model

    // Explicit fields so the footer works for ANY document, not just ConfigItems
    // (Memory files carry a MemoryItem, Plugins/Instructions a ConfigItem).
    let kindLabel: String
    let path: String
    let sizeBytes: Int
    let modified: Date

    @State private var compact = false

    /// Convenience init for a library ConfigItem (Skills / Agents / Commands / Rules /
    /// Plugins / Instructions).
    init(item: ConfigItem) {
        self.kindLabel = item.kind.singular.uppercased()
        self.path = item.path
        self.sizeBytes = item.fileSize
        self.modified = item.modified
    }

    /// General init for non-ConfigItem documents (e.g. Memory files).
    init(kindLabel: String, path: String, sizeBytes: Int, modified: Date) {
        self.kindLabel = kindLabel
        self.path = path
        self.sizeBytes = sizeBytes
        self.modified = modified
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            // Kind badge (text only).
            Text(kindLabel)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Theme.hairFill))

            FooterSep(visible: true)

            // File path: a breadcrumb that copies the full path to the clipboard on click.
            Button(action: copyPath) {
                Text(abbreviatePath(path))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .linkCursor()
            .help("Click to copy path")

            FooterSep(visible: !compact)

            // File size
            Text(sizeString(sizeBytes))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .layoutPriority(1)

            Spacer(minLength: 8)

            // Last edited: long relative phrase normally, a short date when narrow.
            // Hover shows the exact updated + created timestamps.
            Text(lastEdited)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .layoutPriority(1)
                .help(dateTooltip)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.canvas)
        .overlay(alignment: .top) { Divider().overlay(Theme.stroke) }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { compact = $0 < 540 }
    }

    private var lastEdited: String {
        compact
            ? modified.formatted(date: .abbreviated, time: .omitted)
            : Self.relative.localizedString(for: modified, relativeTo: Date())
    }

    // Tooltip: exact last-updated + created timestamps.
    private var dateTooltip: String {
        var lines = "Last updated: \(modified.formatted(date: .abbreviated, time: .shortened))"
        if let created = creationDate {
            lines += "\nCreated: \(created.formatted(date: .abbreviated, time: .shortened))"
        }
        return lines
    }

    private var creationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        model.showToast("Path copied")
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func sizeString(_ bytes: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useBytes, .useKB, .useMB]
        return f.string(fromByteCount: Int64(bytes))
    }
}

/// A faint vertical separator used between footer fields (hidden when compact).
private struct FooterSep: View {
    var visible: Bool
    var body: some View {
        Rectangle()
            .fill(Theme.stroke)
            .frame(width: 1, height: 12)
            .opacity(visible ? 1 : 0)
            .frame(width: visible ? 1 : 0)
    }
}
