import SwiftUI

// MARK: - Routes
//
// One case per sidebar destination, grouped into the sidebar sections:
// Overview, Library, Monitor, Workspace.

enum Route: String, Hashable, Identifiable, CaseIterable, Codable {
    // Overview
    case readout
    case assistant
    // Monitor
    case usage
    case live
    case sessions
    case tools
    case costs
    case ports
    // Workspace
    case repos
    case workGraph
    case repoPulse
    case diffs
    case snapshots
    case environment
    // Library
    case skills
    case agents
    case rules
    case commands
    case plugins
    case memory
    case hooks
    case instructions
    case favorites
    case collections
    case settings
    // Health
    case health

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readout: "Home"
        case .assistant: "Assistant"
        case .usage: "Usage"
        case .live: "Live"
        case .sessions: "Sessions"
        case .tools: "MCP Servers"
        case .costs: "Costs"
        case .ports: "Ports"
        case .repos: "Repos"
        case .workGraph: "Work Graph"
        case .repoPulse: "Repo Pulse"
        case .diffs: "Diffs"
        case .snapshots: "Snapshots"
        case .environment: "Environment"
        case .skills: "Skills"
        case .agents: "Agents"
        case .rules: "Rules"
        case .commands: "Commands"
        case .plugins: "Plugins"
        case .instructions: "Instructions"
        case .favorites: "Favorites"
        case .collections: "Collections"
        case .memory: "Memory"
        case .hooks: "Hooks"
        case .settings: "Settings"
        case .health: "Health"
        }
    }

    var icon: String {
        switch self {
        case .readout: "house"
        case .assistant: "bubble.left.and.bubble.right"
        case .usage: "gauge.with.dots.needle.67percent"
        case .live: "waveform.path.ecg"
        case .sessions: "clock"
        case .tools: "antenna.radiowaves.left.and.right"
        case .costs: "dollarsign.circle"
        case .ports: "point.3.connected.trianglepath.dotted"
        case .repos: "folder"
        case .workGraph: "chart.bar"
        case .repoPulse: "waveform.path"
        case .diffs: "doc.on.doc"
        case .snapshots: "camera"
        case .environment: "wrench.and.screwdriver"
        case .skills: "bolt"
        case .agents: "person.2"
        case .rules: "list.bullet.rectangle"
        case .commands: "terminal"
        case .plugins: "puzzlepiece.extension"
        case .instructions: "book.closed"
        case .favorites: "star"
        case .collections: "rectangle.stack"
        case .memory: "brain"
        case .hooks: "link"
        case .settings: "gearshape"
        case .health: "heart.text.square"
        }
    }

    /// Whether the window's "+" (New skill / agent / rule / command / collection)
    /// belongs on this destination. It only makes sense on the Library pages; on
    /// Sessions (including the embedded Replay), Usage, Home, Costs, etc. it is out of
    /// context, so the sidebar toolbar hides it there rather than showing a "+" that
    /// creates something unrelated to what the user is looking at.
    var allowsNewItem: Bool {
        switch self {
        case .skills, .agents, .rules, .commands, .plugins,
             .hooks, .memory, .instructions, .favorites, .collections, .tools:
            return true
        default:
            return false
        }
    }

    /// Keywords used by the ⌘K command palette for fuzzy matching.
    var searchKeywords: String {
        switch self {
        case .readout: "home dashboard overview"
        case .assistant: "chat ai claude ask"
        case .usage: "limits quota rate session weekly tokens subscription"
        case .sessions: "usage tokens stats history"
        case .costs: "spend money budget billing"
        case .ports: "localhost lsof servers listening"
        case .repos: "git github projects"
        case .workGraph: "chart graph analytics"
        case .tools: "mcp servers integrations"
        case .environment: "toolchain cli installed versions binaries path homebrew runtimes"
        default: title.lowercased()
        }
    }
}

// MARK: - Sidebar structure

struct SidebarSection: Identifiable {
    var id: String { title }
    let title: String
    let routes: [Route]
}

enum Sidebar {
    static let sections: [SidebarSection] = [
        SidebarSection(title: "Overview", routes: [.readout, .assistant]),
        SidebarSection(title: "Library", routes: [.skills, .agents, .rules, .commands, .tools, .plugins, .hooks, .memory, .instructions, .favorites, .collections]),
        SidebarSection(title: "Monitor", routes: [.usage, .live, .sessions, .costs, .ports]),
        SidebarSection(title: "Workspace", routes: [.repos, .workGraph, .diffs, .snapshots, .environment, .health]),
    ]
}
