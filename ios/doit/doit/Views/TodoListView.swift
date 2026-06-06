import AuthenticationServices
import Combine
import CoreLocation
import MapKit
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
    @State private var settingsSheetIsVisible = false
    @State private var selectedSectionID: Int? = TodoListSection.todo.index
    @State private var scrubbedSectionID: Int?
    @State private var navigationPath = NavigationPath()
    @State private var deletingTodoIDs: Set<UUID> = []
    @State private var addSheetInitialTitle = ""
    @State private var centeredSuggestedTaskID: String?
    @State private var suggestedTasks: [SuggestedTask] = []
    @State private var suggestionsLoading = false
    @State private var suggestionsError: String?
    @State private var suggestionsHasLoaded = false
    @State private var showSuggestedInfo = false
    @State private var exploreToolkits: [Toolkit] = []
    @State private var exploreToolkitsLoading = true
    @State private var exploreToolkitsHasLoaded = false
    @State private var exploreError: String?
    @State private var exploreBusySlug: String?
    @State private var exploreOAuthSession: ASWebAuthenticationSession?
    @State private var exploreApiKeyToolkit: Toolkit?
    @State private var exploreApiKeyInput = ""
    @State private var exploreApiKeyError: String?
    @StateObject private var locationProvider = LocationProvider()
    @Namespace private var taskCardNamespace

    var body: some View {
        ZStack(alignment: .top) {
            NavigationStack(path: $navigationPath) {
                ZStack {
                    Color(red: 0.98, green: 0.98, blue: 0.98)
                        .ignoresSafeArea()

                    Group {
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
                    .offset(y: settingsHomeOffset)
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
                    if newValue == TodoListSection.done.index {
                        Task { await prepareExploreIfNeeded() }
                    }
                }
                .sheet(
                    isPresented: $showAddSheet,
                    onDismiss: { addSheetInitialTitle = "" }
                ) {
                    AddTodoView(userID: userID, initialTitle: addSheetInitialTitle) { newTodo in
                        // The store owns the list; insert there so realtime
                        // reconciliation can update the same row in place when
                        // the runner's prep pass finishes.
                        store.insertOptimistic(newTodo)
                        selectedSectionID = TodoListSection.todo.index
                    }
                }
                .sheet(item: $exploreApiKeyToolkit) { toolkit in
                    ExploreApiKeySheet(
                        toolkit: toolkit,
                        apiKey: $exploreApiKeyInput,
                        error: $exploreApiKeyError,
                        busy: exploreBusySlug == toolkit.slug,
                        onConnect: { key in
                            Task { await connectExploreApiKey(toolkit, apiKey: key) }
                        },
                        onCancel: {
                            exploreApiKeyToolkit = nil
                            exploreApiKeyInput = ""
                            exploreApiKeyError = nil
                        }
                    )
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

            if showSuggestedInfo {
                suggestedInfoBackdrop
                    .transition(.opacity)
                    .zIndex(6)

                suggestedInfoPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(7)
            }

            if showSettings {
                Color.white
                    .ignoresSafeArea()
                    .opacity(settingsSheetIsVisible ? 1 : 0)
                    .animation(settingsPresentationAnimation, value: settingsSheetIsVisible)
                    .zIndex(9)

                SettingsTopOverlay(onDismiss: dismissSettings)
                    .offset(y: settingsSheetOffset)
                    .zIndex(10)
            }
        }
    }

    private var topControls: some View {
        ZStack(alignment: .top) {
            Color(red: 0xFA / 255, green: 0xFA / 255, blue: 0xFA / 255)
            .frame(height: 114)
            .ignoresSafeArea(.container, edges: .top)

            HStack {
                SlidingSectionTitle(selectedSection: selectedSection)

                Spacer()

                Button {
                    playFirmHaptic()
                    presentSettings()
                } label: {
                    ProfileAvatar(
                        kind: .user(
                            initials: auth.initials,
                            imageData: auth.avatarImageData,
                            url: auth.avatarURL
                        ),
                        size: 32
                    )
                    .overlay {
                        Circle()
                            .stroke(Color.gray.opacity(0.16), lineWidth: 2.5)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Profile")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    private var selectedSection: TodoListSection {
        TodoListSection.allCases.first { $0.index == selectedSectionID }
            ?? .todo
    }

    @ViewBuilder
    private func sectionPage(_ section: TodoListSection) -> some View {
        if section == .todo {
            tasksSectionPage
        } else if section == .scheduled {
            scheduledSectionPage
        } else {
            exploreSectionPage
        }
    }

    private var tasksSectionPage: some View {
        let activeItems = activeTodos
        let completedItems = completedTodos
        let suggestions = displayedSuggestedTasks
        return GeometryReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if let loadError = store.loadError {
                        Text(loadError)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ForEach(activeItems) { todo in
                        todoCard(for: todo)
                    }

                    if !suggestions.isEmpty {
                        TaskSectionHeader(
                            title: "Suggested",
                            trailingIconName: "info.circle.fill",
                            trailingAction: presentSuggestedInfo
                        )
                            .padding(.top, activeItems.isEmpty ? 8 : 14)

                        SuggestedTasksStrip(
                            suggestions: suggestions,
                            screenWidth: proxy.size.width,
                            centeredSuggestionID: $centeredSuggestedTaskID,
                            onLoadMore: triggerLoadMoreSuggestions,
                            onSelect: selectSuggestion
                        )
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                    }

                    if !completedItems.isEmpty {
                        TaskSectionHeader(title: "Done")
                            .padding(.top, suggestions.isEmpty ? (activeItems.isEmpty ? 8 : 14) : 2)

                        ForEach(completedItems) { todo in
                            todoCard(for: todo)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 116)
                .padding(.bottom, 96)
                .animation(.smooth(duration: 0.34), value: taskLayoutSignature)
            }
            .refreshable { await store.loadAll() }
            .task {
                await loadInitialSuggestionsIfNeeded()
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
            onOpen: {
                playLightHaptic()
                navigationPath.append(TodoListDestination.todo(todo.id))
            },
            onDoIt: { Task { await store.request(todo) } },
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
        .id(todo.id)
        .matchedGeometryEffect(id: todo.id, in: taskCardNamespace)
        .opacity(isDeleting ? 0 : 1)
        .scaleEffect(isDeleting ? 0.96 : 1)
        .offset(x: isDeleting ? 28 : 0)
        .allowsHitTesting(!isDeleting)
        .animation(.smooth(duration: 0.24), value: isDeleting)
        .contextMenu {
            todoContextMenuAction(for: todo)
        }
    }

    private var exploreSectionPage: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let exploreError {
                    Text(exploreError)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ExploreLocationCard(
                    locationProvider: locationProvider,
                    actions: Array(locationActions.prefix(3)),
                    onSelectAction: { item in
                        openSuggestedTask(item.prompt)
                    }
                )

                ExploreConnectionsPromoCard {
                    playLightHaptic()
                    presentSettings()
                }

                ForEach(exploreCategories) { category in
                    ExploreSectionHeader(title: category.title)
                    ExploreHorizontalRow {
                        ForEach(category.items) { item in
                            ExploreActionTile(item: item, style: category.cardStyle) {
                                openSuggestedTask(item.prompt)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 116)
            .padding(.bottom, 96)
        }
        .refreshable {
            locationProvider.refreshIfAuthorized()
        }
    }

    private var scheduledSectionPage: some View {
        Group {
            if store.cronJobs.isEmpty && store.loadError == nil {
                EmptyState(section: .scheduled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10)
                        ],
                        spacing: 10
                    ) {
                        if let loadError = store.loadError {
                            Text(loadError)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .gridCellColumns(2)
                        }
                        ForEach(store.cronJobs) { job in
                            CronJobCard(
                                job: job,
                                onOpen: {
                                    playLightHaptic()
                                    navigationPath.append(TodoListDestination.cronJob(job.id))
                                },
                                onTogglePause: {
                                    playLightHaptic()
                                    Task { await store.toggleCronPause(job) }
                                },
                                onDelete: { Task { await store.deleteCronJob(job.id) } }
                            )
                            .frame(maxWidth: .infinity, alignment: .topLeading)
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
                addSheetInitialTitle = ""
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

    private func playFirmHaptic() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.9)
    }

    private var settingsPresentationAnimation: Animation {
        .spring(response: 0.36, dampingFraction: 0.78)
    }

    private var settingsSheetOffset: CGFloat {
        settingsSheetIsVisible ? 0 : -UIScreen.main.bounds.height
    }

    private var settingsHomeOffset: CGFloat {
        settingsSheetIsVisible ? UIScreen.main.bounds.height : 0
    }

    private func presentSettings() {
        showSettings = true
        DispatchQueue.main.async {
            withAnimation(settingsPresentationAnimation) {
                settingsSheetIsVisible = true
            }
        }
    }

    private func dismissSettings() {
        withAnimation(settingsPresentationAnimation) {
            settingsSheetIsVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            if !settingsSheetIsVisible {
                showSettings = false
            }
        }
    }

    private var suggestedInfoBackdrop: some View {
        Color.black.opacity(0.16)
            .ignoresSafeArea(.all)
            .contentShape(Rectangle())
            .onTapGesture {
                playLightHaptic()
                dismissSuggestedInfo()
            }
    }

    private var suggestedInfoPanel: some View {
        VStack {
            Spacer()
            SuggestedInfoCard(
                onClose: {
                    playLightHaptic()
                    dismissSuggestedInfo()
                }
            )
            .padding(.horizontal, 18)
            .padding(.bottom, 20)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private func presentSuggestedInfo() {
        playLightHaptic()
        withAnimation(settingsPresentationAnimation) {
            showSuggestedInfo = true
        }
    }

    private func dismissSuggestedInfo() {
        withAnimation(settingsPresentationAnimation) {
            showSuggestedInfo = false
        }
    }

    private func playSectionHaptic() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private var activeTodos: [Todo] {
        store.todos.filter { $0.status != .done }
    }

    private var completedTodos: [Todo] {
        store.todos.filter { $0.status == .done }.sorted { lhs, rhs in
            if lhs.updated_at == rhs.updated_at {
                return lhs.created_at > rhs.created_at
            }
            return lhs.updated_at > rhs.updated_at
        }
    }

    private var taskLayoutSignature: String {
        store.todos
            .map { "\($0.id.uuidString):\($0.status.rawValue):\($0.updated_at.ISO8601Format())" }
            .joined(separator: "|")
    }

    private var displayedSuggestedTasks: [SuggestedTask] {
        if suggestedTasks.isEmpty && !suggestionsLoading && suggestionsHasLoaded {
            return fallbackSuggestedTasks()
        }
        if suggestionsLoading || suggestionsHasLoaded {
            return suggestedTasks + [.loader]
        }
        return [.loader]
    }

    private func fallbackSuggestedTasks() -> [SuggestedTask] {
        let source = store.todos
            .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                let lhsDoneRank = lhs.status == .done ? 0 : 1
                let rhsDoneRank = rhs.status == .done ? 0 : 1
                if lhsDoneRank != rhsDoneRank {
                    return lhsDoneRank < rhsDoneRank
                }
                return lhs.updated_at > rhs.updated_at
            }

        var seenTitles: Set<String> = []
        return source.compactMap { todo in
            let title = suggestionTitle(for: todo)
            let key = title.lowercased()
            guard seenTitles.insert(key).inserted else { return nil }
            return SuggestedTask(
                id: "fallback-\(key)",
                title: title,
                theme: fallbackTheme(for: todo),
                kind: .suggestion
            )
        }
        .prefix(5)
        .map { $0 }
    }

    private func suggestionTitle(for todo: Todo) -> String {
        let rawTitle = todo.original_title?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? todo.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTitle.isEmpty else { return "Create a new task" }
        return rawTitle
    }

    private func fallbackTheme(for todo: Todo) -> String {
        switch todo.connection_slug {
        case "gmail": return "Email"
        case "googlecalendar": return "Plan"
        case "googlesheets": return "Sheets"
        case "slack": return "Update"
        case "googledocs": return "Write"
        case "googledrive": return "Docs"
        default:
            return todo.status == .done ? "Follow-up" : "Idea"
        }
    }

    private func selectSuggestion(_ suggestion: SuggestedTask) {
        guard suggestion.kind == .suggestion else { return }
        openSuggestedTask(suggestion.title)
    }

    private func openSuggestedTask(_ title: String) {
        playLightHaptic()
        addSheetInitialTitle = title
        showAddSheet = true
    }

    private var locationActions: [ExploreActionItem] {
        [
            ExploreActionItem(
                title: "When I Leave",
                subtitle: "Location reminder",
                prompt: "Remind me when I leave here to ",
                symbolName: "location.fill"
            ),
            ExploreActionItem(
                title: "Nearby Places",
                subtitle: "Local search",
                prompt: "Find nearby places for ",
                symbolName: "map.fill"
            ),
            ExploreActionItem(
                title: "Errand Route",
                subtitle: "Plan around here",
                prompt: "Plan errands around my current location",
                symbolName: "car.fill"
            ),
            ExploreActionItem(
                title: "Area Checklist",
                subtitle: "Travel prep",
                prompt: "Create a travel checklist for this area",
                symbolName: "checklist"
            )
        ]
    }

    private var exploreCategories: [ExploreCategory] {
        [
            ExploreCategory(
                title: "Daily Automations",
                cardStyle: .square,
                items: [
                    ExploreActionItem(title: "Morning Plan", subtitle: "Every weekday", prompt: "Every weekday morning, make me a short plan for the day", symbolName: "sun.max.fill"),
                    ExploreActionItem(title: "Email Watch", subtitle: "Monitor inbox", prompt: "Monitor my inbox every day for important follow-ups", symbolName: "envelope.fill"),
                    ExploreActionItem(title: "Weekly Summary", subtitle: "Recurring recap", prompt: "Every Friday, summarize what I got done this week", symbolName: "calendar.badge.clock"),
                    ExploreActionItem(title: "Daily Check", subtitle: "Track anything", prompt: "Check every day whether ", symbolName: "clock.fill")
                ]
            ),
            ExploreCategory(
                title: "Writing",
                cardStyle: .square,
                items: [
                    ExploreActionItem(title: "Draft Reply", subtitle: "Fast response", prompt: "Draft a reply to ", symbolName: "text.bubble.fill"),
                    ExploreActionItem(title: "Polish Message", subtitle: "Cleaner tone", prompt: "Polish this message and make it concise: ", symbolName: "sparkles"),
                    ExploreActionItem(title: "Summarize Notes", subtitle: "Find the point", prompt: "Summarize these notes into action items: ", symbolName: "doc.text.fill"),
                    ExploreActionItem(title: "Make a Plan", subtitle: "From bullets", prompt: "Turn these bullets into a clear plan: ", symbolName: "list.bullet.clipboard.fill")
                ]
            ),
            ExploreCategory(
                title: "Research",
                cardStyle: .square,
                items: [
                    ExploreActionItem(title: "Compare Options", subtitle: "Pros and cons", prompt: "Compare options for ", symbolName: "scale.3d"),
                    ExploreActionItem(title: "Find Info", subtitle: "Web research", prompt: "Research and summarize ", symbolName: "magnifyingglass"),
                    ExploreActionItem(title: "Track Company", subtitle: "Stay updated", prompt: "Track news about this company and summarize important updates: ", symbolName: "building.2.fill"),
                    ExploreActionItem(title: "Topic Brief", subtitle: "Quick overview", prompt: "Create a short brief about ", symbolName: "book.closed.fill")
                ]
            ),
            ExploreCategory(
                title: "Organization",
                cardStyle: .square,
                items: [
                    ExploreActionItem(title: "Clean Inbox", subtitle: "Triage help", prompt: "Help me clean up my inbox and make a follow-up list", symbolName: "tray.full.fill"),
                    ExploreActionItem(title: "Organize Links", subtitle: "Sort resources", prompt: "Organize these links into useful groups: ", symbolName: "link"),
                    ExploreActionItem(title: "Follow-Ups", subtitle: "Next actions", prompt: "Create a follow-up list from ", symbolName: "person.crop.circle.badge.checkmark"),
                    ExploreActionItem(title: "Status Update", subtitle: "Share progress", prompt: "Prepare a status update for ", symbolName: "chart.bar.doc.horizontal.fill")
                ]
            )
        ]
    }

    private func beginExploreConnect(_ toolkit: Toolkit) {
        if toolkit.usesApiKey {
            exploreApiKeyInput = ""
            exploreApiKeyError = nil
            exploreApiKeyToolkit = toolkit
        } else {
            Task { await connectExploreOAuth(toolkit) }
        }
    }

    private func prepareExploreIfNeeded() async {
        locationProvider.refreshIfAuthorized()
    }

    private func loadExploreToolkits(showSpinner: Bool = true, force: Bool = false) async {
        if exploreToolkitsHasLoaded, !force {
            return
        }

        if exploreToolkits.isEmpty, let cachedToolkits = IntegrationsAPI.cachedToolkits {
            exploreToolkits = cachedToolkits
            exploreToolkitsLoading = cachedToolkits.isEmpty
            if !cachedToolkits.isEmpty, !force {
                exploreToolkitsHasLoaded = true
                return
            }
        }

        if showSpinner {
            exploreToolkitsLoading = exploreToolkits.isEmpty
        }

        do {
            exploreToolkits = try await IntegrationsAPI.list()
            exploreToolkitsHasLoaded = true
            exploreError = nil
        } catch {
            exploreError = "Couldn't load connections: \(error.localizedDescription)"
        }

        exploreToolkitsLoading = false
    }

    private func connectExploreOAuth(_ toolkit: Toolkit) async {
        exploreBusySlug = toolkit.slug
        defer { exploreBusySlug = nil }

        do {
            let result = try await IntegrationsAPI.connect(toolkit: toolkit.slug)
            guard let urlString = result.redirect_url,
                  let url = URL(string: urlString) else {
                exploreError = "Got an invalid authorization URL."
                return
            }
            await runExploreOAuth(url: url)
            await loadExploreToolkits(showSpinner: false, force: true)
        } catch {
            exploreError = "Couldn't start connection: \(error.localizedDescription)"
        }
    }

    private func connectExploreApiKey(_ toolkit: Toolkit, apiKey key: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            exploreApiKeyError = "Enter your \(toolkit.name) API key."
            return
        }

        exploreBusySlug = toolkit.slug
        exploreApiKeyError = nil
        defer { exploreBusySlug = nil }

        do {
            _ = try await IntegrationsAPI.connect(toolkit: toolkit.slug, apiKey: trimmed)
            let toolkits = try await IntegrationsAPI.list()
            if let updated = toolkits.first(where: { $0.slug == toolkit.slug }), updated.connected {
                exploreToolkits = toolkits
                exploreToolkitsHasLoaded = true
                exploreApiKeyToolkit = nil
                exploreApiKeyInput = ""
                exploreApiKeyError = nil
                exploreError = nil
            } else {
                exploreApiKeyError = "Saved your key but couldn't confirm the connection. Pull down to refresh."
            }
        } catch {
            exploreApiKeyError = IntegrationsAPI.userFacingError(error)
        }
    }

    private func disconnectExploreToolkit(_ toolkit: Toolkit) async {
        guard let connectionID = toolkit.connection_id else { return }
        exploreBusySlug = toolkit.slug
        defer { exploreBusySlug = nil }

        do {
            try await IntegrationsAPI.disconnect(connectionID: connectionID)
            await loadExploreToolkits(showSpinner: false, force: true)
        } catch {
            exploreError = "Couldn't disconnect: \(error.localizedDescription)"
        }
    }

    private func runExploreOAuth(url: URL) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { _, _ in
                continuation.resume()
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = PresentationContextProvider.shared
            exploreOAuthSession = session
            if !session.start() {
                continuation.resume()
            }
        }
    }

    private func loadInitialSuggestionsIfNeeded() async {
        guard !suggestionsHasLoaded, !suggestionsLoading else { return }
        await loadMoreSuggestions()
    }

    private func triggerLoadMoreSuggestions() {
        Task { await loadMoreSuggestions() }
    }

    private func loadMoreSuggestions() async {
        guard !suggestionsLoading else { return }
        suggestionsLoading = true
        suggestionsError = nil
        defer {
            suggestionsLoading = false
            suggestionsHasLoaded = true
        }

        do {
            let response = try await SuggestionsAPI.fetch(
                count: 5,
                excludeTitles: suggestedTasks.map(\.title)
            )
            let newSuggestions = response.suggestions
                .map(makeSuggestedTask(from:))
                .filter { candidate in
                    !suggestedTasks.contains { existing in
                        existing.title.caseInsensitiveCompare(candidate.title) == .orderedSame
                    }
                }
            suggestedTasks.append(contentsOf: newSuggestions)
            if centeredSuggestedTaskID == SuggestedTask.loaderID, let first = newSuggestions.first {
                centeredSuggestedTaskID = first.id
            }
        } catch {
            suggestionsError = error.localizedDescription
            if suggestedTasks.isEmpty {
                suggestedTasks = fallbackSuggestedTasks()
            }
        }
    }

    private func makeSuggestedTask(from generated: GeneratedSuggestion) -> SuggestedTask {
        let title = generated.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let theme = generated.theme.trimmingCharacters(in: .whitespacesAndNewlines)
        return SuggestedTask(
            id: "generated-\(UUID().uuidString)",
            title: title.isEmpty ? "Create a helpful new task" : title,
            theme: theme.isEmpty ? "Idea" : theme,
            kind: .suggestion
        )
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

private struct TaskSectionHeader: View {
    let title: String
    var trailingIconName: String? = nil
    var trailingAction: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.78))

            Spacer(minLength: 0)

            if let trailingIconName {
                if let trailingAction {
                    Button(action: trailingAction) {
                        Image(systemName: trailingIconName)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.gray.opacity(0.58))
                            .frame(width: 36, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About suggested tasks")
                } else {
                    Image(systemName: trailingIconName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.gray.opacity(0.58))
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct SuggestedInfoCard: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Suggestions")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(white: 0.1))

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(white: 0.55))
                        .frame(width: 34, height: 34)
                        .background(Color(white: 0.95), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close suggested tasks info")
            }
            .padding(.leading, 22)
            .padding(.trailing, 16)
            .padding(.top, 22)
            .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 18) {
                Text("doit looks at the kinds of tasks you create, complete, and schedule, then suggests useful next actions that are similar or complementary.")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(white: 0.18))
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: onClose) {
                    Text("Got it")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(TodoCardStyle.primaryBlue, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 24)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 28, y: 18)
    }
}

private struct SuggestedTask: Identifiable, Hashable {
    enum Kind: Hashable {
        case suggestion
        case loader
    }

    static let loaderID = "suggestion-loader"

    let id: String
    let title: String
    let theme: String
    let kind: Kind

    static var loader: SuggestedTask {
        SuggestedTask(
            id: loaderID,
            title: "",
            theme: "",
            kind: .loader
        )
    }
}

private struct SuggestedTasksStrip: View {
    let suggestions: [SuggestedTask]
    let screenWidth: CGFloat
    @Binding var centeredSuggestionID: String?
    let onLoadMore: () -> Void
    let onSelect: (SuggestedTask) -> Void

    private let spacing: CGFloat = 8
    private let horizontalContentInset: CGFloat = 16

    private var tileSize: CGFloat {
        max(58, (viewportWidth - spacing * 4) / 5)
    }

    private var viewportWidth: CGFloat {
        max(0, screenWidth - horizontalContentInset * 2)
    }

    private var tileWidth: CGFloat {
        tileSize * 4.8
    }

    private var tileHeight: CGFloat {
        tileSize * 2.35
    }

    private var leftSnapMargin: CGFloat {
        max(0, min(2, viewportWidth - tileWidth))
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                ForEach(suggestions) { suggestion in
                    SuggestedTaskTile(suggestion: suggestion) {
                        onSelect(suggestion)
                    }
                    .frame(width: tileWidth, height: tileHeight)
                    .id(suggestion.id)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.leading, leftSnapMargin, for: .scrollContent)
        .contentMargins(.trailing, max(0, viewportWidth - tileWidth - leftSnapMargin), for: .scrollContent)
        .scrollClipDisabled()
        .scrollPosition(id: $centeredSuggestionID)
        .scrollTargetBehavior(.viewAligned)
        .onAppear {
            if centeredSuggestionID == nil || !suggestions.contains(where: { $0.id == centeredSuggestionID }) {
                centeredSuggestionID = suggestions.first?.id
            }
        }
        .onChange(of: suggestions.map(\.id)) { _, ids in
            if centeredSuggestionID == nil || !ids.contains(centeredSuggestionID ?? "") {
                centeredSuggestionID = ids.first
            }
        }
        .onChange(of: centeredSuggestionID) { oldValue, newValue in
            guard oldValue != nil, newValue != nil, oldValue != newValue else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            if newValue == SuggestedTask.loaderID {
                onLoadMore()
            }
        }
    }
}

private struct SuggestedTaskTile: View {
    let suggestion: SuggestedTask
    let onTap: () -> Void
    @State private var skeletonIsAnimating = false

    var body: some View {
        Button(action: onTap) {
            Group {
                if suggestion.kind == .loader {
                    skeletonContent
                } else {
                    suggestionContent
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(suggestion.kind == .loader)
        .accessibilityLabel(
            suggestion.kind == .loader
                ? "Loading more suggestions"
                : "Suggested task: \(suggestion.title)"
        )
        .onAppear { skeletonIsAnimating = true }
        .onDisappear { skeletonIsAnimating = false }
    }

    private var suggestionContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(suggestion.theme)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.gray)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.gray.opacity(0.10), in: Capsule())

            Spacer(minLength: 0)

            Text(suggestion.title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.black)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var skeletonContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Capsule()
                .fill(skeletonFill)
                .frame(width: 72, height: 26)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(skeletonFill)
                    .frame(width: 190, height: 18)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(skeletonFill)
                    .frame(width: 140, height: 18)
            }
        }
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: skeletonIsAnimating)
    }

    private var skeletonFill: Color {
        Color.gray.opacity(skeletonIsAnimating ? 0.18 : 0.08)
    }
}

private struct ExploreSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }
}

private struct ExploreHorizontalRow<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                content
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
        .scrollClipDisabled()
    }
}

private struct ExploreLocationCard: View {
    @ObservedObject var locationProvider: LocationProvider
    let actions: [ExploreActionItem]
    let onSelectAction: (ExploreActionItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                LocationMapSquareTile(locationProvider: locationProvider)

                VStack(alignment: .leading, spacing: 10) {
                    LocationInfoPill(title: "Home address", subtitle: "Add home")
                    LocationInfoPill(title: "Work, school etc.", subtitle: "Add place")
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            VStack(spacing: 8) {
                ForEach(actions) { item in
                    LocationSuggestionRow(item: item) {
                        onSelectAction(item)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct LocationMapSquareTile: View {
    @ObservedObject var locationProvider: LocationProvider

    private var coordinate: CLLocationCoordinate2D? {
        locationProvider.coordinate
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let coordinate {
                    Map(
                        coordinateRegion: .constant(region(for: coordinate)),
                        interactionModes: [],
                        showsUserLocation: true
                    )
                    .allowsHitTesting(false)
                } else {
                    permissionContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.88, green: 0.94, blue: 1.0),
                                    Color(red: 0.95, green: 0.98, blue: 0.96)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }

        }
        .frame(width: 142, height: 142)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture {
            locationProvider.requestAuthorizationOrLocation()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Location map")
    }

    private var permissionContent: some View {
        VStack(spacing: 8) {
            Image(systemName: locationProvider.permissionSymbolName)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(TodoCardStyle.primaryBlue)
                .frame(width: 50, height: 50)
                .background(Color.white.opacity(0.75), in: Circle())

            Text(locationProvider.permissionActionText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(10)
    }

    private func region(for coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
        )
    }
}

private struct LocationInfoPill: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct LocationSuggestionRow: View {
    let item: ExploreActionItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: item.symbolName)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(TodoCardStyle.primaryBlue, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(item.subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct ExploreConnectionsPromoCard: View {
    let onSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { proxy in
                Image("Connections_Header")
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: 154)
                    .clipped()
            }
            .frame(height: 154)

            VStack(alignment: .leading, spacing: 16) {
                Spacer()
                    .frame(height: 6)

                Text("Connect your tools")
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)

                Button(action: onSetup) {
                    Text("Setup connections")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

private struct LocationMapTile: View {
    @ObservedObject var locationProvider: LocationProvider

    private var coordinate: CLLocationCoordinate2D? {
        locationProvider.coordinate
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let coordinate {
                    Map(
                        coordinateRegion: .constant(region(for: coordinate)),
                        interactionModes: [],
                        showsUserLocation: true
                    )
                    .allowsHitTesting(false)
                } else {
                    permissionContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.88, green: 0.94, blue: 1.0),
                                    Color(red: 0.95, green: 0.98, blue: 0.96)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

            Text("Monitoring...")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(12)
        }
        .frame(width: 264, height: 190)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .onTapGesture {
            locationProvider.requestAuthorizationOrLocation()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Location map")
    }

    private var permissionContent: some View {
        VStack(spacing: 10) {
            Image(systemName: locationProvider.permissionSymbolName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(TodoCardStyle.primaryBlue)
                .frame(width: 58, height: 58)
                .background(Color.white.opacity(0.75), in: Circle())

            Text(locationProvider.permissionActionText)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
    }

    private func region(for coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
        )
    }
}

private struct ExploreActionTile: View {
    let item: ExploreActionItem
    let style: ExploreCardStyle
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: item.symbolName)
                    .font(.system(size: style.iconSize, weight: style.iconWeight))
                    .foregroundStyle(style.iconForegroundStyle)
                    .frame(width: 40, height: 40)
                    .background(style.iconBackgroundColor(for: item), in: Circle())

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title)
                        .font(.system(size: style.titleSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(item.subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(style.padding)
            .frame(width: style.width, height: style.height, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
    }
}

private struct ExploreConnectionCard: View {
    let toolkit: Toolkit
    let busy: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                ConnectionLogo(slug: toolkit.slug)
                    .frame(width: 32, height: 32)

                Spacer()

                if toolkit.isConnectable && toolkit.connected {
                    Menu {
                        Button("Disconnect", role: .destructive, action: onDisconnect)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .background(Color(.systemGray6), in: Circle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .background(Color(.systemGray6), in: Circle())
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(toolkit.name)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                Text(toolkit.description)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if busy {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
            } else if toolkit.isConnectable && toolkit.connected {
                Text("Connected")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(TodoCardStyle.primaryBlue)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(TodoCardStyle.primaryBlueTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if toolkit.isConnectable {
                Button("Connect", action: onConnect)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Text("Available")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(16)
        .frame(width: 220, height: 204, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct ExploreConnectionSkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Circle()
                .fill(Color.gray.opacity(0.12))
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.gray.opacity(0.12))
                    .frame(width: 118, height: 16)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.gray.opacity(0.10))
                    .frame(width: 160, height: 12)
            }

            Spacer()

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.gray.opacity(0.10))
                .frame(height: 34)
        }
        .padding(16)
        .frame(width: 220, height: 188)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct ExploreApiKeySheet: View {
    let toolkit: Toolkit
    @Binding var apiKey: String
    @Binding var error: String?
    let busy: Bool
    let onConnect: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
                Section {
                    SecureField("\(toolkit.name) API key", text: $apiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(busy)
                } footer: {
                    Text(apiKeyFooter)
                }
            }
            .navigationTitle("Connect \(toolkit.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Connect") {
                            onConnect(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var apiKeyFooter: String {
        switch toolkit.slug {
        case "hunter":
            return "Find your key at hunter.io API. Composio stores it securely for agent use."
        default:
            return "Composio stores your key securely for agent use."
        }
    }
}

private final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var lastError: String?

    private let manager = CLLocationManager()
    private var lastLocationRefresh: Date?

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestAuthorizationOrLocation() {
        authorizationStatus = manager.authorizationStatus
        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            lastError = "Location access is blocked."
        @unknown default:
            lastError = "Location is unavailable."
        }
    }

    func refreshIfAuthorized() {
        authorizationStatus = manager.authorizationStatus
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else {
            return
        }
        if let lastLocationRefresh,
           coordinate != nil,
           Date().timeIntervalSince(lastLocationRefresh) < 300 {
            return
        }
        lastLocationRefresh = Date()
        manager.requestLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse {
            lastLocationRefresh = Date()
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        coordinate = locations.last?.coordinate
        lastError = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        lastError = error.localizedDescription
    }

    var statusText: String {
        if let lastError {
            return lastError
        }
        switch authorizationStatus {
        case .notDetermined:
            return "Tap to allow location suggestions."
        case .authorizedAlways, .authorizedWhenInUse:
            return coordinate == nil ? "Finding you..." : "Ready for nearby ideas."
        case .denied, .restricted:
            return "Enable location in Settings."
        @unknown default:
            return "Location unavailable."
        }
    }

    var permissionActionText: String {
        switch authorizationStatus {
        case .notDetermined:
            return "Use Current Location"
        case .denied, .restricted:
            return "Location Disabled"
        default:
            return "Finding Location"
        }
    }

    var permissionSymbolName: String {
        switch authorizationStatus {
        case .denied, .restricted:
            return "location.slash.fill"
        default:
            return "location.fill"
        }
    }
}

private struct ExploreActionItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let prompt: String
    let symbolName: String

    init(title: String, subtitle: String, prompt: String, symbolName: String) {
        self.id = "\(title)-\(prompt)"
        self.title = title
        self.subtitle = subtitle
        self.prompt = prompt
        self.symbolName = symbolName
    }
}

private struct ExploreCategory: Identifiable, Hashable {
    var id: String { title }
    let title: String
    let cardStyle: ExploreCardStyle
    let items: [ExploreActionItem]
}

private enum ExploreCardStyle: Hashable {
    case compact
    case square

    var width: CGFloat {
        switch self {
        case .compact: return 156
        case .square: return 260
        }
    }

    var height: CGFloat {
        switch self {
        case .compact: return 190
        case .square: return 148
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .compact: return 26
        case .square: return 24
        }
    }

    var padding: CGFloat {
        switch self {
        case .compact: return 16
        case .square: return 14
        }
    }

    var titleSize: CGFloat {
        switch self {
        case .compact: return 16
        case .square: return 15
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .compact: return 17
        case .square: return 16
        }
    }

    var iconWeight: Font.Weight {
        switch self {
        case .compact: return .semibold
        case .square: return .heavy
        }
    }

    var iconForegroundStyle: Color {
        switch self {
        case .compact: return TodoCardStyle.primaryBlue
        case .square: return .white
        }
    }

    func iconBackgroundColor(for item: ExploreActionItem) -> Color {
        switch self {
        case .compact:
            return TodoCardStyle.primaryBlueTint
        case .square:
            let palette: [Color] = [
                Color(red: 0.00, green: 0.48, blue: 1.00),
                Color(red: 0.20, green: 0.78, blue: 0.35),
                Color(red: 1.00, green: 0.58, blue: 0.00),
                Color(red: 0.69, green: 0.32, blue: 0.87),
                Color(red: 1.00, green: 0.23, blue: 0.19),
                Color(red: 0.00, green: 0.78, blue: 0.75)
            ]
            let seed = item.title.unicodeScalars.reduce(0) { $0 + Int($1.value) }
            return palette[seed % palette.count]
        }
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
        case .done: return "Passbook"
        }
    }

    var symbolName: String {
        switch self {
        case .todo: return "circle"
        case .scheduled: return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .done: return "menucard"
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
            return false
        }
    }
}

private struct SlidingSectionTitle: View {
    let selectedSection: TodoListSection

    private let titleWidth: CGFloat = 150

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TodoListSection.allCases) { section in
                Text(section.title)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .frame(width: titleWidth, alignment: .leading)
            }
        }
        .offset(x: -CGFloat(selectedSection.index) * titleWidth)
        .frame(width: titleWidth, alignment: .leading)
        .clipped()
        .animation(.easeInOut(duration: 0.18), value: selectedSection)
        .accessibilityLabel(selectedSection.title)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct SettingsTopOverlay: View {
    let onDismiss: () -> Void

    var body: some View {
        SettingsView(onDismiss: onDismiss)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
    }
}

private struct CronJobCard: View {
    let job: CronJob
    let onOpen: () -> Void
    let onTogglePause: () -> Void
    let onDelete: () -> Void

    private static let scheduleSymbol =
        "clock.arrow.trianglehead.counterclockwise.rotate.90"
    private static let cornerRadius: CGFloat = 30
    private static let footerBackground = Color(
        red: 0xF6 / 255,
        green: 0xF7 / 255,
        blue: 0xF9 / 255
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: TodoCardStyle.rowSpacing) {
                HStack(spacing: 8) {
                    Image(systemName: Self.scheduleSymbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(TodoCardStyle.muted)
                        .frame(width: 20, height: 20)

                    Spacer(minLength: 8)

                    topRowTrailing
                        .frame(
                            width: TodoCardStyle.connectionLogoChipSize,
                            height: TodoCardStyle.connectionLogoChipSize
                        )
                }

                Text(job.scheduleLabel)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(TodoCardStyle.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onOpen) {
                    Text(job.name)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.black)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(TodoCardStyle.cardPadding)
            .background {
                UnevenRoundedRectangle(
                    cornerRadii: .init(
                        topLeading: Self.cornerRadius,
                        bottomLeading: 0,
                        bottomTrailing: 0,
                        topTrailing: Self.cornerRadius
                    ),
                    style: .continuous
                )
                .fill(Color.white)
            }
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)

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
                    Button(action: onTogglePause) {
                        Image(systemName: job.state == .paused ? "play.fill" : "pause")
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(Color.black)
                            .frame(width: 38, height: 38)
                            .background(Color.white, in: Circle())
                            .overlay {
                                Circle()
                                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(job.state == .paused ? "Resume schedule" : "Pause schedule")
                }
            }
            .padding(.horizontal, TodoCardStyle.cardPadding)
            .padding(.vertical, 8)
            .background(Self.footerBackground)
        }
        .frame(maxWidth: .infinity, minHeight: 214, alignment: .topLeading)
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
            ConnectionLogosRow(slugs: [slug], chipSize: TodoCardStyle.connectionLogoChipSize)
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
    let onToggleComplete: () -> Void
    let onRespond: (_ interaction: TodoInteraction, _ optionID: String?, _ text: String?) -> Void

    var body: some View {
        if usesActiveFooterTreatment {
            activeBody
        } else {
            standardBody
        }
    }

    // MARK: Rows

    private var usesActiveFooterTreatment: Bool {
        todo.status.isActive && interaction == nil
    }

    private var standardBody: some View {
        VStack(alignment: .leading, spacing: TodoCardStyle.rowSpacing) {
            topRow
            titleRow
            bottomRow
        }
        .padding(TodoCardStyle.cardPadding)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: TodoCardStyle.cardCornerRadius, style: .continuous)
                .fill(Color.white)
        }
        .overlay {
            RoundedRectangle(cornerRadius: TodoCardStyle.cardCornerRadius, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
    }

    private var activeBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: TodoCardStyle.rowSpacing) {
                topRow
                titleRow
            }
            .padding(TodoCardStyle.cardPadding)
            .background {
                UnevenRoundedRectangle(
                    cornerRadii: .init(
                        topLeading: TodoCardStyle.cardCornerRadius,
                        bottomLeading: TodoCardStyle.cardCornerRadius,
                        bottomTrailing: TodoCardStyle.cardCornerRadius,
                        topTrailing: TodoCardStyle.cardCornerRadius
                    ),
                    style: .continuous
                )
                .fill(Color.white)
            }

            bottomRow
                .padding(.horizontal, TodoCardStyle.cardPadding)
                .padding(.vertical, 12)
                .background(TodoCardStyle.footerBackground)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: TodoCardStyle.cardCornerRadius, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: TodoCardStyle.cardCornerRadius, style: .continuous)
                .fill(TodoCardStyle.footerBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: TodoCardStyle.cardCornerRadius, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
    }

    private var titleRow: some View {
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
    }

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
        Group {
            if connectionSlugs.isEmpty {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.28))
                    .frame(width: 20, height: 20)
            } else {
                ConnectionLogosRow(slugs: connectionSlugs, chipSize: TodoCardStyle.connectionLogoChipSize)
            }
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
        } else if todo.status == .done {
            EmptyView()
        } else {
            HStack(alignment: .center, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    if usesActiveFooterTreatment {
                        ActivityLoadingDots()
                    }
                    Text(statusText)
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .foregroundStyle(TodoCardStyle.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(statusText)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .animation(.smooth(duration: 0.25), value: statusText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
    static let footerBackground = Color(
        red: 0xF6 / 255,
        green: 0xF7 / 255,
        blue: 0xF9 / 255
    )
    static let cardCornerRadius: CGFloat = 30
    /// Green used for the completed-todo toggle (iOS system green).
    static let completedGreen = Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
    /// Padding on all four sides of the card.
    static let cardPadding: CGFloat = 20
    /// Vertical gap between the three rows; keep equal so the card feels balanced.
    static let rowSpacing: CGFloat = 14
    static let connectionLogoChipSize: CGFloat = 28
}

private struct ActivityLoadingDots: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(TodoCardStyle.muted.opacity(isAnimating ? 0.9 : 0.35))
                    .frame(width: 4, height: 4)
                    .scaleEffect(isAnimating ? 1.0 : 0.72)
                    .animation(
                        .easeInOut(duration: 0.7)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.16),
                        value: isAnimating
                    )
            }
        }
        .frame(width: 18, height: 14)
        .onAppear { isAnimating = true }
        .onDisappear { isAnimating = false }
        .accessibilityHidden(true)
    }
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
    private let chipSize: CGFloat

    init(slugs: [String], chipSize: CGFloat = 24) {
        self.slugs = slugs
        self.chipSize = chipSize
    }

    init(slugs: [String], iconSize: CGFloat, spacing _: CGFloat) {
        self.slugs = slugs
        self.chipSize = iconSize + 8
    }

    private var overlap: CGFloat {
        chipSize * 0.25
    }

    var body: some View {
        if !slugs.isEmpty {
            HStack(spacing: -overlap) {
                ForEach(slugs, id: \.self) { slug in
                    ConnectionLogoChip(slug: slug, size: chipSize)
                }
            }
            .animation(.smooth(duration: 0.25), value: slugs)
        }
    }
}

private struct ConnectionLogoChip: View {
    let slug: String
    let size: CGFloat

    var body: some View {
        ConnectionLogo(slug: slug)
            .frame(width: size * 0.56, height: size * 0.56)
            .frame(width: size, height: size)
            .background(Color.white, in: Circle())
            .overlay {
                Circle()
                    .strokeBorder(Color.black.opacity(0.10), lineWidth: 1)
            }
            .accessibilityLabel("Connection: \(slug)")
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
        case .done: return "menucard"
        }
    }

    private var title: String {
        switch section {
        case .todo: return "No tasks yet"
        case .scheduled: return "No scheduled tasks"
        case .done: return "Explore"
        }
    }

    private var subtitle: String {
        switch section {
        case .todo:
            return "Tap + to add something. The agent prepares each task and starts working right away — tap a row to follow along."
        case .scheduled:
            return "Recurring automations like daily email checks will appear here when the agent sets them up."
        case .done:
            return "New discovery tools will live here soon."
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
