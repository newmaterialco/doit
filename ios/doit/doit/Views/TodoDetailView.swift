import AuthenticationServices
import PostgREST
import Realtime
import Supabase
import SwiftUI

struct TodoDetailView: View {
    let todo: Todo

    @State private var current: Todo
    @State private var steps: [TodoStep] = []
    @State private var interaction: TodoInteraction?
    @State private var submittingOptionID: String?
    @State private var error: String?
    @State private var stepsRealtimeTask: Task<Void, Never>?
    @State private var todoRealtimeTask: Task<Void, Never>?
    @State private var interactionsRealtimeTask: Task<Void, Never>?
    @State private var oauthSession: ASWebAuthenticationSession?

    init(todo: Todo) {
        self.todo = todo
        self._current = State(initialValue: todo)
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    StatusBadge(status: current.status)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(current.title).font(.title3.weight(.semibold))
                        if let d = current.detail, !d.isEmpty {
                            Text(d).font(.body).foregroundStyle(.secondary)
                        }
                        Text(current.status.label)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                if current.status.isCancellable {
                    ActionButtons(
                        status: current.status,
                        onStop: stop
                    )
                }
            }

            if let originalTitle, originalTitle != current.title {
                Section("Original request") {
                    Text(originalTitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if current.status == .needs_auth, let url = mostRecentOAuthURL() {
                Section("Connect to continue") {
                    Button {
                        startOAuth(url: url)
                    } label: {
                        Label("Connect your account", systemImage: "key.fill")
                    }
                }
            }

            if let interaction, interaction.status == .open {
                Section("Needs your input") {
                    InteractionCard(
                        interaction: interaction,
                        submittingOptionID: submittingOptionID,
                        onRespond: { optionID, text in
                            await respond(
                                interaction: interaction,
                                optionID: optionID,
                                text: text
                            )
                        }
                    )
                }
            }

            if !visibleSteps.isEmpty {
                Section("Activity") {
                    ForEach(visibleSteps) { step in
                        StepRow(step: step) { url in
                            startOAuth(url: url)
                        }
                    }
                }
            }

            if let err = current.error_message ?? error {
                Section { Text(err).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Todo")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadSteps()
            await loadInteraction()
            startStepsRealtime()
            startTodoRealtime()
            startInteractionsRealtime()
        }
        .onDisappear {
            stepsRealtimeTask?.cancel()
            todoRealtimeTask?.cancel()
            interactionsRealtimeTask?.cancel()
        }
    }

    private var visibleSteps: [TodoStep] {
        steps.filter { !$0.containsInteractionMarker }
    }

    private var originalTitle: String? {
        let trimmed = current.original_title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    // MARK: - Actions

    private func doIt() {
        Task {
            do {
                print("[todo-detail] requesting todo id=\(current.id)")
                try await TodosAPI.setStatus(current.id, .requested)
                current.status = .requested
                print("[todo-detail] local status set to requested id=\(current.id)")
            } catch {
                print("[todo-detail] request failed id=\(current.id): \(error)")
                self.error = error.localizedDescription
            }
        }
    }

    private func stop() {
        Task {
            do {
                try await TodosAPI.setStatus(current.id, .cancelled)
                current.status = .cancelled
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func respond(
        interaction: TodoInteraction,
        optionID: String?,
        text: String?
    ) async {
        submittingOptionID = optionID ?? "__freeform"
        defer { submittingOptionID = nil }
        let phase: InteractionPhase = interaction.isPreparationPhase ? .prepare : .execute
        do {
            try await TodosAPI.respond(
                to: interaction.id,
                todoID: current.id,
                optionID: optionID,
                text: text,
                phase: phase
            )
            // Optimistic: hide the card immediately. Realtime will refresh
            // shortly.
            self.interaction = nil
            if optionID?.lowercased() == "cancel" {
                current.status = .cancelled
            } else {
                current.status = phase.nextStatus
            }
        } catch {
            print("[interaction] respond failed: \(error)")
            self.error = "Couldn't send your response: \(error.localizedDescription)"
        }
    }

    private func mostRecentOAuthURL() -> URL? {
        for s in steps.reversed() {
            if s.kind == .oauth_needed, let urlStr = s.url, let url = URL(string: urlStr) {
                return url
            }
        }
        return nil
    }

    private func startOAuth(url: URL) {
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: nil
        ) { _, _ in
            // The user finishes in the browser; Composio holds the tokens.
            // They can re-tap "Do it" to resume.
        }
        session.prefersEphemeralWebBrowserSession = false
        session.presentationContextProvider = PresentationContextProvider.shared
        oauthSession = session
        session.start()
    }

    // MARK: - Loading + realtime

    private func loadSteps() async {
        do {
            steps = try await TodosAPI.steps(for: current.id)
            print("[realtime][steps] loaded count=\(steps.count) todo=\(current.id)")
            if steps.contains(where: \.containsInteractionMarker) {
                await loadInteractionWithRetry()
            }
        } catch {
            print("[realtime][steps] load failed todo=\(current.id): \(error)")
            self.error = "Couldn't load steps: \(error.localizedDescription)"
        }
    }

    private func loadInteraction() async {
        do {
            interaction = try await TodosAPI.openInteraction(for: current.id)
            print("[interaction] loaded id=\(interaction?.id.uuidString ?? "nil") todo=\(current.id)")
        } catch {
            print("[interaction] load failed todo=\(current.id): \(error)")
        }
    }

    private func startStepsRealtime() {
        guard stepsRealtimeTask == nil else { return }
        print("[realtime][steps] starting todo=\(current.id)")
        stepsRealtimeTask = Task {
            let channel = Supa.client.channel("steps:\(current.id.uuidString)")
            let stream = channel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "todo_steps",
                filter: "todo_id=eq.\(current.id.uuidString)"
            )
            await channel.subscribe()
            print("[realtime][steps] subscribed todo=\(current.id)")
            for await change in stream {
                print("[realtime][steps] change received todo=\(current.id): \(change)")
                await loadSteps()
            }
            print("[realtime][steps] stream ended todo=\(current.id)")
        }
    }

    private func startTodoRealtime() {
        guard todoRealtimeTask == nil else { return }
        print("[realtime][todo] starting todo=\(current.id)")
        todoRealtimeTask = Task {
            let channel = Supa.client.channel("todo:\(current.id.uuidString)")
            let stream = channel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "todos",
                filter: "id=eq.\(current.id.uuidString)"
            )
            await channel.subscribe()
            print("[realtime][todo] subscribed todo=\(current.id)")
            for await change in stream {
                print("[realtime][todo] change received todo=\(current.id): \(change)")
                await refreshTodo()
            }
            print("[realtime][todo] stream ended todo=\(current.id)")
        }
    }

    private func startInteractionsRealtime() {
        guard interactionsRealtimeTask == nil else { return }
        print("[realtime][interactions] starting todo=\(current.id)")
        interactionsRealtimeTask = Task {
            let channel = Supa.client.channel("interactions:\(current.id.uuidString)")
            let stream = channel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "todo_interactions",
                filter: "todo_id=eq.\(current.id.uuidString)"
            )
            await channel.subscribe()
            print("[realtime][interactions] subscribed todo=\(current.id)")
            for await change in stream {
                print("[realtime][interactions] change received todo=\(current.id): \(change)")
                await loadInteraction()
            }
            print("[realtime][interactions] stream ended todo=\(current.id)")
        }
    }

    private func refreshTodo() async {
        do {
            let rows: [Todo] = try await Supa.client
                .from("todos")
                .select()
                .eq("id", value: current.id)
                .limit(1)
                .execute()
                .value
            if let first = rows.first {
                self.current = first
                print("[realtime][todo] refreshed id=\(first.id) status=\(first.status)")
                if first.status == .needs_input {
                    await loadInteractionWithRetry()
                }
            } else {
                print("[realtime][todo] refresh returned no rows id=\(current.id)")
            }
        } catch {
            print("[realtime][todo] refresh failed id=\(current.id): \(error)")
        }
    }

    private func loadInteractionWithRetry() async {
        await loadInteraction()
        if interaction == nil {
            try? await Task.sleep(for: .milliseconds(500))
            await loadInteraction()
        }
    }
}

private struct ActionButtons: View {
    let status: TodoStatus
    let onStop: () -> Void

    var body: some View {
        HStack {
            if status.isCancellable {
                Button(role: .destructive, action: onStop) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

private struct StepRow: View {
    let step: TodoStep
    let openURL: (URL) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                if let toolName = step.tool_name, !toolName.isEmpty {
                    Text(prettify(toolName))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if let text = step.text, !text.isEmpty {
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                }
                if step.kind == .oauth_needed,
                   let urlStr = step.url,
                   let url = URL(string: urlStr) {
                    Button("Open authorization link") {
                        openURL(url)
                    }
                    .font(.footnote)
                }
                Text(step.ts.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch step.kind {
        case .thought: return "bubble.left"
        case .tool_started: return "gearshape.2"
        case .tool_result: return "checkmark"
        case .oauth_needed: return "key.fill"
        case .input_needed: return "hand.raised.fill"
        case .final: return "checkmark.seal.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch step.kind {
        case .thought: return .secondary
        case .tool_started: return .blue
        case .tool_result: return .green
        case .oauth_needed: return .orange
        case .input_needed: return .orange
        case .final: return .green
        case .error: return .red
        }
    }

    private func prettify(_ name: String) -> String {
        name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "mcp ", with: "")
            .capitalized
    }
}

// MARK: - Interaction card

private struct InteractionCard: View {
    let interaction: TodoInteraction
    let submittingOptionID: String?
    let onRespond: (_ optionID: String?, _ text: String?) async -> Void

    @State private var freeform: String = ""
    @FocusState private var freeformFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(interaction.prompt)
                .font(.body.weight(.semibold))

            if let summary = interaction.summary, !summary.isEmpty {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let draft = interaction.emailDraft {
                EmailDraftPreview(draft: draft)
            } else if let content = interaction.content {
                JSONPreview(value: content)
            }

            if interaction.allowsFreeform {
                TextField(
                    interaction.freeformPlaceholder ?? "Add a note or instructions",
                    text: $freeform,
                    axis: .vertical
                )
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .focused($freeformFocused)
                .disabled(submittingOptionID != nil)
            }

            optionButtons

            Text("Tap a button or type below to reply. The agent picks up automatically.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var optionButtons: some View {
        let opts = interaction.options
        VStack(spacing: 8) {
            ForEach(opts) { opt in
                OptionButton(
                    option: opt,
                    isSubmitting: submittingOptionID == opt.id,
                    disabled: submittingOptionID != nil
                ) {
                    Task { await onRespond(opt.id, freeform) }
                }
            }

            if opts.isEmpty && interaction.allowsFreeform {
                Button {
                    Task { await onRespond(nil, freeform) }
                } label: {
                    HStack {
                        if submittingOptionID == "__freeform" {
                            ProgressView().controlSize(.small)
                        }
                        Text("Reply")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(submittingOptionID != nil
                          || freeform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

private struct OptionButton: View {
    let option: InteractionOption
    let isSubmitting: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        let label = HStack {
            if isSubmitting {
                ProgressView().controlSize(.small)
            }
            Text(option.label)
                .frame(maxWidth: .infinity)
        }
        Group {
            switch option.style {
            case .destructive:
                Button(role: .destructive, action: action) { label }
                    .buttonStyle(.bordered)
            case .secondary:
                Button(action: action) { label }
                    .buttonStyle(.bordered)
            case .primary, .none:
                Button(action: action) { label }
                    .buttonStyle(.borderedProminent)
            }
        }
        .disabled(disabled)
    }
}

private struct EmailDraftPreview: View {
    let draft: (subject: String, body: String, to: [String])

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !draft.to.isEmpty {
                Text("To: \(draft.to.joined(separator: ", "))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(draft.subject)
                .font(.subheadline.weight(.semibold))
            Text(draft.body)
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }
}

private struct JSONPreview: View {
    let value: JSONValue

    var body: some View {
        Text(prettyPrint(value))
            .font(.footnote.monospaced())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
            .textSelection(.enabled)
    }

    private func prettyPrint(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let s = String(data: data, encoding: .utf8) else {
            return "(unparseable)"
        }
        return s
    }
}

/// ASWebAuthenticationSession needs a window to anchor on.
@MainActor
final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = PresentationContextProvider()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow }) ?? ASPresentationAnchor()
    }
}
