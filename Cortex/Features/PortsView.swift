import SwiftUI
import AppKit

// MARK: - PortsView
//
// Live listing of every listening TCP port (model.ports.ports), rebuilt with STOCK
// native containers. Ports render in a native `List` of columnar rows grouped into
// Sections: a "Dev servers" Section for the common 3000-3010 range and an "Other
// listeners" Section for everything else. The list is searchable with the native
// `.searchable` modifier and carries a toolbar refresh button that re-runs the
// lsof scan. Each row exposes the port, owning process, pid, address family, user,
// optional project, and native Open / Copy buttons for http-reachable ports.

struct PortsView: View {
    @Environment(AppModel.self) private var model

    // Search query applied to port / process / project / user.
    @State private var query = ""
    // ⌘F focuses the search field (via model.focusSearchToken).
    @FocusState private var searchFocused: Bool

    // Common local dev-server range surfaced under its own header.
    private let devRange = 3000...3010

    var body: some View {
        content
            .navigationTitle("Ports")
            .navigationSubtitle(subtitleText)
            .searchable(text: $query, prompt: "Search ports")
            .searchFocused($searchFocused)
            .onChange(of: model.focusSearchToken) { _, _ in searchFocused = true }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.ports.load() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.ports.isLoading)
                }
            }
    }

    // MARK: Subtitle (count + last scan time)

    private var subtitleText: String {
        let count = model.ports.ports.count
        let portWord = count == 1 ? "port" : "ports"
        if let scan = model.ports.lastScan {
            return "\(count) listening \(portWord) \u{00B7} scanned \(Fmt.relative(scan))"
        }
        return "\(count) listening \(portWord)"
    }

    // MARK: Body content (loading / empty / grouped native List)

    @ViewBuilder
    private var content: some View {
        if model.ports.ports.isEmpty && model.ports.isLoading {
            // Native loading state.
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Scanning Listening Ports")
                    .font(.headline)
                Text("Running lsof to map ports to their owning processes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.ports.ports.isEmpty {
            ContentUnavailableView(
                "No Listening Ports",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("Nothing is bound to a TCP port right now. Start a dev server and refresh.")
            )
        } else if filtered.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            // Grouped native List: dev servers, then everything else.
            List {
                if !devServers.isEmpty {
                    Section {
                        ForEach(devServers) { PortRow(port: $0) }
                    } header: {
                        Label("Dev Servers (\(devServers.count))", systemImage: "bolt.horizontal")
                    }
                }
                if !others.isEmpty {
                    Section {
                        ForEach(others) { PortRow(port: $0) }
                    } header: {
                        Label("Other Listeners (\(others.count))", systemImage: "network")
                    }
                }
            }
        }
    }

    // MARK: Filtering + grouping

    /// Ports matching the search query, kept sorted by port number.
    private var filtered: [PortInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = model.ports.ports
        guard !trimmed.isEmpty else { return base }
        return base.filter { port in
            String(port.port).contains(trimmed)
                || port.processName.lowercased().contains(trimmed)
                || port.command.lowercased().contains(trimmed)
                || port.user.lowercased().contains(trimmed)
                || (port.project?.lowercased().contains(trimmed) ?? false)
                || port.family.lowercased().contains(trimmed)
        }
    }

    private var devServers: [PortInfo] { filtered.filter { devRange.contains($0.port) } }
    private var others: [PortInfo] { filtered.filter { !devRange.contains($0.port) } }
}

// MARK: - Port row
//
// One listening port as a native columnar List row: a bold mono port number, the
// process + command, native metadata badges (family, pid, user, optional project),
// and native Open / Copy buttons for http-reachable ports.

private struct PortRow: View {
    let port: PortInfo
    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Port number column (bold mono).
            Text("\(port.port)")
                .font(.title3.monospacedDigit().weight(.bold))
                .frame(width: 60, alignment: .leading)

            // Process + command column.
            VStack(alignment: .leading, spacing: 2) {
                Text(port.processName)
                    .font(.body)
                    .lineLimit(1)
                Text(port.command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Metadata column: family, pid, user, project.
            PortMetaColumn(port: port)

            // Quick actions for http-reachable ports.
            if let url = port.url {
                HStack(spacing: 6) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Open", systemImage: "safari")
                    }
                    .linkCursor()
                    Button {
                        copyLocalhost()
                    } label: {
                        Label(didCopy ? "Copied" : "Copy",
                              systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .linkCursor()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }

    // Copy "localhost:<port>" to the pasteboard, with a brief confirmation.
    private func copyLocalhost() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("localhost:\(port.port)", forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) { didCopy = true }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.easeInOut(duration: 0.2)) { didCopy = false }
        }
    }
}

// MARK: - Metadata column
//
// The family / pid / user / project descriptors for a port, kept on one quiet line
// in native secondary text so the row reads like a stock table cell.

private struct PortMetaColumn: View {
    let port: PortInfo

    var body: some View {
        HStack(spacing: 10) {
            // Address family.
            Label(port.family, systemImage: port.family == "IPv6" ? "6.circle" : "4.circle")
                .foregroundStyle(.secondary)

            // Process id.
            Text("pid \(port.pid)")
                .foregroundStyle(.secondary)

            // Owning user.
            Text(port.user)
                .foregroundStyle(.secondary)

            // Resolved project, when known.
            if let project = port.project, !project.isEmpty {
                Label(project, systemImage: "folder")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
    }
}
