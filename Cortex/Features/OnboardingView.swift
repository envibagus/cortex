import SwiftUI
import AppKit

// MARK: - OnboardingView
//
// First-run welcome, shown until the user finishes setup. Explains what Cortex is,
// reassures that everything is read locally and read-only, and lets the user pick
// the folders to scan for local git repositories and project-level AI config.
// Choices are committed to the model and a workspace rescan kicks off on "Get
// Started". Native semantic colors + the app design system throughout.

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    // Draft scan roots assembled here, committed to the model on completion so a
    // cancelled session leaves the persisted roots untouched.
    @State private var draftRoots: [String] = []

    var body: some View {
        // A plain NavigationStack (no sidebar) gives the onboarding its own toolbar
        // with just the "Cortex" title on the left, independent of the app's shell.
        NavigationStack {
            ZStack {
                Theme.canvas.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 28) {
                        welcomeHeader
                        scanRootsCard
                        privacyNote
                        primaryActions
                    }
                    .frame(maxWidth: 560)        // cap the content column width
                    .frame(maxWidth: .infinity) // and center it in the window
                    .padding(.horizontal, 40)
                    .padding(.vertical, 56)
                }
            }
            .navigationTitle("Cortex")
        }
        .onAppear {
            draftRoots = model.scanRoots
        }
    }

    // MARK: - Welcome header
    //
    // The real app icon, app name, and a one-line description of what Cortex does.

    private var welcomeHeader: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 76, height: 76)
            Text("Welcome to Cortex")
                .font(.cortexTitle)
                .foregroundStyle(Theme.textPrimary)
            Text("Your control center for the local AI stack. Cortex turns your on-device Claude Code sessions, costs, repos, skills, agents, and MCP servers into live dashboards.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Scan roots card
    //
    // The folders Cortex walks for local git repositories and project AI config.
    // Add folders via a native open panel; remove with the trailing minus button.

    private var scanRootsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(icon: "folder", title: "Scan Roots", tint: Theme.accent)

                Text("Folders Cortex scans for your git repositories.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if draftRoots.isEmpty {
                    Text("None added yet. You can also add them later in Settings.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    VStack(spacing: 0) {
                        ForEach(draftRoots, id: \.self) { root in
                            scanRootRow(root)
                            if root != draftRoots.last { Divider() }
                        }
                    }
                }

                Button(action: addFolders) {
                    Label("Add Folder\u{2026}", systemImage: "plus")
                }
                .controlSize(.large)
                .linkCursor()
            }
        }
    }

    // One folder row: glyph, prettified path, and a remove button.
    private func scanRootRow(_ root: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(Theme.accent)
            Text(root.tildeAbbreviated)
                .font(.body.monospaced())
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button {
                draftRoots.removeAll { $0 == root }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .linkCursor()
            .help("Remove this folder")
        }
        .padding(.vertical, 9)
    }

    // MARK: - Privacy note
    //
    // Honest, one-line reassurance about read-only local access.

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(Theme.textSecondary)
            Text("Everything is read locally and read-only. Cortex never reads credentials or tokens, and never sends your data anywhere.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Primary actions
    //
    // Skip (secondary) finishes onboarding with no folders; Get Started (primary) is
    // enabled once at least one folder is added. Both load the workspace and dismiss.

    private var primaryActions: some View {
        HStack(spacing: 12) {
            Spacer()
            Button("Skip for Now", action: completeOnboarding)
                .controlSize(.large)
                .linkCursor()
            Button("Get Started", action: completeOnboarding)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .linkCursor()
                .disabled(draftRoots.isEmpty)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Actions

    /// Open a native directory picker and append any newly chosen folders.
    private func addFolders() {
        let chosen = NSOpenPanel.chooseDirectories(
            message: "Choose folders that contain your git repositories.")
        for path in chosen where !draftRoots.contains(path) {
            draftRoots.append(path)
        }
    }

    /// Persist the chosen roots, mark onboarding done, load the workspace.
    private func completeOnboarding() {
        Task { await model.completeOnboarding(roots: draftRoots) }
    }
}
