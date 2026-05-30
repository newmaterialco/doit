import Realtime
import Supabase
import SwiftUI
import UIKit

struct TodoListView: View {
    let userID: UUID

    @State private var todos: [Todo] = []
    @State private var openInteractions: [UUID: TodoInteraction] = [:]
    @State private var respondingInteractionID: UUID?
    @State private var showAddSheet = false
    @State private var showSettings = false
    @State private var selectedSectionID: Int? = TodoListSection.todo.index
    @State private var scrubbedSectionID: Int?
    @State private var navigationPath = NavigationPath()
    @State private var loadError: String?
    @State private var realtimeTask: Task<Void, Never>?
    @State private var interactionsRealtimeTask: Task<Void, Never>?

    @Environment(AuthModel.self) private var auth

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                Color(red: 0.98, green: 0.98, blue: 0.98)
                    .ignoresSafeArea()

                GeometryReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            sectionPage(.todo)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .id(TodoListSection.todo.index)
                            sectionPage(.doing)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .id(TodoListSection.doing.index)
                            sectionPage(.done)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .id(TodoListSection.done.index)
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollIndicators(.hidden)
                    .scrollPosition(id: $selectedSectionID)
                    .ignoresSafeArea(.container, edges: [.top, .bottom])
                }
                .ignoresSafeArea(.container, edges: [.top, .bottom])

                VStack {
                    topControls
                    Spacer()
                    bottomControls
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Todo.self) { TodoDetailView(todo: $0) }
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: selectedSectionID) { _, newValue in
                guard newValue != nil else { return }
                playSectionHaptic()
            }
            .sheet(isPresented: $showAddSheet) {
                AddTodoView(userID: userID) { newTodo in
                    todos.insert(newTodo, at: 0)
                    selectedSectionID = TodoListSection.todo.index
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .task { await load() }
            .onAppear { startRealtime() }
            .onDisappear {
                realtimeTask?.cancel()
                interactionsRealtimeTask?.cancel()
            }
        }
    }

    private var topControls: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    .white,
                    .white.opacity(0.9),
                    .white.opacity(0.55),
                    .white.opacity(0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 180)
            .ignoresSafeArea(.container, edges: .top)

            HStack {
                Image("doit_Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 24)
                    .accessibilityLabel("doit")

                Spacer()

                Button {
                    playLightHaptic()
                    showSettings = true
                } label: {
                    Image("doit_pofile")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 34, height: 34)
                        .clipShape(Circle())
                        .background {
                            Circle().fill(Color.black)
                        }
                        .overlay {
                            Circle().stroke(Color.black, lineWidth: 2)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Profile")
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private func sectionPage(_ section: TodoListSection) -> some View {
        let items = todos.filter { section.contains($0.status) }
        Group {
            if items.isEmpty && loadError == nil {
                EmptyState(section: section)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                    if let loadError {
                        Text(loadError)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(items) { todo in
                        TodoCard(
                            todo: todo,
                            interaction: openInteractions[todo.id],
                            isResponding: respondingInteractionID != nil
                                && respondingInteractionID == openInteractions[todo.id]?.id,
                            onOpen: { navigationPath.append(todo) },
                            onDoIt: { request(todo) },
                            onCancel: { cancel(todo) },
                            onToggleComplete: { toggleComplete(todo) },
                            onRespond: { interaction, optionID, text in
                                respond(to: interaction, todo: todo, optionID: optionID, text: text)
                            }
                        )
                        .id(cardRefreshID(for: todo))
                        .contextMenu {
                            todoContextMenuAction(for: todo)
                        }
                    }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 130)
                    .padding(.bottom, 96)
                }
                .refreshable { await load() }
            }
        }
    }

    private var bottomControls: some View {
        HStack(alignment: .bottom) {
            dockControls

            Spacer()

            Button {
                playLightHaptic()
                showAddSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .frame(width: 52, height: 52)
                    .foregroundStyle(.white)
                    .background(Color.black, in: Circle())
                    .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .accessibilityLabel("New Task")
        }
        .padding(.leading, 28)
        .padding(.trailing, 20)
        .padding(.bottom, 0)
    }

    private var dockControls: some View {
        HStack(spacing: 0) {
            ForEach(TodoListSection.allCases) { section in
                dockButton(section)
            }
        }
        .padding(3)
        .glassEffect(.regular, in: Capsule())
        .contentShape(Capsule())
        .simultaneousGesture(
            DragGesture(minimumDistance: 6)
                .onChanged { value in
                    scrubDock(at: value.location.x)
                }
                .onEnded { value in
                    scrubDock(at: value.location.x)
                    commitDockScrub()
                }
        )
    }

    private func dockButton(_ section: TodoListSection) -> some View {
        let isSelected = selectedSectionID == section.index
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                selectedSectionID = section.index
            }
        } label: {
            Image(systemName: section.symbolName)
                .font(.body.weight(.semibold))
                .scaleEffect(isSelected ? 1.25 : 0.85)
                .frame(width: 40, height: 40)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .opacity(isSelected ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel(section.title)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: selectedSectionID)
    }

    private func scrubDock(at xPosition: CGFloat) {
        let sectionCount = TodoListSection.allCases.count
        let dockWidth = CGFloat(sectionCount * 40 + 6)
        let sectionWidth = dockWidth / CGFloat(sectionCount)
        let clampedX = min(max(xPosition, 0), dockWidth - 0.1)
        let sectionIndex = Int(clampedX / sectionWidth)
        guard TodoListSection.allCases.indices.contains(sectionIndex) else { return }

        let newSelection = TodoListSection.allCases[sectionIndex].index
        guard selectedSectionID != newSelection else { return }
        scrubbedSectionID = newSelection
        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
            selectedSectionID = newSelection
        }
    }

    private func commitDockScrub() {
        guard let scrubbedSectionID else { return }
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                selectedSectionID = scrubbedSectionID
            }
            self.scrubbedSectionID = nil
        }
    }

    private func playLightHaptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func playSectionHaptic() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    @MainActor
    private func load() async {
        do {
            let latest = try await TodosAPI.list()
            todos = latest
            print("[todos] list loaded count=\(todos.count)")
            loadError = nil
            await loadOpenInteractions()
        } catch {
            print("[todos] list load failed: \(error)")
            loadError = "Couldn't load todos: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func loadOpenInteractions() async {
        let ids = todos.filter { $0.status == .needs_input }.map(\.id)
        guard !ids.isEmpty else {
            openInteractions = [:]
            return
        }
        do {
            openInteractions = try await TodosAPI.openInteractions(for: ids)
        } catch {
            print("[interactions] batch load failed: \(error)")
        }
    }

    private func startRealtime() {
        guard realtimeTask == nil else { return }
        print("[realtime][todos] starting for user=\(userID.uuidString)")
        realtimeTask = Task {
            do {
                let channel = Supa.client.channel("public:todos:user=\(userID.uuidString)")
                let inserts = channel.postgresChange(
                    AnyAction.self,
                    schema: "public",
                    table: "todos"
                )
                await channel.subscribe()
                print("[realtime][todos] subscribed")
                for await change in inserts {
                    print("[realtime][todos] change received: \(change)")
                    await handle(change)
                }
                print("[realtime][todos] stream ended")
            }
        }
        guard interactionsRealtimeTask == nil else { return }
        interactionsRealtimeTask = Task {
            let channel = Supa.client.channel(
                "public:todo_interactions:user=\(userID.uuidString)"
            )
            let stream = channel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "todo_interactions"
            )
            await channel.subscribe()
            for await _ in stream {
                await loadOpenInteractions()
            }
        }
    }

    @MainActor
    private func handle(_ change: AnyAction) async {
        // Cheapest correct thing: refetch.
        await load()
    }

    private func cardRefreshID(for todo: Todo) -> String {
        [
            todo.id.uuidString,
            todo.status.rawValue,
            todo.title,
            todo.connection_slug ?? "",
            todo.preparation_summary ?? "",
            todo.updated_at.ISO8601Format()
        ].joined(separator: "|")
    }

    private func deleteRows(at offsets: IndexSet, in section: TodoListSection) {
        let visible = todos.filter { section.contains($0.status) }
        let toDelete = offsets.map { visible[$0] }
        let idsToDelete = Set(toDelete.map(\.id))
        todos.removeAll { idsToDelete.contains($0.id) }
        Task {
            for t in toDelete {
                try? await TodosAPI.delete(t.id)
            }
        }
    }

    private func delete(_ todo: Todo) {
        todos.removeAll { $0.id == todo.id }
        Task {
            try? await TodosAPI.delete(todo.id)
        }
    }

    @ViewBuilder
    private func todoContextMenuAction(for todo: Todo) -> some View {
        if todo.status.isCancellable {
            Button(role: .destructive) {
                cancel(todo)
            } label: {
                Label("Cancel task", systemImage: "xmark.circle")
            }
        } else {
            Button(role: .destructive) {
                delete(todo)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func request(_ todo: Todo) {
        guard let index = todos.firstIndex(where: { $0.id == todo.id }) else { return }
        todos[index].status = .requested
        selectedSectionID = TodoListSection.doing.index
        Task {
            do {
                try await TodosAPI.setStatus(todo.id, .requested)
            } catch {
                print("[todos] request failed id=\(todo.id): \(error)")
                await load()
            }
        }
    }

    /// Tap-to-complete from the top-left circle. Flips between `.done`
    /// and `.todo` so the user can manually mark a task done (or reopen
    /// it) without going through the agent. Optimistic UI: we update the
    /// local row immediately and reload on failure.
    private func toggleComplete(_ todo: Todo) {
        guard let index = todos.firstIndex(where: { $0.id == todo.id }) else { return }
        let next: TodoStatus = todo.status == .done ? .todo : .done
        todos[index].status = next
        Task {
            do {
                try await TodosAPI.setStatus(todo.id, next)
            } catch {
                print("[todos] toggle complete failed id=\(todo.id): \(error)")
                await load()
            }
        }
    }

    /// Cancel a todo from the card. Mostly used during the preparation
    /// spinner so a stuck prep is never a dead end; the runner sees the
    /// status change and skips its final write.
    private func cancel(_ todo: Todo) {
        guard let index = todos.firstIndex(where: { $0.id == todo.id }) else { return }
        todos[index].status = .cancelled
        Task {
            do {
                try await TodosAPI.setStatus(todo.id, .cancelled)
            } catch {
                print("[todos] cancel failed id=\(todo.id): \(error)")
                await load()
            }
        }
    }

    /// Respond to a card-level interaction (typically a preparation
    /// clarification). The interaction's phase decides whether the todo
    /// goes back to `preparing` or moves on to `requested`.
    private func respond(
        to interaction: TodoInteraction,
        todo: Todo,
        optionID: String?,
        text: String?
    ) {
        respondingInteractionID = interaction.id
        let phase: InteractionPhase = interaction.isPreparationPhase ? .prepare : .execute
        Task {
            defer { respondingInteractionID = nil }
            do {
                try await TodosAPI.respond(
                    to: interaction.id,
                    todoID: todo.id,
                    optionID: optionID,
                    text: text,
                    phase: phase
                )
                openInteractions[todo.id] = nil
                if let index = todos.firstIndex(where: { $0.id == todo.id }) {
                    if optionID?.lowercased() == "cancel" {
                        todos[index].status = .cancelled
                    } else {
                        todos[index].status = phase.nextStatus
                    }
                }
            } catch {
                print("[interactions] inline respond failed: \(error)")
                await load()
            }
        }
    }
}

private enum TodoListSection: String, CaseIterable, Identifiable, Hashable {
    case todo
    case doing
    case done

    var id: String { rawValue }

    var index: Int {
        switch self {
        case .todo: return 0
        case .doing: return 1
        case .done: return 2
        }
    }

    var title: String {
        switch self {
        case .todo: return "Todo"
        case .doing: return "Doing"
        case .done: return "Done"
        }
    }

    var symbolName: String {
        switch self {
        case .todo: return "circle"
        case .doing: return "progress.indicator"
        case .done: return "checkmark.circle.fill"
        }
    }

    func contains(_ status: TodoStatus) -> Bool {
        switch self {
        case .todo:
            // Newly-created todos enter `preparing` while the runner does the
            // AI prep pass. We keep them in the Todo section so the spinner
            // sits where the user just added them.
            return status == .todo || status == .preparing
        case .doing:
            return status == .requested
                || status == .running
                || status == .needs_auth
                || status == .needs_input
                || status == .failed
                || status == .cancelled
        case .done:
            return status == .done
        }
    }
}

/// Three-row task card.
///
///   Row 1: stroked todo circle + "Task" label + (connection icon | spinner)
///   Row 2: task title in SF Pro Rounded 20
///   Row 3: status text + primary action (Do it, Cancel, or inline option)
private struct TodoCard: View {
    let todo: Todo
    /// Open interaction for this todo, if the agent is waiting on a reply.
    /// Loaded by the parent in a single batched query so the card stays
    /// pure-presentational.
    let interaction: TodoInteraction?
    let isResponding: Bool
    let onOpen: () -> Void
    let onDoIt: () -> Void
    let onCancel: () -> Void
    let onToggleComplete: () -> Void
    let onRespond: (_ interaction: TodoInteraction, _ optionID: String?, _ text: String?) -> Void

    var body: some View {
        // Flat three-row stack so spacing between rows is uniform. The
        // top-left circle is its own tap target (toggle); the rest of the
        // top row and the title both open the detail screen.
        VStack(alignment: .leading, spacing: TodoCardStyle.rowSpacing) {
            topRow
            Button(action: onOpen) {
                Text(displayTitle)
                    .font(.system(size: 20, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.black)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            bottomRow

            if let interaction, interaction.options.count > 1 {
                extraOptionsRow(for: interaction)
            }
        }
        .padding(TodoCardStyle.cardPadding)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    interaction != nil
                        ? Color.orange.opacity(0.55)
                        : Color.black.opacity(0.06),
                    lineWidth: interaction != nil ? 1.5 : 1
                )
        }
    }

    // MARK: Rows

    private var topRow: some View {
        HStack(spacing: 8) {
            TodoToggle(status: todo.status, action: onToggleComplete)
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Text("Task")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(TodoCardStyle.muted)
                    Spacer(minLength: 8)
                    topRowTrailing
                        .frame(width: 20, height: 20)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var topRowTrailing: some View {
        if todo.status.isActive {
            ProgressView()
                .controlSize(.small)
                .tint(TodoCardStyle.muted)
        } else if let slug = todo.connection_slug, !slug.isEmpty {
            ConnectionLogo(slug: slug)
        } else {
            Image(systemName: trailingSymbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(TodoCardStyle.muted)
        }
    }

    private var trailingSymbol: String {
        switch todo.status {
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "minus.circle"
        case .needs_auth: return "key.fill"
        case .needs_input: return "hand.raised.fill"
        default: return "sparkles"
        }
    }

    private var displayTitle: String {
        // While the preparation pass is still running the rewritten title
        // doesn't exist yet, so we show the user's raw input. After prep,
        // `title` is the concise version and `original_title` is the raw.
        todo.title
    }

    private var bottomRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(statusText)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(TodoCardStyle.muted)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            primaryAction
        }
    }

    @ViewBuilder
    private func extraOptionsRow(for interaction: TodoInteraction) -> some View {
        // The bottom-right action shows the first option. Render the rest
        // here so multi-option clarifications (e.g. yes/no/cancel) all stay
        // tappable without forcing the user into the detail view.
        let extras = Array(interaction.options.dropFirst())
        HStack(spacing: 8) {
            ForEach(extras) { option in
                PillButton(
                    label: option.label,
                    style: pillStyle(for: option.style),
                    isLoading: isResponding,
                    action: { onRespond(interaction, option.id, nil) }
                )
            }
            Spacer(minLength: 0)
        }
    }

    private var statusText: String {
        if let interaction {
            return interaction.prompt
        }
        switch todo.status {
        case .preparing:
            if let summary = todo.preparation_summary, !summary.isEmpty {
                return summary
            }
            return "Preparing task..."
        case .todo: return "Ready to get started..."
        case .requested: return "Queued..."
        case .running: return "Working..."
        case .needs_auth: return "Connect an account to continue"
        case .needs_input: return "Needs your input"
        case .done: return "Done"
        case .failed: return todo.error_message ?? "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if let interaction, let primary = interaction.options.first {
            PillButton(
                label: primary.label,
                style: pillStyle(for: primary.style),
                isLoading: isResponding,
                action: { onRespond(interaction, primary.id, nil) }
            )
        } else {
            switch todo.status {
            case .preparing:
                PillButton(
                    label: "Cancel",
                    style: .neutral,
                    action: onCancel
                )
            case .todo:
                PillButton(
                    label: "Do it",
                    style: .primary,
                    icon: "play.fill",
                    action: onDoIt
                )
            default:
                EmptyView()
            }
        }
    }

    private func pillStyle(for style: InteractionStyle?) -> PillButton.Style {
        switch style {
        case .destructive: return .destructive
        case .secondary: return .neutral
        case .primary, .none: return .primary
        }
    }
}

/// Shared style tokens for the redesigned todo card. Mirrors the design
/// spec: muted #B6B6B6 for chrome text/strokes, iOS system blue tint for
/// the primary action.
private enum TodoCardStyle {
    static let muted = Color(red: 0xB6 / 255, green: 0xB6 / 255, blue: 0xB6 / 255)
    static let primaryBlue = Color(red: 0, green: 122 / 255, blue: 1)
    static let primaryBlueTint = Color(red: 0, green: 122 / 255, blue: 1).opacity(0.15)
    /// Green used for the completed-todo toggle (iOS system green).
    static let completedGreen = Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
    /// Padding on all four sides of the card.
    static let cardPadding: CGFloat = 20
    /// Vertical gap between the three rows; keep equal so the card feels balanced.
    static let rowSpacing: CGFloat = 14
}

/// Tap-to-complete circle on the top-left of every card. Mirrors the
/// design spec: 20pt diameter, 3pt muted stroke when open, solid green
/// fill with a white checkmark when the todo is `done`.
private struct TodoToggle: View {
    let status: TodoStatus
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if status == .done {
                    Circle().fill(TodoCardStyle.completedGreen)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.white)
                } else {
                    Circle()
                        .strokeBorder(TodoCardStyle.muted, lineWidth: 3)
                }
            }
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(status == .done ? "Mark as not done" : "Mark as done")
    }
}

/// Rounded pill button matching the design spec
/// (`padding 10/16, radius 999, SF Pro Rounded 14/500`).
struct PillButton: View {
    enum Style {
        case primary
        case destructive
        case neutral

        var background: Color {
            switch self {
            case .primary: return TodoCardStyle.primaryBlueTint
            case .destructive: return Color.red.opacity(0.15)
            case .neutral: return Color(white: 0.92)
            }
        }

        var foreground: Color {
            switch self {
            case .primary: return TodoCardStyle.primaryBlue
            case .destructive: return Color.red
            case .neutral: return Color(white: 0.35)
            }
        }
    }

    let label: String
    let style: Style
    var icon: String? = nil
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(style.foreground)
                }
                Text(label)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                if let icon, !isLoading {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(style.foreground)
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(Capsule().fill(style.background))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

/// Renders a Composio toolkit logo from the asset catalog (e.g. "gmail",
/// "googlecalendar"). Falls back to a generic SF Symbol when the asset is
/// missing so we never crash on an unknown slug.
struct ConnectionLogo: View {
    let slug: String

    var body: some View {
        if UIImage(named: slug) != nil {
            Image(slug)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(TodoCardStyle.muted)
        }
    }
}

/// Legacy status badge still used in `TodoDetailView`. Keeps the existing
/// detail-screen look while the card has switched to the new three-row UI.
struct StatusBadge: View {
    let status: TodoStatus

    var body: some View {
        let (symbol, tint) = symbolAndTint
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(tint)
            .frame(width: 24)
            .symbolEffect(.pulse, isActive: status.isActive)
    }

    private var symbolAndTint: (String, Color) {
        switch status {
        case .preparing: return ("sparkles", .gray)
        case .todo: return ("circle", .secondary)
        case .requested: return ("hourglass", .blue)
        case .running: return ("sparkles", .blue)
        case .needs_auth: return ("exclamationmark.circle", .orange)
        case .needs_input: return ("hand.raised.fill", .orange)
        case .done: return ("checkmark.circle.fill", .green)
        case .failed: return ("xmark.circle.fill", .red)
        case .cancelled: return ("minus.circle", .secondary)
        }
    }
}

private struct EmptyState: View {
    let section: TodoListSection

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 28))
                .foregroundStyle(.gray)
            Text(title)
                .font(.title3.bold())
            Text(subtitle)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
    }

    private var iconName: String {
        switch section {
        case .todo: return "checklist"
        case .doing: return "progress.indicator"
        case .done: return "checkmark.seal"
        }
    }

    private var title: String {
        switch section {
        case .todo: return "No todos yet"
        case .doing: return "Nothing in progress"
        case .done: return "Nothing done yet"
        }
    }

    private var subtitle: String {
        switch section {
        case .todo:
            return "Tap + to add something. Then swipe to Doing and tap \u{201C}Do it\u{201D} so the agent can take it from there."
        case .doing:
            return "Tasks the agent is working on, queued, or that need your input will appear here."
        case .done:
            return "Completed todos will show up here."
        }
    }
}

struct InitialsAvatar: View {
    let initials: String?
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black)
            if let initials, !initials.isEmpty {
                Text(initials)
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}
