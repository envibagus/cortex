import SwiftUI

// MARK: - AgentsView
//
// Browses every agent discovered by ConfigScanner (~/.claude/agents). It reuses
// the shared ConfigBrowser defined in SkillsView.swift, so the in-page split layout
// (a native selectable list on the left, a document-style markdown detail pane on the
// right), search, and metadata bar are identical to Skills, parameterized by the
// .agent ConfigKind and a blue tint to distinguish it from Skills' yellow.
//
// The native library features added to ConfigBrowser are inherited here verbatim:
// each row shows a favorite star + a .contextMenu (LibraryItemMenu), and the detail
// pane carries the StarButton, the ellipsis library Menu, the markdown preview/source
// toggle, and the shared "New Collection..." native alert. Those helpers (StarButton,
// LibraryItemMenu, NativeDocumentDetail) live in SkillsView.swift.

struct AgentsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ConfigBrowser(
            kind: .agent,
            tint: Color.secondary,
            emptyMessage: "Add agents under ~/.claude/agents to see them here.",
            items: model.config.agents
        )
    }
}
