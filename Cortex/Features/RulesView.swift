import SwiftUI

// MARK: - RulesView
//
// Browses every rule discovered by ConfigScanner (markdown rule files under the
// tools' rules directories). It reuses the shared ConfigBrowser defined in
// SkillsView.swift, so the in-page split layout (a native selectable list on the
// left, a document-style markdown detail pane on the right), search, and metadata
// bar are identical to Skills, parameterized by the .rule ConfigKind and a green
// tint to distinguish it from Skills' yellow and Agents' blue.
//
// The native library features added to ConfigBrowser are inherited here verbatim:
// each row shows a favorite star + a .contextMenu (LibraryItemMenu), and the detail
// pane carries the StarButton, the ellipsis library Menu, the markdown preview/source
// toggle, and the shared "New Collection..." native alert. Those helpers (StarButton,
// LibraryItemMenu, NativeDocumentDetail) live in SkillsView.swift.

struct RulesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ConfigBrowser(
            kind: .rule,
            tint: Color.secondary,
            emptyMessage: "Add rules under your tools' rules directories to see them here.",
            items: model.config.rules
        )
    }
}
