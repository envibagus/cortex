import SwiftUI

// MARK: - AssistantView
//
// A polished chat surface backed by `model.chat` (ChatService). The assistant is
// seeded with a live snapshot of the whole AI stack, so it can answer questions
// about sessions, costs, skills, agents, MCP servers, hooks, memory, repos, and
// ports. User turns are right-aligned in a Claude-tinted bubble; assistant turns
// are left-aligned and rendered as markdown.

struct AssistantView: View {
    @Environment(AppModel.self) private var model

    // Draft input bound to the bottom composer.
    @State private var draft: String = ""
    // Whether the conversation-history popover is open (anchored on the header button).
    @State private var showHistory = false
    // Focus for the composer so Enter submits and the field can be re-focused.
    @FocusState private var composerFocused: Bool
    // Persisted model + mode choices, shared with ChatService via the same keys.
    @AppStorage("assistantModel") private var assistantModelRaw = ChatModel.sonnet.rawValue
    @AppStorage("assistantMode") private var assistantModeRaw = ChatMode.readOnly.rawValue

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            // Header: explains the assistant's scope + New Chat action.
            assistantHeader

            Divider().overlay(Theme.stroke)

            // Body: either the unavailable empty state or the live conversation.
            if !model.chat.isAvailable {
                unavailableState
            } else {
                conversation
                composer
            }
        }
        .background(Theme.canvas)
    }

    // MARK: - Header

    private var assistantHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            // Just the page title (no scope line - the empty-state ConversationIntro
            // already states the assistant's reach, so repeating it here was redundant).
            Text("Assistant")
                .font(.cortexTitle)
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 12)

            // History (reopen a past chat) then New Chat (clears the transcript). Wrapped
            // in a glass group so the two Liquid Glass pills render together and blend,
            // matching the app's other glass controls (refresh, scope/sort pills).
            LiquidGlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    historyButton
                    newChatButton
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(Theme.canvas)
    }

    // History button: opens a popover of saved past conversations to reopen or delete.
    private var historyButton: some View {
        Button {
            showHistory = true
        } label: {
            glassPillLabel(icon: "clock.arrow.circlepath", title: "History")
        }
        .buttonStyle(.plain)
        .glassPill()
        .disabled(model.chat.history.isEmpty || model.chat.isResponding)
        .help("Reopen a past conversation")
        .popover(isPresented: $showHistory, arrowEdge: .bottom) {
            ChatHistoryPopover { showHistory = false }
        }
    }

    private var newChatButton: some View {
        Button {
            model.chat.reset()
            draft = ""
            composerFocused = true
        } label: {
            glassPillLabel(icon: "square.and.pencil", title: "New Chat")
        }
        .buttonStyle(.plain)
        .glassPill()
        .disabled(model.chat.isResponding || (model.chat.messages.isEmpty && model.chat.lastError == nil))
        .help("Start a new conversation")
    }

    // Shared label for the header glass pills: icon + title, padded to a capsule shape
    // (the `.glassPill()` modifier supplies the material/glass capsule background).
    private func glassPillLabel(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .contentShape(Capsule())
    }

    // MARK: - Conversation list

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if model.chat.messages.isEmpty {
                        // First-run prompt suggestions.
                        ConversationIntro(userName: model.userName, onSelect: sendPrompt)
                            .padding(.top, 8)
                    }

                    // Message bubbles.
                    ForEach(model.chat.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    // Animated thinking row while a turn is in flight, but only until the
                    // first streamed token lands (after that the live bubble shows the
                    // text). It surfaces the current activity ("Reading files…") so a long
                    // turn shows progress, not a blank wait.
                    if model.chat.isResponding, (model.chat.messages.last?.text.isEmpty ?? true) {
                        ThinkingRow(activity: model.chat.streamingActivity)
                            .id(Self.thinkingAnchor)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            // Auto-scroll to the newest content whenever it changes.
            .onChange(of: model.chat.messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: model.chat.isResponding) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: model.chat.messages.last?.text) { _, _ in
                scrollToBottom(proxy)
            }
            .onAppear { scrollToBottom(proxy, animated: false) }
        }
        .frame(maxHeight: .infinity)
    }

    // Scroll to the live edge of the conversation. While streaming, the bottom is the
    // growing assistant bubble; only before the first token is the thinking row the edge.
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let showingThinking = model.chat.isResponding && (model.chat.messages.last?.text.isEmpty ?? true)
        let target: AnyHashable = showingThinking
            ? AnyHashable(Self.thinkingAnchor)
            : (model.chat.messages.last?.id).map { AnyHashable($0) } ?? AnyHashable(Self.thinkingAnchor)
        let scroll = { proxy.scrollTo(target, anchor: .bottom) }
        if animated {
            withAnimation(.easeOut(duration: 0.22)) { scroll() }
        } else {
            scroll()
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 0) {
            // Error banner sits directly above the input when set.
            if let error = model.chat.lastError {
                ErrorBanner(message: error)
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
            }

            VStack(spacing: 10) {
                // Input box on top, with the submit control INSIDE it (trailing).
                inputField

                // Controls row: mode pill (left) + model picker (right).
                HStack(spacing: 10) {
                    modePicker
                    Spacer(minLength: 8)
                    modelPicker
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .background(
            Theme.canvas
                .overlay(alignment: .top) { Divider().overlay(Theme.stroke) }
        )
    }

    // The input box: a growing multiline field with the submit control INSIDE it at the
    // trailing bottom, so the composer reads as one unit (matches the target mockup).
    private var inputField: some View {
        // Center-aligned so a single line of text sits vertically centered against the
        // send button (it grows downward for multi-line input via the 1...8 lineLimit).
        HStack(alignment: .center, spacing: 8) {
            TextField("Ask about your stack…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.claude)
                .lineLimit(1...8)
                .focused($composerFocused)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onSubmit(submit)

            inlineSendButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(composerFocused ? Theme.claude.opacity(0.45) : Theme.stroke, lineWidth: 1)
        )
    }

    // Mode pill (left of the controls row): Read only (default) vs Allow edit.
    private var modePicker: some View {
        @Bindable var model = model
        return Menu {
            ForEach(ChatMode.allCases) { m in
                Button {
                    model.chat.mode = m
                    assistantModeRaw = m.rawValue
                } label: {
                    if m == model.chat.mode {
                        Label(m.label, systemImage: "checkmark")
                    } else {
                        Label(m.label, systemImage: m.icon)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.chat.mode.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(model.chat.mode.label)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(model.chat.mode == .allowEdit ? Theme.orange : Theme.textSecondary)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Read only just answers; Allow edit lets the assistant change files")
    }

    // Model picker: a compact menu showing the active model; picking one updates both
    // the live ChatService and the persisted preference.
    private var modelPicker: some View {
        @Bindable var model = model
        return Menu {
            ForEach(ChatModel.allCases) { m in
                Button {
                    model.chat.model = m
                    assistantModelRaw = m.rawValue
                } label: {
                    if m == model.chat.model {
                        Label("\(m.label) - \(m.blurb)", systemImage: "checkmark")
                    } else {
                        Text("\(m.label) - \(m.blurb)")
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkle")
                    .font(.system(size: 11, weight: .semibold))
                Text(model.chat.model.label)
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Model for this chat - Opus is the smartest")
    }

    // Submit control that lives INSIDE the input box (trailing). Stop glyph while a turn
    // is in flight, up-arrow otherwise.
    private var inlineSendButton: some View {
        Button(action: submit) {
            Image(systemName: model.chat.isResponding ? "stop.fill" : "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(canSend ? .white : Theme.textTertiary)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(canSend ? Theme.claude : Theme.cardRaised)
                )
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .help("Send (Return)")
    }

    // Send is allowed only when idle and there is trimmed text.
    private var canSend: Bool {
        !model.chat.isResponding &&
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Dispatch the current draft and clear the field.
    private func submit() {
        guard canSend else { return }
        let text = draft
        draft = ""
        Task { await model.chat.send(text) }
    }

    // Send a tapped suggestion immediately (when idle).
    private func sendPrompt(_ text: String) {
        guard !model.chat.isResponding else { return }
        draft = ""
        Task { await model.chat.send(text) }
    }

    // MARK: - Unavailable state

    private var unavailableState: some View {
        VStack {
            Spacer()
            CortexEmptyState(
                icon: "terminal",
                title: "Claude Code CLI required",
                message: "The Assistant talks to Claude through the `claude` command-line tool. Install Claude Code from https://claude.ai/download, make sure `claude` is on your PATH, then reopen Cortex."
            )
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }

    // Stable anchor id for the thinking row / scroll target.
    private static let thinkingAnchor = "cortex.assistant.thinking"
}

// MARK: - Chat history popover
//
// A compact list of saved past conversations (newest-first), reopened from the
// Assistant header's History button. Each row shows the derived title, when it was
// last touched, and its message count; tapping reopens it, the trailing trash deletes.

private struct ChatHistoryPopover: View {
    @Environment(AppModel.self) private var model
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("History")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Text("\(model.chat.history.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().overlay(Theme.stroke)

            if model.chat.history.isEmpty {
                Text("No past conversations yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 28)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.chat.history) { convo in
                            ChatHistoryRow(
                                convo: convo,
                                onOpen: { model.chat.openConversation(convo.id); dismiss() },
                                onDelete: { model.chat.deleteConversation(convo.id) }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 300)
    }
}

// One saved-conversation row: a chat glyph, the title over its time + message count,
// and a delete button that appears on hover.

private struct ChatHistoryRow: View {
    let convo: ChatConversation
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.claude)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(convo.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text("\(Fmt.relative(convo.updatedAt)) · \(convo.messages.count) msgs")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if hovering {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Delete this conversation")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .onHover { hovering = $0 }
    }
}

// MARK: - Conversation intro
//
// Friendly first-run state shown when the transcript is empty.

private struct ConversationIntro: View {
    let userName: String
    var onSelect: (String) -> Void = { _ in }

    // Starter prompts that hint at the assistant's reach across the stack.
    // Chip glyphs are chrome: outline + grayscale (.secondary).
    private let prompts: [(icon: String, tint: Color, text: String)] = [
        ("dollarsign.circle", Theme.textSecondary, "How much have I spent on Claude this month?"),
        ("bolt", Theme.textSecondary, "Which of my skills haven't I used lately?"),
        ("folder", Theme.textSecondary, "Summarize the state of my repos."),
        ("point.3.connected.trianglepath.dotted", Theme.textSecondary, "What's listening on my dev ports right now?"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Greeting + scope.
            VStack(alignment: .leading, spacing: 6) {
                Text("Hey, \(userName)")
                    .font(.cortexTitle)
                    .foregroundStyle(Theme.textPrimary)
                Text("Ask me anything about your local AI setup. I read your live sessions, costs, config, and repos.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }

            // Suggested prompts: clickable, each sized to its own text.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(prompts, id: \.text) { prompt in
                    PromptChip(icon: prompt.icon, tint: prompt.tint, text: prompt.text) {
                        onSelect(prompt.text)
                    }
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}

// A clickable suggestion chip that sends its prompt. Sized to fit its text (it does
// not stretch to fill the width), with a hover state for affordance.
private struct PromptChip: View {
    let icon: String
    let tint: Color
    let text: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(hovering ? Theme.cardRaised : Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(hovering ? Theme.claude.opacity(0.4) : Theme.stroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Message bubble
//
// User: right-aligned, Claude-tinted. Assistant: left-aligned, markdown text.

private struct MessageBubble: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    // The assistant reply is appended empty and filled once the response lands. While
    // it's still empty, render nothing here so no blank bubble shows under the
    // "Thinking with Claude" indicator (which already conveys loading).
    private var isEmptyAssistant: Bool {
        !isUser && message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if isEmptyAssistant {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 10) {
                if isUser {
                    Spacer(minLength: 60)
                    bubble
                } else {
                    assistantAvatar
                    bubble
                    Spacer(minLength: 60)
                }
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        }
    }

    // The text container, styled per role.
    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isUser {
                Text(message.text)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
            } else {
                // Full GitHub-flavored markdown (tables, lists, code) via the shared
                // renderer, so a table reply renders as a real table, not raw pipes.
                MarkdownText(markdown: message.text)

                // Navigation CTAs the assistant attached: tappable jumps into the app.
                if !message.actions.isEmpty {
                    actionButtons
                }
                // (The per-reply price label was removed at the user's request.)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(bubbleBackground)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(isUser ? Theme.claude.opacity(0.30) : Theme.stroke, lineWidth: 1)
        )
        // The bubble caps at 600pt; a user bubble hugs the RIGHT edge (top-right corner),
        // the assistant the left. Previously both were .leading, which left a short user
        // bubble stranded mid-window once the spacer pushed the wide frame right.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 600, alignment: isUser ? .trailing : .leading)
    }

    // Assistant-attached navigation CTAs, wrapped so several fit narrow bubbles. Each
    // button switches the route (and pre-applies any search/scope) via the app model.
    private var actionButtons: some View {
        FlowLayout(spacing: 8) {
            ForEach(message.actions) { action in
                Button {
                    model.runChatAction(action)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: action.route.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(action.label)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .foregroundStyle(Theme.claude)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.claude.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(Theme.claude.opacity(0.30), lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Open \(action.route.title) in Cortex")
            }
        }
        .padding(.top, 2)
    }

    // Claude-tinted fill for the user, raised card for the assistant.
    private var bubbleBackground: some View {
        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .fill(isUser ? Theme.claude.opacity(0.18) : Theme.card)
    }

    // Small assistant avatar to anchor the left column.
    private var assistantAvatar: some View {
        ZStack {
            Circle().fill(Theme.claude.opacity(0.16))
            Image(systemName: "asterisk")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.claude)
        }
        .frame(width: 28, height: 28)
    }
}

// MARK: - Thinking row
//
// Animated "Thinking with Claude..." indicator shown while a turn is in flight.

private struct ThinkingRow: View {
    // The live activity label ("Reading files…"), or nil for the generic thinking state.
    var activity: String? = nil
    @State private var animating = false
    // Seconds elapsed since the turn started, shown so a multi-second cold start reads
    // as "working", not frozen. Claude Code's first token is inherently a few seconds.
    @State private var seconds = 0
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Assistant avatar matches the message column.
            ZStack {
                Circle().fill(Theme.claude.opacity(0.16))
                Image(systemName: "asterisk")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.claude)
                    .rotationEffect(.degrees(animating ? 180 : 0))
            }
            .frame(width: 28, height: 28)

            HStack(spacing: 8) {
                Text(activity ?? "Thinking with Claude")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .animation(.easeOut(duration: 0.15), value: activity)
                AnimatedDots()
                // Live elapsed time once it's been a beat, so the wait reads as alive.
                if seconds >= 1 {
                    Text("\(seconds)s")
                        .font(.cortexCaption.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            )

            Spacer(minLength: 60)
        }
        .onReceive(tick) { _ in seconds += 1 }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                animating = true
            }
        }
    }
}

// Three dots that pulse in sequence.
private struct AnimatedDots: View {
    @State private var phase = 0

    private let timer = Timer.publish(every: 0.28, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Theme.claude)
                    .frame(width: 5, height: 5)
                    .opacity(phase == index ? 1 : 0.28)
                    .scaleEffect(phase == index ? 1.0 : 0.7)
            }
        }
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 0.24)) {
                phase = (phase + 1) % 3
            }
        }
    }
}

// MARK: - Error banner
//
// Red banner surfacing `model.chat.lastError`.

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.orange)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.orange.opacity(0.35), lineWidth: 1)
        )
    }
}
