import SwiftUI
import UIKit

/// Navigation targets pushed from the task list. We navigate by id (not by
/// the full `Todo` / `CronJob` value) so the destination always reads the
/// latest row from `TodoStore` instead of whatever snapshot the list had
/// when the user tapped the card. See `docs/task-realtime.md`.
enum TodoListDestination: Hashable {
    case todo(UUID)
    case cronJob(UUID)
}

struct TodoListView: View {
    let userID: UUID

    @Environment(AuthModel.self) private var auth
    @Environment(TodoStore.self) private var store
    @Environment(PushManager.self) private var push
    @Environment(\.scenePhase) private var scenePhase

    @State private var showAddSheet = false
    @State private var showSettings = false
    @State private var selectedSectionID: Int? = TodoListSection.todo.index
    @State private var scrubbedSectionID: Int?
    @State private var navigationPath = NavigationPath()
    @State private var deletingTodoIDs: Set<UUID> = []

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
                            sectionPage(.scheduled)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .id(TodoListSection.scheduled.index)
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
            .navigationDestination(for: TodoListDestination.self) { destination in
                switch destination {
                case .todo(let id):
                    TodoDetailView(todoID: id)
                case .cronJob(let id):
                    CronJobDetailView(jobID: id)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: selectedSectionID) { _, newValue in
                guard newValue != nil else { return }
                playSectionHaptic()
            }
            .sheet(isPresented: $showAddSheet) {
                AddTodoView(userID: userID) { newTodo in
                    // The store owns the list; insert there so realtime
                    // reconciliation can update the same row in place when
                    // the runner's prep pass finishes.
                    store.insertOptimistic(newTodo)
                    selectedSectionID = TodoListSection.todo.index
                }
            }
            .fullScreenCover(isPresented: $showSettings) {
                SettingsView()
            }
            .onChange(of: navigationPath.count) { _, count in
                if count == 0 {
                    TodoRealtimeHub.endTodoWatch()
                    TodoRealtimeHub.endCronJobWatch()
                }
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                print("[list] scenePhase \(oldPhase)→\(newPhase)")
                guard newPhase == .active else { return }
                Task { await store.loadAll() }
            }
            .onChange(of: store.cronJobs.count) { _, _ in
                // If the runner's prep pass converted the new todo into a
                // cron job, the placeholder todo row vanishes and a cron
                // job arrives. Move the user to the "Scheduled" section so
                // they can see where their input landed.
                guard let pending = store.pendingNewTodoID else { return }
                if !store.todos.contains(where: { $0.id == pending }) {
                    store.pendingNewTodoID = nil
                    selectedSectionID = TodoListSection.scheduled.index
                }
            }
            .onChange(of: push.pendingTodoID) { _, newID in
                guard let id = newID else { return }
                // Push tap → open that todo. Refresh its row first so the
                // detail view doesn't render against a stale list snapshot.
                Task { await store.refreshTodo(id: id) }
                navigationPath.append(TodoListDestination.todo(id))
                push.pendingTodoID = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .todoRemoteUpdate)) { note in
                // Foreground push: refresh only the affected row instead of
                // reloading the whole list. Falls back to a full reload if
                // the payload didn't carry a todo id.
                if let id = TodoRemoteUpdate.todoID(from: note) {
                    print("[list] push refresh todo=\(id)")
                    Task { await store.refreshTodo(id: id) }
                } else {
                    print("[list] push refresh (no id) → full reload")
                    Task { await store.loadAll() }
                }
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
                    ProfileAvatar(
                        kind: .user(
                            initials: auth.initials,
                            imageData: auth.avatarImageData,
                            url: auth.avatarURL
                        ),
                        size: 30
                    )
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
        if section == .scheduled {
            scheduledSectionPage
        } else {
            todoSectionPage(section)
        }
    }

    @ViewBuilder
    private func todoSectionPage(_ section: TodoListSection) -> some View {
        let items = sortedTodos(for: section)
        Group {
            if items.isEmpty && store.loadError == nil {
                EmptyState(section: section)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if let loadError = store.loadError {
                            Text(loadError)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, todo in
                            if let label = doneDividerLabel(for: todo, at: index, in: items) {
                                DoneTimeDivider(label: label)
                                    .padding(.vertical, 2)
                            }
                            todoCard(for: todo)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 130)
                    .padding(.bottom, 96)
                    .animation(.smooth(duration: 0.24), value: items.map(\.id))
                }
                .refreshable { await store.loadAll() }
            }
        }
    }

    @ViewBuilder
    private func todoCard(for todo: Todo) -> some View {
        let interaction = store.openInteractions[todo.id]
        let activity = store.agentActivityByTodoID[todo.id]
        let isDeleting = deletingTodoIDs.contains(todo.id)
        TodoCard(
            todo: todo,
            connectionSlugs: connectionSlugs(for: todo),
            interaction: interaction,
            activity: activity,
            isResponding: store.respondingInteractionID != nil
                && store.respondingInteractionID == interaction?.id,
            onOpen: { navigationPath.append(TodoListDestination.todo(todo.id)) },
            onDoIt: { Task { await store.request(todo) } },
            onCancel: { Task { await store.cancel(todo) } },
            onToggleComplete: { Task { await store.toggleComplete(todo) } },
            onRespond: { interaction, optionID, text in
                Task {
                    await store.respond(
                        to: interaction,
                        todo: todo,
                        optionID: optionID,
                        text: text
                    )
                }
            }
        )
        .id(cardRefreshID(for: todo))
        .opacity(isDeleting ? 0 : 1)
        .scaleEffect(isDeleting ? 0.96 : 1)
        .offset(x: isDeleting ? 28 : 0)
        .allowsHitTesting(!isDeleting)
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .move(edge: .top)),
                removal: .opacity
                    .combined(with: .scale(scale: 0.96))
                    .combined(with: .move(edge: .trailing))
            )
        )
        .animation(.smooth(duration: 0.24), value: isDeleting)
        .contextMenu {
            todoContextMenuAction(for: todo)
        }
    }

    private var scheduledSectionPage: some View {
        Group {
            if store.cronJobs.isEmpty && store.loadError == nil {
                EmptyState(section: .scheduled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if let loadError = store.loadError {
                            Text(loadError)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(store.cronJobs) { job in
                            CronJobCard(
                                job: job,
                                onOpen: { navigationPath.append(TodoListDestination.cronJob(job.id)) },
                                onTogglePause: { Task { await store.toggleCronPause(job) } },
                                onDelete: { Task { await store.deleteCronJob(job.id) } }
                            )
                            .id(cronJobRefreshID(for: job))
                            .contextMenu {
                                Button(role: .destructive) {
                                    Task { await store.deleteCronJob(job.id) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 130)
                    .padding(.bottom, 96)
                }
                .refreshable { await store.loadAll() }
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

    private enum DockStyle {
        static let buttonWidth: CGFloat = 34
        static let buttonHeight: CGFloat = 38
        static let capsulePadding: CGFloat = 6
    }

    private var dockControls: some View {
        HStack(spacing: 0) {
            ForEach(TodoListSection.allCases) { section in
                dockButton(section)
            }
        }
        .padding(DockStyle.capsulePadding)
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
                .font(.title3.weight(.semibold))
                .scaleEffect(isSelected ? 1.15 : 0.9)
                .frame(width: DockStyle.buttonWidth, height: DockStyle.buttonHeight)
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
        let dockWidth = CGFloat(sectionCount) * DockStyle.buttonWidth
            + DockStyle.capsulePadding * 2
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

    private func sortedTodos(for section: TodoListSection) -> [Todo] {
        let items = store.todos.filter { section.contains($0.status) }
        guard section == .done else { return items }
        return items.sorted { lhs, rhs in
            if lhs.updated_at == rhs.updated_at {
                return lhs.created_at > rhs.created_at
            }
            return lhs.updated_at > rhs.updated_at
        }
    }

    private func doneDividerLabel(for todo: Todo, at index: Int, in items: [Todo]) -> String? {
        guard todo.status == .done else { return nil }
        let currentBucket = DoneTimeBucket.bucket(for: todo.updated_at)
        guard index > 0 else { return currentBucket.label }
        let previousBucket = DoneTimeBucket.bucket(for: items[index - 1].updated_at)
        return previousBucket == currentBucket ? nil : currentBucket.label
    }

    private func connectionSlugs(for todo: Todo) -> [String] {
        TodoArtifact.connectionSlugs(
            todoSlug: todo.connection_slug,
            artifacts: store.artifactsByTodoID[todo.id] ?? []
        )
    }

    private func cronJobRefreshID(for job: CronJob) -> String {
        [
            job.id.uuidString,
            job.state.rawValue,
            job.name,
            job.schedule,
            job.next_run_at?.ISO8601Format() ?? "",
            job.updated_at.ISO8601Format()
        ].joined(separator: "|")
    }

    private func cardRefreshID(for todo: Todo) -> String {
        let artifactSig = (store.artifactsByTodoID[todo.id] ?? [])
            .map { "\($0.artifact_key):\($0.kind.rawValue):\($0.updated_at.ISO8601Format())" }
            .joined(separator: ",")
        let activitySig: String
        if let activity = store.agentActivityByTodoID[todo.id] {
            activitySig = "\(activity.phase):\(activity.state):\(activity.title):\(activity.updated_at.ISO8601Format())"
        } else {
            activitySig = ""
        }
        return [
            todo.id.uuidString,
            todo.status.rawValue,
            todo.title,
            todo.connection_slug ?? "",
            artifactSig,
            activitySig,
            todo.preparation_summary ?? "",
            todo.updated_at.ISO8601Format()
        ].joined(separator: "|")
    }

    @ViewBuilder
    private func todoContextMenuAction(for todo: Todo) -> some View {
        if todo.status.isCancellable {
            Button(role: .destructive) {
                Task { await store.cancel(todo) }
            } label: {
                Label("Cancel task", systemImage: "xmark.circle")
            }
        } else {
            Button(role: .destructive) {
                deleteTodoWithAnimation(todo.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func deleteTodoWithAnimation(_ id: UUID) {
        guard !deletingTodoIDs.contains(id) else { return }
        withAnimation(.smooth(duration: 0.24)) {
            deletingTodoIDs.insert(id)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(240))
            await store.deleteTodo(id)
            await MainActor.run {
                deletingTodoIDs.remove(id)
            }
        }
    }
}

private enum DoneTimeBucket: Equatable {
    case today
    case yesterday
    case pastWeek
    case pastMonth
    case earlier

    var label: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .pastWeek: return "Past week"
        case .pastMonth: return "Past month"
        case .earlier: return "Earlier"
        }
    }

    static func bucket(for date: Date, now: Date = Date()) -> DoneTimeBucket {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return .today
        }
        if calendar.isDateInYesterday(date) {
            return .yesterday
        }

        let startOfDate = calendar.startOfDay(for: date)
        let startOfToday = calendar.startOfDay(for: now)
        let daysAgo = calendar.dateComponents([.day], from: startOfDate, to: startOfToday).day ?? 0
        if daysAgo < 7 {
            return .pastWeek
        }
        if daysAgo < 31 {
            return .pastMonth
        }
        return .earlier
    }
}

private struct DoneTimeDivider: View {
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            dividerLine
            Text(label.uppercased())
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(Color.black.opacity(0.34))
            dividerLine
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(Color.black.opacity(0.07))
            .frame(height: 1)
    }
}

private enum TodoListSection: String, CaseIterable, Identifiable, Hashable {
    case todo
    case scheduled
    case done

    var id: String { rawValue }

    var index: Int {
        switch self {
        case .todo: return 0
        case .scheduled: return 1
        case .done: return 2
        }
    }

    var title: String {
        switch self {
        case .todo: return "Tasks"
        case .scheduled: return "Scheduled"
        case .done: return "Done"
        }
    }

    var symbolName: String {
        switch self {
        case .todo: return "circle"
        case .scheduled: return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .done: return "checkmark.circle.fill"
        }
    }

    func contains(_ status: TodoStatus) -> Bool {
        switch self {
        case .todo:
            // All non-done tasks live in one list — preparing, ready, in-flight,
            // waiting on the user, failed, and cancelled.
            return status != .done
        case .scheduled:
            return false
        case .done:
            return status == .done
        }
    }
}

private struct CronJobCard: View {
    let job: CronJob
    let onOpen: () -> Void
    let onTogglePause: () -> Void
    let onDelete: () -> Void

    private static let scheduleSymbol =
        "clock.arrow.trianglehead.counterclockwise.rotate.90"
    private static let cornerRadius: CGFloat = 18
    private static let footerBackground = Color(white: 0.975)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: TodoCardStyle.rowSpacing) {
                HStack(spacing: 8) {
                    Image(systemName: Self.scheduleSymbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(TodoCardStyle.muted)
                        .frame(width: 20, height: 20)
                    HStack(spacing: 8) {
                        Text("Scheduled")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(TodoCardStyle.muted)
                        Spacer(minLength: 8)
                        topRowTrailing
                            .frame(width: 20, height: 20)
                    }
                }

                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(job.name)
                            .font(.system(size: 20, weight: .regular, design: .rounded))
                            .foregroundStyle(Color.black)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(job.schedulePillText)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color(white: 0.35))
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                            .background(Capsule().fill(Color(white: 0.92)))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(TodoCardStyle.cardPadding)
            .background {
                UnevenRoundedRectangle(
                    cornerRadii: .init(
                        topLeading: Self.cornerRadius,
                        bottomLeading: Self.cornerRadius,
                        bottomTrailing: Self.cornerRadius,
                        topTrailing: Self.cornerRadius
                    ),
                    style: .continuous
                )
                .fill(Color.white)
            }

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    if let next = job.nextRunLabel, job.state == .scheduled {
                        Text("Next: \(next)")
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundStyle(TodoCardStyle.muted.opacity(0.85))
                    } else {
                        Text(job.state.label)
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundStyle(TodoCardStyle.muted.opacity(0.85))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if job.state != .completed {
                    PillButton(
                        label: job.state == .paused ? "Resume" : "Pause",
                        style: .neutral,
                        action: onTogglePause
                    )
                }
            }
            .padding(.horizontal, TodoCardStyle.cardPadding)
            .padding(.vertical, 8)
            .background(Self.footerBackground)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Self.footerBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var topRowTrailing: some View {
        if job.state.isActive {
            ProgressView()
                .controlSize(.small)
                .tint(TodoCardStyle.muted)
        } else if let slug = job.connection_slug, !slug.isEmpty {
            ConnectionLogo(slug: slug)
        } else {
            Image(systemName: Self.scheduleSymbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(TodoCardStyle.muted)
        }
    }
}

/// Task card.
///
///   Row 1: stroked todo circle + "Task" label + (connection icon | spinner)
///   Row 2: task title in SF Pro Rounded 20
///   Row 3: status text + primary action, or input prompt + option pills
private struct TodoCard: View {
    let todo: Todo
    /// Toolkit logos for the top row (prep slug + artifact providers).
    let connectionSlugs: [String]
    /// Open interaction for this todo, if the agent is waiting on a reply.
    /// Loaded by the parent in a single batched query so the card stays
    /// pure-presentational.
    let interaction: TodoInteraction?
    /// Live agent activity snapshot used to drive the bottom-row status
    /// line ("Searching Gmail…") while the runner is actively working.
    /// `nil` when no run is in flight; the card falls back to the
    /// status-based copy below.
    let activity: AgentActivity?
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
        }
        .padding(TodoCardStyle.cardPadding)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var topRowTrailing: some View {
        HStack(spacing: 5) {
            if !connectionSlugs.isEmpty {
                ConnectionLogosRow(slugs: connectionSlugs, iconSize: 16, spacing: 2)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.28))
                .frame(width: 11, height: 11)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, connectionSlugs.isEmpty ? 5 : 7)
        .background(Capsule().fill(Color.black.opacity(0.025)))
        .overlay {
            Capsule().stroke(Color.black.opacity(0.08), lineWidth: 1)
        }
    }

    private var displayTitle: String {
        // While the preparation pass is still running the rewritten title
        // doesn't exist yet, so we show the user's raw input. After prep,
        // `title` is the concise version and `original_title` is the raw.
        todo.title
    }

    @ViewBuilder
    private var bottomRow: some View {
        if let interaction {
            VStack(alignment: .leading, spacing: 10) {
                Text(interaction.prompt)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(TodoCardStyle.muted)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                if !interaction.options.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(interaction.options) { option in
                            PillButton(
                                label: option.label,
                                style: pillStyle(for: option.style),
                                isLoading: isResponding,
                                action: { onRespond(interaction, option.id, nil) }
                            )
                        }
                    }
                }
            }
            .id(statusText)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .animation(.smooth(duration: 0.25), value: statusText)
        } else {
            HStack(alignment: .center, spacing: 10) {
                Text(statusText)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(TodoCardStyle.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(statusText)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.smooth(duration: 0.25), value: statusText)
                primaryAction
            }
        }
    }

    private var statusText: String {
        if let interaction {
            return interaction.prompt
        }
        // Live agent activity is the most specific source while the agent
        // is actually working ("Searching Gmail…"). We only trust it
        // for active statuses so the card doesn't flash a stale title
        // once the run lands in a terminal state.
        if let activity, todo.status.isActive {
            return activity.cardStatusText
        }
        switch todo.status {
        case .preparing:
            if let activity, activity.resolvedState == .running {
                return activity.cardStatusText
            }
            if let summary = todo.preparation_summary, !summary.isEmpty {
                return summary
            }
            return "Preparing task..."
        case .todo: return "Ready to get started..."
        case .requested: return "Starting..."
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

/// Stacked Composio toolkit logos (e.g. Sheets + Gmail on one task).
struct ConnectionLogosRow: View {
    let slugs: [String]
    var iconSize: CGFloat = 18
    var spacing: CGFloat = 6

    var body: some View {
        if !slugs.isEmpty {
            HStack(spacing: spacing) {
                ForEach(slugs, id: \.self) { slug in
                    ConnectionLogo(slug: slug)
                        .frame(width: iconSize, height: iconSize)
                        .accessibilityLabel("Connection: \(slug)")
                }
            }
            .animation(.smooth(duration: 0.25), value: slugs)
        }
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
        case .scheduled: return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .done: return "checkmark.seal"
        }
    }

    private var title: String {
        switch section {
        case .todo: return "No tasks yet"
        case .scheduled: return "No scheduled tasks"
        case .done: return "Nothing done yet"
        }
    }

    private var subtitle: String {
        switch section {
        case .todo:
            return "Tap + to add something. The agent prepares each task and starts working right away — tap a row to follow along."
        case .scheduled:
            return "Recurring automations like daily email checks will appear here when the agent sets them up."
        case .done:
            return "Completed tasks will show up here."
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
