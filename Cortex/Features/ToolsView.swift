import SwiftUI

// MARK: - ToolsView
//
// The "Tools" monitor page, centered on MCP servers. It is an in-page split: a
// header (whole-stack summary strip + searchable count) and a NATIVE selectable
// list of MCP servers on the LEFT, and the selected server's connection detail on
// the RIGHT (an empty state when nothing is selected). The detail pane is a
// document viewer: a scrollable info layout with a metadata bar pinned to the
// bottom.

struct ToolsView: View {
    @Environment(AppModel.self) private var model

    // Search query filtering the MCP server list by name (and endpoint/scope)
    @State private var query = ""
    // Scope filter (nil = all): "Global" / "User" / "Project".
    @State private var scope: String?
    // The id (server name) of the selected server, bound to the split layout
    @State private var selectedID: MCPServer.ID?

    // Distinct MCP scopes for the filter chips, in a sensible order (present ones only).
    private var scopes: [String] {
        let present = Set(model.config.mcpServers.map { $0.scope.capitalized })
        let ordered = ["Global", "User", "Project"]
        return ordered.filter(present.contains) + present.subtracting(ordered).sorted()
    }

    // Servers filtered by the live search query (name, transport, command/url) AND
    // scope, then ordered by the app-wide library sort. MCP servers carry no modified
    // date or file size, so .sorted(by:) falls back to A-Z by name for every order.
    private var filteredServers: [MCPServer] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.config.mcpServers.filter { server in
            (scope == nil || server.scope.capitalized == scope)
                && (trimmed.isEmpty
                    || [server.name, server.transport, server.scope,
                        server.command ?? "", server.url ?? ""]
                        .contains { $0.localizedCaseInsensitiveContains(trimmed) })
        }.sorted(by: model.librarySort)
    }

    // Two-way binding to the app-wide library sort (persisted on the model).
    private var sortBinding: Binding<LibrarySort> {
        Binding(get: { model.librarySort }, set: { model.librarySort = $0 })
    }

    var body: some View {
        // In-page master/detail: list + summary on the left, detail on the right
        SplitDetailView(
            items: filteredServers,
            selectedID: $selectedID,
            emptyIcon: "server.rack",
            emptyTitle: "No MCP server selected",
            emptyMessage: "Pick a server on the left to see its transport, scope, tools, and connection details."
        ) {
            // List header: page title + count, search + scope + sort filter
            ToolsListHeader(
                serverCount: filteredServers.count,
                query: $query,
                scope: $scope,
                scopes: scopes,
                sort: sortBinding
            )
        } row: { server, _ in
            // PLAIN row content: the native List draws the system selection highlight
            MCPServerRow(server: server)
        } detail: { server in
            // Per-server connection detail rendered directly in the right pane
            MCPServerDetail(server: server)
                // Re-identify so the scroll position resets when the selection changes.
                .id(server.id)
        }
        // When the search filters out the current selection, fall back to the first match.
        .onChange(of: query) { _, _ in
            if let id = selectedID, !filteredServers.contains(where: { $0.id == id }) {
                selectedID = filteredServers.first?.id
            }
        }
        .onChange(of: scope) { _, _ in
            if let id = selectedID, !filteredServers.contains(where: { $0.id == id }) {
                selectedID = filteredServers.first?.id
            }
        }
        .background(Theme.canvas)
    }
}

// MARK: - Tools list header
//
// The upper area of the left pane: a "Tools" title with the live server count and a
// search field that filters the MCP server list below. (The whole-stack summary now
// lives on Home, so this page stays focused on MCP servers.)

private struct ToolsListHeader: View {
    let serverCount: Int
    @Binding var query: String
    @Binding var scope: String?
    let scopes: [String]
    @Binding var sort: LibrarySort

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Page title (smaller; name also shows in the toolbar) + MCP server count
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Tools")
                    .font(.cortexTitle)
                    .foregroundStyle(Theme.textPrimary)
                Text("\(serverCount) \(serverCount == 1 ? "server" : "servers")")
                    .font(.cortexCaption)
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
            }

            // Shared search + scope filter (Global / User / Project) + sort.
            LibraryFilterBar(query: $query, placeholder: "Search MCP servers", scope: $scope, scopes: scopes, sort: $sort)
        }
    }
}

// MARK: - Tools search field
//
// A themed inline search field that filters the MCP server list. Lives in the
// list header (the split owns its panes, so there is no toolbar .searchable).

private struct ToolsSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)

            TextField("Search MCP servers", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)

            // Clear button, only when there is a query
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .linkCursor()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .fill(Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1)
        )
    }
}

// MARK: - MCP server row
//
// One PLAIN list row (no SelectableRow, no custom selection background) so the
// native List paints the system accent highlight: a leading server glyph, the
// server name over a transport caption, a spacer, and a small auth-warning icon
// when the server needs reauthentication.

private struct MCPServerRow: View {
    let server: MCPServer

    var body: some View {
        HStack(spacing: 11) {
            // Leading server glyph (grayscale chrome)
            Image(systemName: "server.rack")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22)

            // Name over a transport caption
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(MCPStyle.transportCaption(server))
                    .font(.cortexCaption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            // Auth-warning icon, only when the server needs reauthentication
            if server.needsAuth {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.warn)
            }
        }
        .padding(.vertical, 5)
    }
}

// MARK: - MCP server detail
//
// The right-pane connection detail for one server, rebuilt with STOCK native
// containers: a large native title (server name as .title.bold) with a transport
// subtitle, then a "Connection" GroupBox of LabeledContent rows (transport, scope,
// tools, needs auth), an endpoint GroupBox with the command / url in selectable
// monospaced text, a native auth-warning callout when needed, and an "About MCP"
// GroupBox with a transport-aware explanation.

private struct MCPServerDetail: View {
    @Environment(AppModel.self) private var model
    let server: MCPServer

    // The connection tint, keyed to the server's transport
    private var tint: Color { MCPStyle.transportTint(server.transport) }

    // Tool count phrasing: "n tools" when known, else "unknown"
    private var toolCountText: String {
        server.toolCount > 0 ? "\(server.toolCount) \(server.toolCount == 1 ? "tool" : "tools")" : "unknown"
    }

    // Command (stdio) vs URL (sse / http) shapes the endpoint section labels.
    private var isCommand: Bool { server.command != nil }
    private var endpointLabel: String { isCommand ? "Command" : "Endpoint URL" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Identity header: large native title + transport subtitle
                header

                // Connection facts as native LabeledContent rows
                connectionSection

                // Full command / url shown selectable in mono
                endpointSection

                // Auth warning, only when the server needs reauthentication
                if server.needsAuth {
                    authNotice
                }

                // Short, transport-aware explanation of how the server connects
                aboutSection
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }

    // MARK: Header (large native title + transport subtitle)

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Server name as the large native document title.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(server.name)
                    .font(.title.bold())
                    .foregroundStyle(.primary)
                if server.needsAuth {
                    // Native badge flagging the reauthentication state.
                    Text("Needs auth")
                        .font(.caption)
                        .foregroundStyle(Theme.warn)
                }
                Spacer(minLength: 0)
                // Favorite toggle (favorited MCP servers appear on the Favorites page).
                FavoriteToggle(id: server.id)
            }
            Text("MCP server (\(server.transport.lowercased()))")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Connection section (native GroupBox + LabeledContent rows)

    private var connectionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Transport") {
                    // Native badge for the transport kind (grayscale chrome label).
                    Text(server.transport.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Scope", value: server.scope.capitalized)

                LabeledContent("Tools") {
                    // Tinted when the tool count is known, else native tertiary style.
                    if server.toolCount > 0 {
                        Text(toolCountText)
                            .foregroundStyle(Theme.green)
                    } else {
                        Text(toolCountText)
                            .foregroundStyle(.tertiary)
                    }
                }

                LabeledContent("Needs auth") {
                    Text(server.needsAuth ? "Yes" : "No")
                        .foregroundStyle(server.needsAuth ? Theme.warn : Theme.green)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("Connection", systemImage: "bolt.horizontal")
                .font(.headline)
        }
    }

    // MARK: Endpoint section (command / url in selectable mono)

    private var endpointSection: some View {
        GroupBox {
            Text(MCPStyle.endpoint(server))
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } label: {
            Label(endpointLabel, systemImage: isCommand ? "terminal" : "link")
                .font(.headline)
        }
    }

    // MARK: Auth notice (native callout)

    private var authNotice: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warn)
                Text("This server needs authentication. Run its connect or login flow in Claude Code before its tools become available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    // MARK: About section (transport-aware explanation)

    private var aboutSection: some View {
        GroupBox {
            Text(MCPStyle.note(for: server))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } label: {
            Label("About MCP", systemImage: "info.circle")
                .font(.headline)
        }
    }
}

// MARK: - MCP presentation helpers
//
// Shared formatting and color logic so the row, pills, metadata bar, and detail
// panel stay in sync: transport tint + glyph, the row caption, the displayed
// endpoint string, and the explanatory note.

private enum MCPStyle {
    /// Color a transport by kind: local stdio, server-sent events, plain HTTP.
    static func transportTint(_ transport: String) -> Color {
        switch transport.lowercased() {
        case "stdio": Theme.green
        case "sse": Theme.purple
        case "http": Theme.blue
        default: Theme.textSecondary
        }
    }

    /// The row subtitle: transport plus the scope, e.g. "stdio - user".
    static func transportCaption(_ server: MCPServer) -> String {
        "\(server.transport.lowercased()) - \(server.scope.lowercased())"
    }

    /// The endpoint to display: the launch command for stdio, else the URL.
    static func endpoint(_ server: MCPServer) -> String {
        server.command ?? server.url ?? "unknown"
    }

    /// A short, transport-aware explanation shown in the detail panel.
    static func note(for server: MCPServer) -> String {
        switch server.transport.lowercased() {
        case "stdio":
            return "Connects over stdio: Claude Code launches the command above as a local subprocess and exchanges JSON-RPC over its standard streams. Tool count shows as unknown until the server has been started and its tools listed."
        case "sse":
            return "Connects over Server-Sent Events to the URL above. Tool count shows as unknown until the server has been reached and its tools listed."
        default:
            return "Connects over HTTP to the URL above. Tool count shows as unknown until the server has been reached and its tools listed."
        }
    }
}
