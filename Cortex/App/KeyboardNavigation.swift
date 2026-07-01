import SwiftUI

// MARK: - Keyboard navigation: focused selection actions
//
// The list pane of every split page publishes a `PageActions` bundle via
// `.focusedValue` WHILE IT HAS KEYBOARD FOCUS. The Edit-menu commands (⌘E / ⌘C / ⌫)
// read it and are DISABLED whenever it is absent - i.e. when a text field or the
// detail's selectable text is focused instead - so those keys fall through to the
// system Copy / character delete / no-op. That gating is what keeps ⌘C and Delete safe
// to bind globally without clobbering text editing.

struct PageActions {
    /// Edit the selected item (nil when the page has no in-app editor for it).
    var edit: (() -> Void)?
    /// Copy the selected item's path (or endpoint) to the clipboard.
    var copyPath: (() -> Void)?
    /// Delete the selected item (raises the page's own confirmation).
    var delete: (() -> Void)?
}

private struct PageActionsKey: FocusedValueKey {
    typealias Value = PageActions
}

extension FocusedValues {
    var pageActions: PageActions? {
        get { self[PageActionsKey.self] }
        set { self[PageActionsKey.self] = newValue }
    }
}

extension View {
    /// Publish the focused list selection's actions to the menu commands, but only while
    /// this view (the focused list) is in the key window's focus chain. Passing nil
    /// removes the value, so the commands disable and their keys fall through.
    @ViewBuilder
    func publishPageActions(_ actions: PageActions?) -> some View {
        if let actions {
            focusedValue(\.pageActions, actions)
        } else {
            self
        }
    }
}

// MARK: - Selection commands (Edit menu)
//
// ⌘E edit, ⌘C copy path, and ⌫ delete, all gated on the focused `PageActions`. When no
// list is focused the value is nil, every button disables, and macOS lets the shortcut
// fall through to the responder chain (so ⌘C still copies selected text, ⌫ still
// deletes a character while typing, and so on).

struct SelectionCommands: Commands {
    @FocusedValue(\.pageActions) private var actions

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Edit Item") { actions?.edit?() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(actions?.edit == nil)
            Button("Copy Path") { actions?.copyPath?() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(actions?.copyPath == nil)
            Button("Delete Item") { actions?.delete?() }
                .keyboardShortcut(.delete)
                .disabled(actions?.delete == nil)
        }
    }
}
