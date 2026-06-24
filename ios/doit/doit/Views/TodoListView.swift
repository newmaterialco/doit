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

private enum TopicSurfaceSelection: Identifiable, Hashable {
    case task(SuggestedCategory)
    case scheduled(ScheduledPromptCategory)

    var id: String {
        switch self {
        case .task(let category):
            return "task-\(category.id)"
        case .scheduled(let category):
            return "scheduled-\(category.id)"
        }
    }
}

struct TodoListView: View {
    let userID: UUID

    @Environment(AuthModel.self) private var auth
    @Environment(TodoStore.self) private var store
    @Environment(PushManager.self) private var push
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(\.scenePhase) private var scenePhase

    @State private var addTodoComposer: AddTodoSheetPresentation?
    @State private var isAddTodoComposerExpanded = false
    @State private var isAddTodoComposerContentVisible = false
    @State private var rendersAddTodoOverlay = true
    @State private var isAddTodoOverlayVisible = true
    @State private var showSettings = false
    @State private var settingsSheetIsVisible = false
    @State private var settingsInitialRoute: SettingsRoute?
    @State private var settingsPresentationToken = 0
    @State private var selectedCompletedActivityFilter: CompletedActivityFilter = .allActivity
    @State private var selectedActivityGroup: ActivityGroupDescriptor?
    @State private var showActivityGroupDetail = false
    @State private var activityGroupDetailIsVisible = false
    @State private var selectedTopicSurface: TopicSurfaceSelection?
    @State private var taskTopicSurfaceIsVisible = false
    @State private var taskTopicHomeIsScaled = false
    @State private var selectedSectionID: Int? = TodoListSection.todo.index
    @State private var scrubbedSectionID: Int?
    @State private var navigationPath = NavigationPath()
    @State private var deletingTodoIDs: Set<UUID> = []
    @State private var showPassbookMemoryDetail = false
    @State private var selectedPassbookMemory: AgentMemory?
    @State private var passbookMemoryIsEditing = false
    @State private var passbookMemoryDraftTitle = ""
    @State private var passbookMemoryDraftBody = ""
    @AppStorage("onboarding.connectionsPromoDismissed") private var connectionsPromoDismissed = false
    @State private var exploreToolkits: [Toolkit] = []
    @State private var exploreToolkitsLoading = true
    @State private var exploreToolkitsHasLoaded = false
    @State private var exploreError: String?
    @State private var exploreBusySlug: String?
    @State private var exploreOAuthSession: ASWebAuthenticationSession?
    @State private var exploreApiKeyToolkit: Toolkit?
    @State private var exploreApiKeyInput = ""
    @State private var exploreApiKeyError: String?
    @State private var activeCronHandoff: CronHandoff?
    @State private var completedCronHandoffGeometryIDs: Set<String> = []
    @State private var isPullRefreshing = false
    @StateObject private var locationProvider = LocationProvider()
    @Namespace private var taskCardNamespace

    var body: some View {
        ZStack(alignment: .top) {
            NavigationStack(path: $navigationPath) {
                ZStack {
                    AppSemanticColors.screenBackground
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
                            .scrollDisabled(taskTopicSurfaceIsVisible)
                            .ignoresSafeArea(.container, edges: [.top, .bottom])
                        }
                        .ignoresSafeArea(.container, edges: [.top, .bottom])

                        VStack {
                            topControls
                            Spacer()
                            bottomControls
                        }
                    }
                    .offset(y: presentationHomeOffset)
                    .animation(settingsPresentationAnimation, value: settingsSheetIsVisible)
                    .animation(settingsPresentationAnimation, value: activityGroupDetailIsVisible)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: TodoListDestination.self) { destination in
                    switch destination {
                    case .todo(let id):
                        TodoDetailView(
                            todoID: id,
                            initialChatExpanded: store.prefersChatExpanded(for: id)
                        )
                    case .cronJob(let id):
                        CronJobDetailView(jobID: id)
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
                .onAppear {
                    updateAddTodoOverlayVisibility(shouldShowAddTodoOverlay, animated: false)
                }
                .onChange(of: selectedSectionID) { _, newValue in
                    guard newValue != nil else { return }
                    playSectionHaptic()
                    if newValue == TodoListSection.done.index {
                        Task { await prepareExploreIfNeeded() }
                    }
                }
                .onChange(of: shouldShowAddTodoOverlay) { _, visible in
                    updateAddTodoOverlayVisibility(visible)
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
                    Task {
                        await store.refreshForForeground()
                        await refreshConnectionsPromoState()
                    }
                }
                .onChange(of: hasAnyConnection) { _, connected in
                    guard connected else { return }
                    dismissConnectionsPromo()
                }
                .onChange(of: cronHandoffSignature) { _, _ in
                    reconcilePendingCronHandoff()
                }
                .onChange(of: store.cronHandoffRevision) { _, _ in
                    reconcilePendingCronHandoff()
                }
                .onChange(of: push.pendingTodoID) { _, newID in
                    guard let id = newID else { return }
                    // Push tap → open that todo. Refresh its row first so the
                    // detail view doesn't render against a stale list snapshot.
                    Task { await store.refreshTodoSurfaceWithRetry(id: id) }
                    navigationPath.append(TodoListDestination.todo(id))
                    push.pendingTodoID = nil
                }
                .onReceive(NotificationCenter.default.publisher(for: .todoRemoteUpdate)) { note in
                    // Foreground push: refresh the affected todo's full list
                    // surface instead of reloading the whole list. Falls back
                    // to a full reload if the payload didn't carry a todo id.
                    if let id = TodoRemoteUpdate.todoID(from: note) {
                        print("[list] push refresh todo=\(id)")
                        Task { await store.refreshTodoSurfaceWithRetry(id: id) }
                    } else {
                        print("[list] push refresh (no id) → full reload")
                        Task { await store.loadAll() }
                    }
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .scaleEffect(taskTopicHomeIsScaled ? 0.97 : 1, anchor: .top)
            .opacity(taskTopicSurfaceIsVisible ? 0 : 1)
            .allowsHitTesting(!taskTopicSurfaceIsVisible)
            .animation(taskTopicTransitionAnimation, value: taskTopicSurfaceIsVisible)

            if let selectedTopicSurface {
                topicSurface(for: selectedTopicSurface)
                    .scaleEffect(taskTopicSurfaceIsVisible ? 1 : 1.02)
                    .opacity(taskTopicSurfaceIsVisible ? 1 : 0)
                    .allowsHitTesting(taskTopicSurfaceIsVisible)
                    .animation(taskTopicTransitionAnimation, value: taskTopicSurfaceIsVisible)
                    .zIndex(6)
            }

            if showPassbookMemoryDetail, let selectedPassbookMemory {
                memoryDetailBackdrop
                    .transition(.opacity)
                    .zIndex(6)

                memoryDetailPanel(for: selectedPassbookMemory)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(7)
                    .onAppear {
                        print("[passbook][memory] detail overlay appeared id=\(selectedPassbookMemory.id)")
                    }
            }

            if showSettings {
                AppSemanticColors.surface
                    .ignoresSafeArea()
                    .opacity(settingsSheetIsVisible ? 1 : 0)
                    .animation(settingsPresentationAnimation, value: settingsSheetIsVisible)
                    .zIndex(9)

                SettingsTopOverlay(
                    initialRoute: settingsInitialRoute,
                    onDismiss: dismissSettings
                )
                    .id(settingsPresentationToken)
                    .offset(y: settingsSheetOffset)
                    .zIndex(10)
            }

            if showActivityGroupDetail, let selectedActivityGroup {
                AppSemanticColors.surface
                    .ignoresSafeArea()
                    .opacity(activityGroupDetailIsVisible ? 1 : 0)
                    .animation(settingsPresentationAnimation, value: activityGroupDetailIsVisible)
                    .zIndex(8)

                activityGroupDetailOverlay(for: selectedActivityGroup)
                    .offset(y: activityGroupDetailOffset)
                    .zIndex(9)
            }

            if rendersAddTodoOverlay {
                AddTodoMorphOverlay(
                    isExpanded: isAddTodoComposerExpanded,
                    isContentVisible: isAddTodoComposerContentVisible,
                    isVisible: isAddTodoOverlayVisible,
                    presentation: addTodoComposer,
                    userID: userID,
                    onExpand: { openAddComposer() },
                    onDismiss: dismissAddComposer,
                    onCreated: { newTodo in
                        store.insertOptimistic(newTodo)
                        selectedSectionID = TodoListSection.todo.index
                    }
                )
                .scaleEffect(taskTopicHomeIsScaled ? 0.97 : 1, anchor: .bottom)
                .opacity(taskTopicSurfaceIsVisible ? 0 : 1)
                .allowsHitTesting(!taskTopicSurfaceIsVisible)
                .animation(taskTopicTransitionAnimation, value: taskTopicSurfaceIsVisible)
                .offset(y: presentationHomeOffset)
                .animation(settingsPresentationAnimation, value: settingsSheetIsVisible)
                .animation(settingsPresentationAnimation, value: activityGroupDetailIsVisible)
                .zIndex(isAddTodoComposerExpanded ? 11 : 5)
            }
        }
    }

    private var topControls: some View {
        ZStack(alignment: .top) {
            AppSemanticColors.screenBackground
            .frame(height: 114)
            .ignoresSafeArea(.container, edges: .top)

            HStack {
                SlidingSectionTitle(selectedSection: selectedSection)

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        playFirmHaptic()
                        presentSettings(route: .feedback)
                    } label: {
                        Image(systemName: "ladybug.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppSemanticColors.mutedChrome)
                            .frame(width: 32, height: 32)
                            .background(AppSemanticColors.neutralFill, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Beta feedback")

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
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Profile")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    private var selectedSection: TodoListSection {
        TodoListSection.allCases.first { $0.index == selectedSectionID }
            ?? .todo
    }

    private var shouldShowAddTodoOverlay: Bool {
        guard
            navigationPath.count == 0,
            let selectedSectionID,
            let section = TodoListSection.allCases.first(where: { $0.index == selectedSectionID })
        else { return false }

        return section.allowsAddTodoComposer
    }

    private var fabPresenceAnimation: Animation {
        shouldShowAddTodoOverlay
            ? AddTodoComposerMotion.fabAppear
            : AddTodoComposerMotion.fabDisappear
    }

    private func updateAddTodoOverlayVisibility(_ visible: Bool, animated: Bool = true) {
        if visible {
            rendersAddTodoOverlay = true
            let show = { isAddTodoOverlayVisible = true }
            if animated {
                DispatchQueue.main.async {
                    withAnimation(AddTodoComposerMotion.fabAppear, show)
                }
            } else {
                show()
            }
        } else {
            let hide = { isAddTodoOverlayVisible = false }
            if animated {
                withAnimation(AddTodoComposerMotion.fabDisappear, hide)
            } else {
                hide()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + AddTodoComposerMotion.fabDisappearDuration) {
                if !shouldShowAddTodoOverlay {
                    rendersAddTodoOverlay = false
                }
            }
        }
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
        let shouldShowInitialSkeleton = store.isInitialLoading && activeItems.isEmpty && completedItems.isEmpty
        return ZStack(alignment: .top) {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if let loadError = store.loadError {
                            Text(loadError)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if shouldShowInitialSkeleton {
                            TaskListLoadingSkeleton()
                        } else {
                            ForEach(activeItems) { todo in
                                todoCard(for: todo)
                            }

                            VStack(spacing: 10) {
                                TaskSectionHeader(
                                    title: "Topics",
                                    titleSuffix: "Coming soon",
                                    verticalPadding: 0
                                )

                                SuggestedCategoryStrip(
                                    categories: SuggestedCategoryCatalog.taskCategories,
                                    onSelect: handleTaskCategorySelection
                                )
                            }
                            .padding(.top, 6)

                            if shouldShowConnectionsPromo {
                                ExploreConnectionsPromoCard(
                                    onSetup: {
                                        dismissConnectionsPromo()
                                        presentSettings(route: .connections)
                                    },
                                    onDismiss: dismissConnectionsPromo
                                )
                                .padding(.top, 10)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }

                            completedTasksSection(completedItems)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 116)
                    .padding(.bottom, DockStyle.scrollBottomInset)
                    .animation(.smooth(duration: 0.34), value: taskLayoutSignature)
                    .animation(.smooth(duration: 0.34), value: shouldShowConnectionsPromo)
                }
                .refreshable {
                    await refreshTaskListFromPull()
                }

                if isPullRefreshing {
                    PullRefreshSpinner()
                        .padding(.top, PullRefreshSpinnerStyle.topPadding)
                }
            }
            .onChange(of: store.todos.isEmpty) { wasEmpty, isEmpty in
                guard isEmpty, !wasEmpty else { return }
                selectedCompletedActivityFilter = .allActivity
            }
            .task {
                await loadExploreToolkits(showSpinner: false)
            }
    }

    @ViewBuilder
    private func completedTasksSection(_ completedItems: [Todo]) -> some View {
        if completedItems.isEmpty {
            EmptyState(section: .todo)
        } else {
            completedActivitySection(completedItems)
        }
    }

    private var hasAnyConnection: Bool {
        exploreToolkits.contains { $0.isConnectable && $0.connected }
    }

    private var shouldShowConnectionsPromo: Bool {
        guard exploreToolkitsHasLoaded, !connectionsPromoDismissed else { return false }
        return !hasAnyConnection
    }

    private func dismissConnectionsPromo() {
        connectionsPromoDismissed = true
    }

    @ViewBuilder
    private func completedActivitySection(_ completedItems: [Todo]) -> some View {
        let showingCategories = selectedCompletedActivityFilter == .topics

        VStack(spacing: 10) {
            TaskSectionHeader(
                title: "Recent",
                trailingIconName: showingCategories ? nil : "Category_Logo",
                trailingLabel: showingCategories ? "Hide categories" : nil,
                trailingAction: toggleCompletedActivityView,
                trailingAccessibilityLabel: showingCategories ? "Hide categories" : "Show categories",
                trailingIconCompact: true,
                trailingSwapsInstantly: true,
                verticalPadding: 0
            )
            .transaction { transaction in
                transaction.disablesAnimations = true
            }

            Group {
                switch selectedCompletedActivityFilter {
                case .allActivity:
                    VStack(spacing: 10) {
                        ForEach(completedItems) { todo in
                            todoCard(for: todo, identityScope: CompletedActivityFilter.allActivity.rawValue)
                        }
                    }
                case .topics:
                    let summaries = activityGroupSummaries(from: completedItems)
                    if summaries.isEmpty {
                        ActivityEmptyCard(
                            title: "No categories yet",
                            message: "Recent tasks will appear here once doit assigns categories or collections.",
                            systemImage: "square.grid.2x2.fill"
                        )
                    } else {
                        ActivityGroupGrid(summaries: summaries) { descriptor in
                            playLightHaptic()
                            presentActivityGroup(descriptor)
                        }
                        .padding(.top, 2)
                    }
                }
            }
            .id(selectedCompletedActivityFilter.rawValue)
            .transition(activityToggleTransition)
        }
        .padding(.top, 6)
    }

    private var activityToggleTransition: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.96, anchor: .center).combined(with: .opacity),
            removal: .scale(scale: 0.98, anchor: .center).combined(with: .opacity)
        )
    }

    @ViewBuilder
    private func todoCard(
        for todo: Todo,
        identityScope: String? = nil,
        onOpenOverride: (() -> Void)? = nil
    ) -> some View {
        // Read the latest row from the store so prep / realtime updates
        // aren't stuck behind a ForEach snapshot. Cron cards already use
        // `cronJobRefreshID`; todo cards need the same refresh id pattern.
        let liveTodo = store.todo(id: todo.id) ?? todo
        let interaction = store.openInteractions[liveTodo.id]
        let activity = store.agentActivityByTodoID[liveTodo.id]
        let isDeleting = deletingTodoIDs.contains(liveTodo.id)
        let refreshID = cardRefreshID(for: liveTodo)
        let viewID = identityScope.map { "\($0):\(refreshID)" } ?? refreshID
        let artifacts = store.artifactsByTodoID[liveTodo.id] ?? []
        TodoCard(
            todo: liveTodo,
            connectionSlugs: connectionSlugs(for: liveTodo),
            artifacts: artifacts,
            interaction: interaction,
            activity: activity,
            isResponding: store.respondingInteractionID != nil
                && store.respondingInteractionID == interaction?.id,
            onOpen: {
                playLightHaptic()
                if let onOpenOverride {
                    onOpenOverride()
                } else {
                    navigationPath.append(TodoListDestination.todo(liveTodo.id))
                }
            },
            onDoIt: { Task { await store.request(liveTodo) } },
            onToggleComplete: { Task { await store.toggleComplete(liveTodo) } },
            onRespond: { interaction, optionID, text in
                Task {
                    await store.respond(
                        to: interaction,
                        todo: liveTodo,
                        optionID: optionID,
                        text: text
                    )
                }
            }
        )
        .id(viewID)
        .modifier(
            OptionalMatchedGeometryEffect(
                id: identityScope == nil ? (cronHandoffGeometryID(forTodo: liveTodo.id) ?? liveTodo.id.uuidString) : nil,
                namespace: taskCardNamespace,
                isSource: true
            )
        )
        .opacity(isDeleting ? 0 : 1)
        .scaleEffect(isDeleting ? 0.96 : 1)
        .offset(x: isDeleting ? 28 : 0)
        .allowsHitTesting(!isDeleting && cronHandoffGeometryID(forTodo: liveTodo.id) == nil)
        .animation(.smooth(duration: 0.24), value: isDeleting)
        .contextMenu {
            todoContextMenuAction(for: liveTodo)
        }
    }

    private var exploreSectionPage: some View {
        ZStack(alignment: .top) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let exploreError {
                        Text(exploreError)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    PassbookUserContactCard(
                        initials: auth.initials,
                        displayName: auth.displayName,
                        avatarImageData: auth.avatarImageData,
                        avatarURL: auth.avatarURL,
                        joinedAt: auth.joinedAt,
                        locationText: locationProvider.displayLocationText,
                        onLocationTap: handlePassbookLocationTap
                    )

                    PassbookMemorySection(
                        memories: passbookMemories,
                        onSelect: { memory in
                            print("[passbook][memory] selected row id=\(memory.id) title=\(memory.title)")
                            presentMemoryDetail(memory)
                        }
                    )

                }
                .padding(.horizontal, 16)
                .padding(.top, 116)
                .padding(.bottom, DockStyle.scrollBottomInset)
            }
            .refreshable {
                await refreshExploreFromPull()
            }

            if isPullRefreshing {
                PullRefreshSpinner()
                    .padding(.top, PullRefreshSpinnerStyle.topPadding)
            }
        }
    }

    private var passbookMemories: [AgentMemory] {
        store.memories
            .filter { $0.effectiveTarget == .user }
            .filter { $0.effectiveMemoryStatus == .active || $0.effectiveMemoryStatus == .proposed }
            .sorted { $0.updated_at > $1.updated_at }
    }

    private var scheduledSectionPage: some View {
        ZStack(alignment: .top) {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if let loadError = store.loadError {
                            Text(loadError)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        TaskSectionHeader(title: "Suggested", verticalPadding: 0)
                            .padding(.top, 6)

                        SuggestedCategoryStrip(
                            categories: SuggestedCategoryCatalog.scheduledCategories,
                            onSelect: handleScheduledCategorySelection
                        )
                        .padding(.bottom, 2)

                        if store.isInitialLoading && store.cronJobs.isEmpty {
                            TaskListLoadingSkeleton()
                                .padding(.top, 8)
                        } else if store.cronJobs.isEmpty && store.loadError == nil {
                            EmptyState(section: .scheduled)
                                .padding(.top, 8)
                        } else if !store.cronJobs.isEmpty {
                            LazyVGrid(
                                columns: [
                                    GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)
                                ],
                                spacing: 10
                            ) {
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
                                    .modifier(
                                        OptionalMatchedGeometryEffect(
                                            id: cronHandoffGeometryID(forCronJob: job.id),
                                            namespace: taskCardNamespace,
                                            isSource: false
                                        )
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
                            .padding(.top, 8)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 116)
                    .padding(.bottom, DockStyle.scrollBottomInset)
                }
                .refreshable { await refreshTaskListFromPull() }

                if isPullRefreshing {
                    PullRefreshSpinner()
                        .padding(.top, PullRefreshSpinnerStyle.topPadding)
                }
            }
    }

    private var bottomControls: some View {
        VStack(spacing: 0) {
            if shouldShowAddTodoOverlay && !isAddTodoComposerExpanded {
                Color.clear
                    .frame(height: DockStyle.fabClearanceHeight)
            }
            dockControls
        }
        .animation(fabPresenceAnimation, value: shouldShowAddTodoOverlay)
    }

    private enum DockStyle {
        static let buttonWidth: CGFloat = 44
        static let buttonHeight: CGFloat = 40
        static let barHorizontalPadding: CGFloat = 56
        static let barTopPadding: CGFloat = 8
        static let barBottomPadding: CGFloat = 4
        static let topBorderHeight: CGFloat = 0.5
        static let fabGapAboveDock: CGFloat = 12
        static let scrollBottomExtraPadding: CGFloat = 16
        static var barHeight: CGFloat { barTopPadding + buttonHeight + barBottomPadding }
        static var fabClearanceHeight: CGFloat { barHeight + fabGapAboveDock }
        /// Clears the floating add button, dock bar, and a little breathing room.
        static var scrollBottomInset: CGFloat {
            fabClearanceHeight + barHeight + scrollBottomExtraPadding
        }
    }

    private var dockControls: some View {
        HStack(spacing: 0) {
            ForEach(TodoListSection.allCases) { section in
                dockButton(section)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, DockStyle.barHorizontalPadding)
        .padding(.top, DockStyle.barTopPadding)
        .padding(.bottom, DockStyle.barBottomPadding)
        .frame(maxWidth: .infinity)
        .background {
            AppSemanticColors.screenBackground
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppSemanticColors.separator.opacity(0.35))
                .frame(height: DockStyle.topBorderHeight)
        }
        .contentShape(Rectangle())
        .background {
            GeometryReader { proxy in
                Color.clear
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 6)
                            .onChanged { value in
                                scrubDock(at: value.location.x, dockWidth: proxy.size.width)
                            }
                            .onEnded { value in
                                scrubDock(at: value.location.x, dockWidth: proxy.size.width)
                                commitDockScrub()
                            }
                    )
            }
        }
    }

    private func dockButton(_ section: TodoListSection) -> some View {
        let isSelected = selectedSectionID == section.index
        return Button {
            selectedSectionID = section.index
        } label: {
            Image(systemName: section.symbolName)
                .font(.title2.weight(.semibold))
                .frame(width: DockStyle.buttonWidth, height: DockStyle.buttonHeight)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .opacity(isSelected ? 1 : 0.55)
        }
        .buttonStyle(DockButtonStyle())
        .contentShape(Circle())
        .accessibilityLabel(section.title)
    }

    private func scrubDock(at xPosition: CGFloat, dockWidth: CGFloat) {
        let sectionCount = TodoListSection.allCases.count
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

    private func toggleCompletedActivityView() {
        playSectionHaptic()
        withAnimation(.smooth(duration: 0.22)) {
            selectedCompletedActivityFilter = selectedCompletedActivityFilter == .allActivity
                ? .topics
                : .allActivity
        }
    }

    private func playLightHaptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func playFirmHaptic() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.9)
    }

    private var taskTopicTransitionAnimation: Animation {
        .easeInOut(duration: 0.18)
    }

    private func handleTaskCategorySelection(_ category: SuggestedCategory) {
        presentTopicSurface(.task(category))
    }

    private func presentTopicSurface(_ selection: TopicSurfaceSelection) {
        playFirmHaptic()
        selectedTopicSurface = selection
        DispatchQueue.main.async {
            withAnimation(taskTopicTransitionAnimation) {
                taskTopicHomeIsScaled = true
                taskTopicSurfaceIsVisible = true
            }
        }
    }

    private func dismissTopicSurface() {
        playFirmHaptic()
        taskTopicHomeIsScaled = false
        withAnimation(taskTopicTransitionAnimation) {
            taskTopicSurfaceIsVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            if !taskTopicSurfaceIsVisible {
                selectedTopicSurface = nil
            }
        }
    }

    private func topicSurface(for selection: TopicSurfaceSelection) -> some View {
        GeometryReader { _ in
            ZStack {
                topicSurfaceBackgroundColor
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    topicSurfaceHeader(for: selection)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 12)

                    ZStack {
                        if case .task = selection {
                            Text("Coming soon")
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }

                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                topicSurfaceContent(for: selection)

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .padding(.bottom, DockStyle.scrollBottomInset)
                        }
                        .scrollIndicators(.hidden)
                    }
                }
            }
        }
    }

    private var topicSurfaceBackgroundColor: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)
                : UIColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1)
        })
    }

    private func topicSurfaceHeader(for selection: TopicSurfaceSelection) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(topicSurfaceTitle(for: selection))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: dismissTopicSurface) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.9))
                    .frame(width: 36, height: 36)
                    .background(Color.primary.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(topicSurfaceTitle(for: selection))")
        }
    }

    @ViewBuilder
    private func topicSurfaceContent(for selection: TopicSurfaceSelection) -> some View {
        switch selection {
        case .task(let category):
            TaskTopicIntroCard(category: category)
        case .scheduled(let category):
            LazyVStack(spacing: 10) {
                ForEach(category.prompts) { prompt in
                    ScheduledPromptOptionRow(
                        prompt: prompt,
                        accentColor: category.promptAccentColor,
                        onSelect: { handleScheduledPromptSelection(prompt) }
                    )
                }
            }
        }
    }

    private func topicSurfaceTitle(for selection: TopicSurfaceSelection) -> String {
        switch selection {
        case .task(let category):
            return category.title
        case .scheduled(let category):
            return category.name
        }
    }

    private func handleScheduledCategorySelection(_ category: SuggestedCategory) {
        guard let scheduledCategory = SuggestedCategoryCatalog.scheduledPromptCategories.first(where: { $0.id == category.id }) else {
            return
        }
        presentTopicSurface(.scheduled(scheduledCategory))
    }

    private func handleScheduledPromptSelection(_ prompt: ScheduledPromptSuggestion) {
        UISelectionFeedbackGenerator().selectionChanged()
        taskTopicHomeIsScaled = false
        withAnimation(taskTopicTransitionAnimation) {
            taskTopicSurfaceIsVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            if !taskTopicSurfaceIsVisible {
                selectedTopicSurface = nil
                openAddComposer(title: prompt.composerPrompt, action: .note)
            }
        }
    }

    private var addTodoComposerAnimation: Animation {
        AddTodoComposerMotion.morph
    }

    private var settingsPresentationAnimation: Animation {
        .easeInOut(duration: 0.28)
    }

    private var settingsSheetOffset: CGFloat {
        settingsSheetIsVisible ? 0 : -UIScreen.main.bounds.height
    }

    private var activityGroupDetailOffset: CGFloat {
        activityGroupDetailIsVisible ? 0 : -UIScreen.main.bounds.height
    }

    private var presentationHomeOffset: CGFloat {
        (settingsSheetIsVisible || activityGroupDetailIsVisible) ? UIScreen.main.bounds.height : 0
    }

    private func presentSettings(route: SettingsRoute? = nil) {
        settingsInitialRoute = route
        settingsPresentationToken += 1
        showSettings = true
        DispatchQueue.main.async {
            withAnimation(settingsPresentationAnimation) {
                settingsSheetIsVisible = true
            }
        }
    }

    private func handlePassbookLocationTap() {
        playLightHaptic()
        switch locationProvider.authorizationStatus {
        case .denied, .restricted:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        default:
            locationProvider.requestAuthorizationOrLocation()
        }
    }

    private func presentActivityGroup(_ descriptor: ActivityGroupDescriptor) {
        selectedActivityGroup = descriptor
        showActivityGroupDetail = true
        DispatchQueue.main.async {
            withAnimation(settingsPresentationAnimation) {
                activityGroupDetailIsVisible = true
            }
        }
    }

    private func dismissActivityGroupDetail() {
        withAnimation(settingsPresentationAnimation) {
            activityGroupDetailIsVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            if !activityGroupDetailIsVisible {
                showActivityGroupDetail = false
                selectedActivityGroup = nil
            }
        }
    }

    private func openTodoFromActivityGroup(_ todo: Todo) {
        activityGroupDetailIsVisible = false
        showActivityGroupDetail = false
        selectedActivityGroup = nil
        navigationPath.append(TodoListDestination.todo(todo.id))
    }

    private func dismissSettings() {
        withAnimation(settingsPresentationAnimation) {
            settingsSheetIsVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            if !settingsSheetIsVisible {
                showSettings = false
                settingsInitialRoute = nil
                Task { await refreshConnectionsPromoState() }
            }
        }
    }

    private func refreshConnectionsPromoState() async {
        if let cached = IntegrationsAPI.cachedToolkits {
            exploreToolkits = cached
        }
        await loadExploreToolkits(showSpinner: false, force: true)
    }

    private var memoryDetailBackdrop: some View {
        Color.black.opacity(0.16)
            .ignoresSafeArea(.all)
            .contentShape(Rectangle())
            .onTapGesture {
                playLightHaptic()
                dismissMemoryDetail()
            }
    }

    private func memoryDetailPanel(for memory: AgentMemory) -> some View {
        VStack {
            Spacer()
            PassbookMemoryDetailCard(
                memory: memory,
                isEditing: $passbookMemoryIsEditing,
                draftTitle: $passbookMemoryDraftTitle,
                draftBody: $passbookMemoryDraftBody,
                onClose: {
                    playLightHaptic()
                    dismissMemoryDetail()
                },
                onEdit: {
                    passbookMemoryDraftTitle = memory.title
                    passbookMemoryDraftBody = memory.body
                    passbookMemoryIsEditing = true
                },
                onSave: {
                    Task { await savePassbookMemory(memory) }
                },
                onForget: {
                    Task {
                        await store.forgetMemory(memory)
                        dismissMemoryDetail()
                    }
                }
            )
            .padding(.horizontal, 18)
            .padding(.bottom, 20)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private func activityGroupDetailOverlay(for descriptor: ActivityGroupDescriptor) -> some View {
        let todos = activityTodos(for: descriptor)
        return VStack(spacing: 0) {
            ActivityGroupDetailHeader(
                descriptor: descriptor,
                count: todos.count,
                onDismiss: {
                    playLightHaptic()
                    dismissActivityGroupDetail()
                }
            )
            ZStack(alignment: .top) {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(todos) { todo in
                            todoCard(for: todo) {
                                openTodoFromActivityGroup(todo)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, DockStyle.scrollBottomInset)
                }
                .refreshable { await refreshTaskListFromPull() }

                if isPullRefreshing {
                    PullRefreshSpinner()
                        .padding(.top, 18)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppSemanticColors.surface)
    }

    private func presentMemoryDetail(_ memory: AgentMemory) {
        print("[passbook][memory] presenting detail id=\(memory.id) title=\(memory.title)")
        playLightHaptic()
        passbookMemoryDraftTitle = memory.title
        passbookMemoryDraftBody = memory.body
        passbookMemoryIsEditing = false
        selectedPassbookMemory = memory
        DispatchQueue.main.async {
            withAnimation(settingsPresentationAnimation) {
                showPassbookMemoryDetail = true
            }
        }
    }

    private func dismissMemoryDetail() {
        withAnimation(settingsPresentationAnimation) {
            showPassbookMemoryDetail = false
            passbookMemoryIsEditing = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if !showPassbookMemoryDetail {
                selectedPassbookMemory = nil
            }
        }
    }

    private func savePassbookMemory(_ memory: AgentMemory) async {
        let title = passbookMemoryDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = passbookMemoryDraftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !body.isEmpty else { return }
        await store.updateMemory(memory, title: title, body: body)
        passbookMemoryIsEditing = false
        selectedPassbookMemory = store.memories.first { $0.id == memory.id } ?? memory
    }

    private func playSectionHaptic() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func refreshTaskListFromPull() async {
        await performPullRefresh {
            await store.loadAll()
        }
    }

    private func refreshExploreFromPull() async {
        await performPullRefresh {
            locationProvider.refreshIfAuthorized()
            await store.refreshMemories()
        }
    }

    private func performPullRefresh(_ operation: () async -> Void) async {
        isPullRefreshing = true
        defer { isPullRefreshing = false }
        await operation()
    }

    private var activeTodos: [Todo] {
        store.todos.filter { $0.status != .done && $0.status != .cancelled }
    }

    private var completedTodos: [Todo] {
        store.todos.filter { $0.status == .done || $0.status == .cancelled }.sorted { lhs, rhs in
            let lhsDate = completedActivityDate(for: lhs)
            let rhsDate = completedActivityDate(for: rhs)
            if lhsDate == rhsDate {
                return lhs.created_at > rhs.created_at
            }
            return lhsDate > rhsDate
        }
    }

    private func completedActivityDate(for todo: Todo) -> Date {
        todo.completed_at ?? todo.updated_at
    }

    private func activityGroupSummaries(from completedItems: [Todo]) -> [ActivityGroupSummary] {
        let collections = Dictionary(grouping: completedItems.compactMap { todo -> (String, Todo)? in
            guard let name = todo.normalizedCollectionName else { return nil }
            return (name, todo)
        }, by: { $0.0 })
            .map { name, pairs in
                let todos = pairs.map { $0.1 }.sorted(by: activitySort)
                return ActivityGroupSummary(
                    descriptor: .collection(name),
                    count: todos.count,
                    previewTitles: todos.prefix(3).map(\.title),
                    latestUpdate: todos.first?.updated_at ?? .distantPast
                )
            }
            .sorted { lhs, rhs in
                if lhs.latestUpdate == rhs.latestUpdate {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.latestUpdate > rhs.latestUpdate
            }

        let topics = Dictionary(grouping: completedItems, by: \.effectiveTopic)
            .map { topic, todos in
                let sortedTodos = todos.sorted(by: activitySort)
                return ActivityGroupSummary(
                    descriptor: .topic(topic),
                    count: sortedTodos.count,
                    previewTitles: sortedTodos.prefix(3).map(\.title),
                    latestUpdate: sortedTodos.first?.updated_at ?? .distantPast
                )
            }
            .sorted { lhs, rhs in
                if lhs.latestUpdate == rhs.latestUpdate {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.latestUpdate > rhs.latestUpdate
            }

        return collections + topics
    }

    private func activityTodos(for descriptor: ActivityGroupDescriptor) -> [Todo] {
        completedTodos.filter { todo in
            switch descriptor.kind {
            case .collection(let name):
                return todo.normalizedCollectionName?.caseInsensitiveCompare(name) == .orderedSame
            case .topic(let topic):
                return todo.effectiveTopic == topic
            }
        }
    }

    private func activitySort(_ lhs: Todo, _ rhs: Todo) -> Bool {
        if lhs.updated_at == rhs.updated_at {
            return lhs.created_at > rhs.created_at
        }
        return lhs.updated_at > rhs.updated_at
    }

    private var taskLayoutSignature: String {
        store.todos
            .map { "\($0.id.uuidString):\($0.status.rawValue):\($0.topic ?? ""):\($0.collection_name ?? ""):\($0.updated_at.ISO8601Format())" }
            .joined(separator: "|")
    }

    private var cronHandoffSignature: String {
        [
            store.pendingNewTodoID?.uuidString ?? "",
            store.pendingNewTodoCronCandidateID()?.uuidString ?? "",
            store.todos.map(\.id.uuidString).joined(separator: ","),
            store.cronJobs.map { "\($0.id.uuidString):\($0.created_at.ISO8601Format())" }.joined(separator: ",")
        ].joined(separator: "|")
    }

    private func openAddComposer(title: String = "", action: AddTodoLaunchAction = .note) {
        playLightHaptic()
        isAddTodoComposerContentVisible = false
        addTodoComposer = AddTodoSheetPresentation(title: title, action: action)
        withAnimation(addTodoComposerAnimation) {
            isAddTodoComposerExpanded = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + AddTodoComposerMotion.contentRevealDelay) {
            guard isAddTodoComposerExpanded else { return }
            withAnimation(AddTodoComposerMotion.contentReveal) {
                isAddTodoComposerContentVisible = true
            }
        }
    }

    private func dismissAddComposer() {
        isAddTodoComposerContentVisible = false
        withAnimation(addTodoComposerAnimation) {
            isAddTodoComposerExpanded = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + AddTodoComposerMotion.dismissCleanupDelay) {
            if !isAddTodoComposerExpanded {
                addTodoComposer = nil
            }
        }
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
            connectivity.reportSuccess()
        } catch where IntegrationsAPI.isCancellation(error) {
            print("[integrations][explore] list cancelled")
        } catch {
            if connectivity.reportFailure(error) {
                exploreError = nil
            } else {
                exploreError = "Couldn't load connections: \(error.localizedDescription)"
            }
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
            if connectivity.reportFailure(error) {
                exploreError = nil
            } else {
                exploreError = "Couldn't start connection: \(error.localizedDescription)"
            }
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
            if connectivity.reportFailure(error) {
                exploreApiKeyError = nil
            } else {
                exploreApiKeyError = IntegrationsAPI.userFacingError(error)
            }
        }
    }

    private func disconnectExploreToolkit(_ toolkit: Toolkit) async {
        guard let connectionID = toolkit.connection_id else { return }
        exploreBusySlug = toolkit.slug
        defer { exploreBusySlug = nil }

        do {
            try await IntegrationsAPI.disconnect(
                connectionID: connectionID,
                toolkit: toolkit.slug
            )
            await loadExploreToolkits(showSpinner: false, force: true)
        } catch where IntegrationsAPI.isCancellation(error) {
            print("[integrations][explore] disconnect cancelled toolkit=\(toolkit.slug) connection=\(connectionID)")
        } catch {
            if connectivity.reportFailure(error) {
                exploreError = nil
            } else {
                exploreError = "Couldn't disconnect: \(error.localizedDescription)"
            }
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

    private func reconcilePendingCronHandoff() {
        if store.pendingNewTodoID != nil || store.pendingNewTodoCronCandidateID() != nil {
            print("[list][cron_handoff] observed pending=\(store.pendingNewTodoID?.uuidString ?? "-") candidate=\(store.pendingNewTodoCronCandidateID()?.uuidString ?? "-") selected=\(selectedSectionID ?? -1)")
        }
        primeCronHandoffAnimationIfNeeded()
        if store.pendingNewTodoCronHandoffIsReadyToAnimate(),
           let handoff = activeCronHandoff,
           !completedCronHandoffGeometryIDs.contains(handoff.geometryID) {
            completedCronHandoffGeometryIDs.insert(handoff.geometryID)
            completeCronHandoffAnimation()
        }
        if store.completePendingNewTodoCronHandoffIfReady() {
            return
        }
        Task {
            _ = await store.reconcilePendingNewTodoCronHandoff()
        }
    }

    private func primeCronHandoffAnimationIfNeeded() {
        guard activeCronHandoff == nil,
              let todoID = store.pendingNewTodoID,
              let cronJobID = store.pendingNewTodoCronCandidateID() else {
            return
        }
        print("[list][cron_handoff] prime animation todo=\(todoID) cron=\(cronJobID)")
        activeCronHandoff = CronHandoff(todoID: todoID, cronJobID: cronJobID)
    }

    private func completeCronHandoffAnimation() {
        primeCronHandoffAnimationIfNeeded()
        print("[list][cron_handoff] scroll to scheduled active=\(activeCronHandoff?.geometryID ?? "-")")
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            selectedSectionID = TodoListSection.scheduled.index
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            print("[list][cron_handoff] clear animation active=\(activeCronHandoff?.geometryID ?? "-")")
            activeCronHandoff = nil
        }
    }

    private func cronHandoffGeometryID(forTodo todoID: UUID) -> String? {
        guard activeCronHandoff?.todoID == todoID else { return nil }
        return activeCronHandoff?.geometryID
    }

    private func cronHandoffGeometryID(forCronJob jobID: UUID) -> String? {
        guard activeCronHandoff?.cronJobID == jobID else { return nil }
        return activeCronHandoff?.geometryID
    }

    private func cardRefreshID(for todo: Todo) -> String {
        let artifactSig = (store.artifactsByTodoID[todo.id] ?? [])
            .map { "\($0.artifact_key):\($0.kind.rawValue):\($0.updated_at.ISO8601Format())" }
            .joined(separator: ",")
        let activitySig: String
        if let activity = store.agentActivityByTodoID[todo.id] {
            activitySig = activity.activityContentSignature
        } else {
            activitySig = ""
        }
        return [
            todo.id.uuidString,
            todo.status.rawValue,
            todo.title,
            todo.original_title ?? "",
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

private struct DockButtonStyle: ButtonStyle {
    private static let pressedScale: CGFloat = 0.9

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? Self.pressedScale : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

private struct ScheduledPromptOptionRow: View {
    let prompt: ScheduledPromptSuggestion
    let accentColor: Color
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(accentColor)
                    Image(systemName: prompt.symbolName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.title)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(prompt.description)
                        .font(.system(size: 16, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(prompt.title), \(prompt.description)")
    }
}

private extension ScheduledPromptCategory {
    var promptAccentColor: Color {
        switch id {
        case "inbox":
            return Color(red: 0.19, green: 0.47, blue: 0.95)
        case "digests":
            return Color(red: 0.43, green: 0.32, blue: 0.92)
        case "project-management":
            return Color(red: 0.04, green: 0.58, blue: 0.46)
        case "coding":
            return Color(red: 0.12, green: 0.48, blue: 0.68)
        case "chief-of-staff":
            return Color(red: 0.94, green: 0.42, blue: 0.22)
        case "finance":
            return Color(red: 0.06, green: 0.56, blue: 0.28)
        case "personal-ops":
            return Color(red: 0.84, green: 0.23, blue: 0.42)
        case "growth-content":
            return Color(red: 0.90, green: 0.42, blue: 0.10)
        default:
            return TodoCardStyle.primaryBlue
        }
    }
}

private struct TaskSectionHeader: View {
    let title: String
    var titleSuffix: String? = nil
    var trailingIconName: String? = nil
    var trailingLabel: String? = nil
    var trailingAction: (() -> Void)? = nil
    var trailingAccessibilityLabel: String? = nil
    var trailingIconCompact: Bool = false
    var trailingSwapsInstantly: Bool = false
    var verticalPadding: CGFloat = 3

    private var trailingIconSize: CGFloat {
        trailingIconCompact ? 16 : 18
    }

    private var trailingAssetIconSize: CGFloat {
        trailingIconCompact ? 20 : 22
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.78))

            if let titleSuffix {
                Text(titleSuffix)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if trailingIconName != nil || trailingLabel != nil {
                if trailingSwapsInstantly, let trailingAction {
                    instantTrailingButton(action: trailingAction)
                } else if let trailingAction {
                    Button(action: trailingAction) {
                        trailingControl
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(trailingAccessibilityLabel ?? trailingLabel ?? title)
                } else {
                    trailingControl
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, verticalPadding)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func instantTrailingButton(action: @escaping () -> Void) -> some View {
        ZStack(alignment: .trailing) {
            if let trailingIconName {
                Button(action: action) {
                    trailingIcon(trailingIconName)
                        .frame(minHeight: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(trailingAccessibilityLabel ?? "Show categories")
            }

            if let trailingLabel {
                Button(action: action) {
                    Text(trailingLabel)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(trailingAccessibilityLabel ?? trailingLabel)
            }
        }
        .transaction { transaction in
            transaction.disablesAnimations = true
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        HStack(spacing: 4) {
            if let trailingIconName {
                trailingIcon(trailingIconName)
            }

            if let trailingLabel {
                Text(trailingLabel)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
            }
        }
        .foregroundStyle(.secondary)
        .frame(minHeight: 30)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func trailingIcon(_ name: String) -> some View {
        if UIImage(named: name) != nil {
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: trailingAssetIconSize, height: trailingAssetIconSize)
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: name)
                .font(.system(size: trailingIconSize, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

private struct ExploreSectionHeader: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
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
        VStack(alignment: .leading, spacing: 0) {
            LocationBasicsRow(locationProvider: locationProvider)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppSemanticColors.elevatedSurface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(AppSemanticColors.separator, lineWidth: 1)
        }
    }
}

private struct LocationBasicsRow: View {
    @ObservedObject var locationProvider: LocationProvider

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            LocationMapSquareTile(locationProvider: locationProvider)
            CurrentLocationPill(locationProvider: locationProvider)
        }
    }
}

private struct LocationMapSquareTile: View {
    @ObservedObject var locationProvider: LocationProvider
    private let size: CGFloat = 62

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
        .frame(width: size, height: size)
        .clipShape(
            UnevenRoundedRectangle(
                cornerRadii: .init(
                    topLeading: size / 2,
                    bottomLeading: size / 2,
                    bottomTrailing: 8,
                    topTrailing: 8
                ),
                style: .continuous
            )
        )
        .onTapGesture {
            locationProvider.requestAuthorizationOrLocation()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Location map")
    }

    private var permissionContent: some View {
        VStack(spacing: 5) {
            Image(systemName: locationProvider.permissionSymbolName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(TodoCardStyle.primaryBlue)
                .frame(width: 30, height: 30)
                .background(AppSemanticColors.elevatedSurface.opacity(0.75), in: Circle())

            Text(locationProvider.permissionActionText)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(6)
    }

    private func region(for coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
        )
    }
}

private struct CurrentLocationPill: View {
    @ObservedObject var locationProvider: LocationProvider
    private let height: CGFloat = 62

    var body: some View {
        HStack(spacing: 0) {
            Text(locationProvider.displayLocationText)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
        .background(
            Color.black.opacity(0.025),
            in: UnevenRoundedRectangle(
                cornerRadii: .init(
                    topLeading: 8,
                    bottomLeading: 8,
                    bottomTrailing: height / 2,
                    topTrailing: height / 2
                ),
                style: .continuous
            )
        )
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

private struct ConnectionsPromoLogoHeader: View {
    private let logos = [
        "gmail", "googledrive", "slack", "notion",
        "googlecalendar", "googledocs", "reddit", "linkedin"
    ]
    private let chipSize: CGFloat = 38

    var body: some View {
        HStack(spacing: -8) {
            ForEach(logos, id: \.self) { slug in
                ConnectionLogoChip(slug: slug, size: chipSize)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ExploreConnectionsPromoCard: View {
    let onSetup: () -> Void
    let onDismiss: () -> Void

    private let cornerRadius: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: SectionEmptyStateStyle.contentSpacing) {
                Text("Connect your Apps")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(SectionEmptyStateStyle.title)
                    .multilineTextAlignment(.center)

                ConnectionsPromoLogoHeader()

                Text("Connect your favorite tools to make the most out of Doit")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(SectionEmptyStateStyle.subtitle)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, SectionEmptyStateStyle.horizontalPadding)
            .padding(.top, 18)

            Button(action: onSetup) {
                Text("Setup connections")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.top, 16)

            Button(action: onDismiss) {
                Text("Not now")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppSemanticColors.elevatedSurface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(AppSemanticColors.separator, lineWidth: 1)
        }
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
        .background(AppSemanticColors.elevatedSurface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(AppSemanticColors.separator, lineWidth: 1)
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
                .background(AppSemanticColors.elevatedSurface.opacity(0.75), in: Circle())

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
            .background(AppSemanticColors.elevatedSurface, in: RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                    .stroke(AppSemanticColors.separator, lineWidth: 1)
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
        .background(AppSemanticColors.elevatedSurface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(AppSemanticColors.separator, lineWidth: 1)
        }
    }
}

private struct ExploreConnectionSkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Circle()
                .fill(AppSemanticColors.neutralFill)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppSemanticColors.neutralFill)
                    .frame(width: 118, height: 16)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppSemanticColors.neutralFill.opacity(0.85))
                    .frame(width: 160, height: 12)
            }

            Spacer()

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppSemanticColors.neutralFill.opacity(0.85))
                .frame(height: 34)
        }
        .padding(16)
        .frame(width: 220, height: 188)
        .background(AppSemanticColors.elevatedSurface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(AppSemanticColors.separator, lineWidth: 1)
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

private struct PassbookUserContactCard: View {
    let initials: String?
    let displayName: String
    let avatarImageData: Data?
    let avatarURL: URL?
    let joinedAt: Date?
    let locationText: String
    let onLocationTap: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                ProfileAvatar(
                    kind: .user(initials: initials, imageData: avatarImageData, url: avatarURL),
                    size: 88
                )
                .id("passbook-user-contact-avatar-\(displayName)")

                VStack(spacing: 11) {
                    Text(displayName)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    Button(action: onLocationTap) {
                        HStack(spacing: 6) {
                            Image(systemName: "location.fill")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)

                            Text(locationText)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(AppSemanticColors.neutralFill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Requests location access for nearby suggestions")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 14)
        .padding(.bottom, 12)
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(AppSemanticColors.elevatedSurface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(AppSemanticColors.separator, lineWidth: 1)
        }
    }
}

private struct PassbookMemorySection: View {
    let memories: [AgentMemory]
    let onSelect: (AgentMemory) -> Void

    private var lastUpdatedLabel: String? {
        guard let latest = memories.map(\.updated_at).max() else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: latest, relativeTo: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ExploreSectionHeader(title: "Memories", detail: lastUpdatedLabel)
            if memories.isEmpty {
                PassbookMemoryEmptyCard()
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(memories.enumerated()), id: \.element.id) { index, memory in
                        PassbookMemoryCard(
                            memory: memory,
                            isFirst: index == 0,
                            isLast: index == memories.count - 1,
                            onSelect: { onSelect(memory) }
                        )
                    }
                }
            }
        }
    }
}

private struct PassbookMemoryEmptyCard: View {
    var body: some View {
        SectionEmptyStateCard(
            systemImage: "plus.square.fill.on.square.fill",
            title: "No Memories Yet",
            subtitle: "Things that Doit remembers about you will appear here."
        )
    }
}

private enum PassbookMemoryRowMetrics {
    static let outerCornerRadius: CGFloat = 24
    static let innerCornerRadius: CGFloat = 4

    static func cornerRadii(isFirst: Bool, isLast: Bool) -> RectangleCornerRadii {
        RectangleCornerRadii(
            topLeading: isFirst ? outerCornerRadius : innerCornerRadius,
            bottomLeading: isLast ? outerCornerRadius : innerCornerRadius,
            bottomTrailing: isLast ? outerCornerRadius : innerCornerRadius,
            topTrailing: isFirst ? outerCornerRadius : innerCornerRadius
        )
    }
}

private struct PassbookMemoryCard: View {
    let memory: AgentMemory
    let isFirst: Bool
    let isLast: Bool
    let onSelect: () -> Void

    private var rowShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: PassbookMemoryRowMetrics.cornerRadii(isFirst: isFirst, isLast: isLast),
            style: .continuous
        )
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                PassbookMemorySymbolAvatar(memory: memory)
                Text(memory.title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 14)
            .padding(.trailing, 20)
            .padding(.vertical, 14)
            .background(AppSemanticColors.elevatedSurface, in: rowShape)
            .contentShape(rowShape)
            .overlay(
                rowShape
                    .stroke(AppSemanticColors.separator)
            )
        }
        .buttonStyle(.plain)
        .contentShape(rowShape)
    }
}

private struct PassbookMemorySymbolAvatar: View {
    let memory: AgentMemory

    var body: some View {
        ZStack {
            Circle()
                .fill(AppSemanticColors.separator)
            Image(systemName: memory.effectiveSymbolName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.secondary.opacity(0.72))
        }
        .frame(width: 40, height: 40)
    }
}

private struct PassbookMemoryDetailCard: View {
    let memory: AgentMemory
    @Binding var isEditing: Bool
    @Binding var draftTitle: String
    @Binding var draftBody: String
    let onClose: () -> Void
    let onEdit: () -> Void
    let onSave: () -> Void
    let onForget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Memory")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Remembered by Doit")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !isEditing {
                    Button("Edit", action: onEdit)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(AppSemanticColors.neutralFill, in: Capsule())
                        .buttonStyle(.plain)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(AppSemanticColors.neutralFill, in: Circle())
                }
                .buttonStyle(.plain)
            }

            if isEditing {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Title", text: $draftTitle)
                        .font(.headline)
                        .textFieldStyle(.roundedBorder)
                    TextEditor(text: $draftBody)
                        .frame(minHeight: 110)
                        .padding(8)
                        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(memory.title)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    if !memory.body.isSameMemoryText(as: memory.title) {
                        Text(memory.body)
                            .font(.body)
                            .foregroundStyle(.primary)
                    }
                }
            }

            if let reason = memory.memory_reason, !reason.isEmpty, !isEditing {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Why Doit remembered this")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                if isEditing {
                    Button("Cancel") {
                        isEditing = false
                    }
                    .buttonStyle(.bordered)
                    Button("Save", action: onSave)
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                } else {
                    Button(action: onForget) {
                        Text("Forget")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 18)
                            .frame(height: 40)
                            .background(Color.red.opacity(0.20), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(26)
        .background(AppSemanticColors.elevatedSurface, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(AppSemanticColors.separator)
        )
    }
}

private extension String {
    func isSameMemoryText(as other: String) -> Bool {
        memoryComparable == other.memoryComparable
    }

    var memoryComparable: String {
        lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var lastError: String?
    @Published private(set) var currentLocationName: String?
    @Published private(set) var isGeocoding = false

    private let manager = CLLocationManager()
    private var lastLocationRefresh: Date?
    private var lastGeocodedCoordinate: CLLocationCoordinate2D?
    private var geocodingTask: Task<Void, Never>?

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
        guard let location = locations.last else { return }
        coordinate = location.coordinate
        lastError = nil
        updateLocationName(for: location)
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
            if isGeocoding {
                return "Finding location..."
            }
            return coordinate == nil ? "Finding you..." : "Ready for nearby ideas."
        case .denied, .restricted:
            return "Enable location in Settings."
        @unknown default:
            return "Location unavailable."
        }
    }

    var displayLocationText: String {
        if let currentLocationName {
            return currentLocationName
        }
        return statusText
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

    private func updateLocationName(for location: CLLocation) {
        if let lastGeocodedCoordinate,
           abs(lastGeocodedCoordinate.latitude - location.coordinate.latitude) < 0.001,
           abs(lastGeocodedCoordinate.longitude - location.coordinate.longitude) < 0.001 {
            return
        }

        lastGeocodedCoordinate = location.coordinate
        geocodingTask?.cancel()
        isGeocoding = true

        geocodingTask = Task { [weak self] in
            guard let self else { return }
            let mapItem = await self.reverseGeocode(location: location)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.isGeocoding = false
                if let mapItem, let text = self.displayText(for: mapItem) {
                    self.currentLocationName = text
                } else {
                    self.currentLocationName = self.coordinateText(for: location.coordinate)
                }
            }
        }
    }

    private func reverseGeocode(location: CLLocation) async -> MKMapItem? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        do {
            let mapItems = try await request.mapItems
            return mapItems.first
        } catch {
            if !Task.isCancelled {
                print("[location] reverse geocoding failed: \(error.localizedDescription)")
            }
            return nil
        }
    }

    private func displayText(for mapItem: MKMapItem) -> String? {
        if let short = mapItem.address?.shortAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
           !short.isEmpty {
            return short
        }
        if let full = mapItem.address?.fullAddress.trimmingCharacters(in: .whitespacesAndNewlines),
           !full.isEmpty {
            return full
        }
        if let city = mapItem.addressRepresentations?.cityWithContext?.trimmingCharacters(in: .whitespacesAndNewlines),
           !city.isEmpty {
            return city
        }
        if let name = mapItem.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return nil
    }

    private func coordinateText(for coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
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

private enum CompletedActivityFilter: String, CaseIterable, Identifiable {
    case allActivity
    case topics

    var id: String { rawValue }
}

private struct ActivityGroupDescriptor: Identifiable, Hashable {
    enum Kind: Hashable {
        case collection(String)
        case topic(TodoTopic)
    }

    let kind: Kind

    static func collection(_ name: String) -> ActivityGroupDescriptor {
        ActivityGroupDescriptor(kind: .collection(name))
    }

    static func topic(_ topic: TodoTopic) -> ActivityGroupDescriptor {
        ActivityGroupDescriptor(kind: .topic(topic))
    }

    var id: String {
        switch kind {
        case .collection(let name): return "collection:\(name.lowercased())"
        case .topic(let topic): return "topic:\(topic.rawValue)"
        }
    }

    var title: String {
        switch kind {
        case .collection(let name): return name
        case .topic(let topic): return topic.label
        }
    }

    var symbolName: String {
        switch kind {
        case .collection: return "folder.fill"
        case .topic(let topic): return topic.symbolName
        }
    }

    var tintColor: Color {
        switch kind {
        case .collection(let name):
            return Self.collectionColor(for: name)
        case .topic(let topic):
            return topic.tileColor
        }
    }

    private static func collectionColor(for name: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.20, green: 0.42, blue: 0.90),
            Color(red: 0.44, green: 0.33, blue: 0.88),
            Color(red: 0.09, green: 0.56, blue: 0.60),
            Color(red: 0.80, green: 0.36, blue: 0.18),
            Color(red: 0.67, green: 0.28, blue: 0.62),
            Color(red: 0.22, green: 0.55, blue: 0.32)
        ]
        let seed = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[seed % palette.count]
    }
}

private extension TodoTopic {
    var tileColor: Color {
        switch self {
        case .communication: return Color(red: 0.00, green: 0.48, blue: 1.00)
        case .scheduling: return Color(red: 0.36, green: 0.42, blue: 0.88)
        case .research: return Color(red: 0.00, green: 0.58, blue: 0.52)
        case .documents: return Color(red: 0.28, green: 0.52, blue: 0.80)
        case .coding: return Color(red: 0.17, green: 0.18, blue: 0.24)
        case .finance: return Color(red: 0.16, green: 0.58, blue: 0.30)
        case .shopping: return Color(red: 0.94, green: 0.48, blue: 0.16)
        case .travel: return Color(red: 0.02, green: 0.60, blue: 0.86)
        case .personal: return Color(red: 0.88, green: 0.38, blue: 0.52)
        case .work: return Color(red: 0.38, green: 0.36, blue: 0.76)
        case .other: return Color(red: 0.42, green: 0.46, blue: 0.52)
        }
    }
}

private struct ActivityGroupSummary: Identifiable, Hashable {
    let descriptor: ActivityGroupDescriptor
    let count: Int
    let previewTitles: [String]
    let latestUpdate: Date

    var id: String { descriptor.id }
    var title: String { descriptor.title }
    var symbolName: String { descriptor.symbolName }
    var tintColor: Color { descriptor.tintColor }
}

private struct ActivityGroupGrid: View {
    let summaries: [ActivityGroupSummary]
    let onSelect: (ActivityGroupDescriptor) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(summaries) { summary in
                ActivityGroupTile(summary: summary) {
                    onSelect(summary.descriptor)
                }
                .transition(.scale(scale: 0.94, anchor: .center).combined(with: .opacity))
            }
        }
    }
}

private struct ActivityGroupTile: View {
    let summary: ActivityGroupSummary
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: summary.symbolName)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24, alignment: .topLeading)
                        .accessibilityHidden(true)

                    Spacer(minLength: 8)

                    Text("\(summary.count)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }

                Spacer(minLength: 0)

                Text(summary.title)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .background(summary.tintColor, in: RoundedRectangle(cornerRadius: TodoCardStyle.cardCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(summary.title), \(summary.count) recent tasks")
    }
}

private struct ActivityEmptyCard: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(TodoCardStyle.primaryBlue)

            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.82))

            Text(message)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(TodoCardStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppSemanticColors.elevatedSurface, in: RoundedRectangle(cornerRadius: TodoCardStyle.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: TodoCardStyle.cardCornerRadius, style: .continuous)
                .stroke(AppSemanticColors.separator, lineWidth: 1)
        }
    }
}

private struct ActivityGroupDetailHeader: View {
    let descriptor: ActivityGroupDescriptor
    let count: Int
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: descriptor.symbolName)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(descriptor.tintColor, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(descriptor.title)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)

                    Text("\(count) recent task\(count == 1 ? "" : "s")")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.primary)
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(AppSemanticColors.surface)
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

    var allowsAddTodoComposer: Bool {
        switch self {
        case .todo, .scheduled:
            return true
        case .done:
            return false
        }
    }

    func contains(_ status: TodoStatus) -> Bool {
        switch self {
        case .todo:
            // Done and cancelled tasks move into the Recent section; the task
            // list keeps current, blocked, and retryable work at the top.
            return status != .done && status != .cancelled
        case .scheduled:
            return false
        case .done:
            return false
        }
    }
}

private enum AddTodoComposerMotion {
    /// Fast morph with a slight ease-out settle at the end.
    static let morph = Animation.spring(response: 0.30, dampingFraction: 0.80)
    static let backdrop = Animation.easeOut(duration: 0.22)
    static let contentReveal = Animation.easeOut(duration: 0.15)
    static let contentRevealDelay: TimeInterval = 0.14
    static let dismissCleanupDelay: TimeInterval = 0.30
    /// Show the FAB "+" before collapse cleanup finishes; shell is ~circle-sized by then.
    static let plusIconRevealDelay: TimeInterval = 0.17
    static let fabAppear = Animation.spring(response: 0.36, dampingFraction: 0.62)
    static let fabDisappearDuration: TimeInterval = 0.12
    static let fabDisappear = Animation.easeOut(duration: fabDisappearDuration)
    static let fabHiddenScale: CGFloat = 0.82
}

private struct AddTodoSheetPresentation: Identifiable {
    let id = UUID()
    let title: String
    let action: AddTodoLaunchAction
}

private struct MorphComposerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct AddTodoMorphOverlay: View {
    let isExpanded: Bool
    let isContentVisible: Bool
    let isVisible: Bool
    let presentation: AddTodoSheetPresentation?
    let userID: UUID
    let onExpand: () -> Void
    let onDismiss: () -> Void
    let onCreated: (Todo) -> Void

    @State private var showsPlusIcon = true
    @State private var keyboardOverlap: CGFloat = 0
    @State private var measuredContentHeight: CGFloat = 0

    private let fabSize: CGFloat = 52
    private let panelMinWidth: CGFloat = 360
    private let panelCornerRadius: CGFloat = 34
    private let leadingInset: CGFloat = 14
    private let trailingInset: CGFloat = 14
    private let expandedBottomInset: CGFloat = 12
    private let expandedTopMargin: CGFloat = 12
    private let keyboardGapAboveKeyboard: CGFloat = 8
    private let fabGapAboveDock: CGFloat = 12
    /// Matches `DockStyle` bar padding + button height (8 + 40 + 4).
    private let dockBarHeight: CGFloat = 52
    private var collapsedBottomInset: CGFloat { dockBarHeight + fabGapAboveDock }

    private func composerBottomPadding(expanded: Bool) -> CGFloat {
        guard expanded else { return collapsedBottomInset }
        if keyboardOverlap > 0 {
            return keyboardOverlap + keyboardGapAboveKeyboard
        }
        return expandedBottomInset
    }

    private var morphAnimation: Animation {
        AddTodoComposerMotion.morph
    }

    private func maxExpandedShellHeight(in proxy: GeometryProxy) -> CGFloat {
        let topInset = SafeAreaInsetsKey.defaultValue.top
        let bottomPadding = composerBottomPadding(expanded: true)
        return max(
            fabSize,
            proxy.size.height - topInset - expandedTopMargin - bottomPadding
        )
    }

    private func expandedShellHeight(panelWidth: CGFloat, maxShellHeight: CGFloat) -> CGFloat {
        let contentHeight: CGFloat
        if measuredContentHeight > fabSize {
            contentHeight = measuredContentHeight
        } else {
            contentHeight = AddTodoView.estimatedMorphComposerHeight(
                for: presentation?.title ?? "",
                panelWidth: panelWidth,
                maxComposerHeight: maxShellHeight
            )
        }
        return min(contentHeight, maxShellHeight)
    }

    var body: some View {
        ZStack {
            if isExpanded {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { onDismiss() }
                    .transition(.opacity)
            }

            GeometryReader { proxy in
                let availableWidth = proxy.size.width - leadingInset - trailingInset
                let panelWidth = max(panelMinWidth, availableWidth)
                let maxShellHeight = maxExpandedShellHeight(in: proxy)
                let shellWidth = isExpanded ? panelWidth : fabSize
                let shellHeight = isExpanded ? expandedShellHeight(panelWidth: panelWidth, maxShellHeight: maxShellHeight) : fabSize
                let shellCornerRadius = isExpanded ? panelCornerRadius : fabSize / 2

                VStack {
                    Spacer()

                    HStack {
                        Spacer(minLength: 0)

                        ZStack(alignment: .bottomTrailing) {
                            RoundedRectangle(cornerRadius: shellCornerRadius, style: .continuous)
                                .fill(isExpanded ? AppSemanticColors.morphComposerBackground : AppSemanticColors.morphFabBackground)
                                .frame(width: shellWidth, height: shellHeight)
                                .compositingGroup()
                                .overlay(alignment: .top) {
                                    if isExpanded, let presentation {
                                        AddTodoView(
                                            userID: userID,
                                            initialTitle: presentation.title,
                                            initialAction: presentation.action,
                                            presentation: .morphShell,
                                            maxComposerHeight: maxShellHeight,
                                            onCancel: onDismiss,
                                            onCreated: onCreated
                                        )
                                        .id(presentation.id)
                                        .frame(width: panelWidth, alignment: .top)
                                        .background {
                                            GeometryReader { contentProxy in
                                                Color.clear.preference(
                                                    key: MorphComposerHeightKey.self,
                                                    value: contentProxy.size.height
                                                )
                                            }
                                        }
                                        .opacity(isContentVisible ? 1 : 0)
                                        .allowsHitTesting(isContentVisible)
                                        .clipShape(
                                            RoundedRectangle(
                                                cornerRadius: shellCornerRadius,
                                                style: .continuous
                                            )
                                        )
                                        .animation(AddTodoComposerMotion.contentReveal, value: isContentVisible)
                                    }
                                }
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: shellCornerRadius,
                                        style: .continuous
                                    )
                                )
                                .shadow(
                                    color: .black.opacity(isExpanded ? 0.16 : 0.20),
                                    radius: isExpanded ? 28 : 12,
                                    y: isExpanded ? 18 : 4
                                )
                                .contentShape(
                                    RoundedRectangle(
                                        cornerRadius: shellCornerRadius,
                                        style: .continuous
                                    )
                                )
                                .onTapGesture {
                                    guard !isExpanded else { return }
                                    onExpand()
                                }
                                .accessibilityLabel("New Task")
                                .accessibilityAddTraits(isExpanded ? [] : .isButton)

                            if showsPlusIcon {
                                Image(systemName: "plus")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .frame(width: fabSize, height: fabSize)
                                    .allowsHitTesting(false)
                            }
                        }
                        .scaleEffect(isVisible ? 1 : AddTodoComposerMotion.fabHiddenScale, anchor: .center)
                        .opacity(isVisible ? 1 : 0)
                        .allowsHitTesting(isVisible)
                        .padding(.trailing, trailingInset)
                    }
                    .padding(.leading, isExpanded ? leadingInset : 0)
                    .padding(.bottom, composerBottomPadding(expanded: isExpanded))
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .animation(morphAnimation, value: isExpanded)
        .animation(AddTodoComposerMotion.backdrop, value: isExpanded)
        .animation(.smooth(duration: 0.25), value: keyboardOverlap)
        .onPreferenceChange(MorphComposerHeightKey.self) { height in
            guard isExpanded, height > fabSize else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                measuredContentHeight = height
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
        ) { note in
            guard isExpanded else {
                keyboardOverlap = 0
                return
            }
            keyboardOverlap = visibleKeyboardOverlap(from: note)
            measuredContentHeight = 0
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
        ) { _ in
            keyboardOverlap = 0
            measuredContentHeight = 0
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded {
                showsPlusIcon = false
            } else {
                keyboardOverlap = 0
                measuredContentHeight = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + AddTodoComposerMotion.plusIconRevealDelay) {
                    if !isExpanded {
                        showsPlusIcon = true
                    }
                }
            }
        }
    }

    private func visibleKeyboardOverlap(from note: Notification) -> CGFloat {
        guard
            let endFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return 0 }
        let screenHeight = UIScreen.main.bounds.height
        let overlap = max(0, screenHeight - endFrame.origin.y)
        guard overlap > 0 else { return 0 }
        let bottomInset = SafeAreaInsetsKey.defaultValue.bottom
        return max(0, overlap - bottomInset)
    }
}

private struct CronHandoff: Equatable {
    let todoID: UUID
    let cronJobID: UUID

    var geometryID: String {
        "cron-handoff-\(todoID.uuidString)-\(cronJobID.uuidString)"
    }
}

private struct OptionalMatchedGeometryEffect: ViewModifier {
    let id: String?
    let namespace: Namespace.ID
    let isSource: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if let id {
            content.matchedGeometryEffect(id: id, in: namespace, isSource: isSource)
        } else {
            content
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
    let initialRoute: SettingsRoute?
    let onDismiss: () -> Void

    var body: some View {
        SettingsView(onDismiss: onDismiss, initialRoute: initialRoute)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppSemanticColors.surface)
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
    private static let contentHorizontalPadding: CGFloat = 14
    private static let contentTopPadding: CGFloat = 12
    private static let contentBottomPadding: CGFloat = 16
    private static let footerHeight: CGFloat = 54
    private static let footerBackground = AppSemanticColors.footerSurface

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
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(TodoCardStyle.muted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onOpen) {
                    Text(job.name)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Self.contentHorizontalPadding)
            .padding(.top, Self.contentTopPadding)
            .padding(.bottom, Self.contentBottomPadding)
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
                .fill(AppSemanticColors.elevatedSurface)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    if let next = job.nextRunLabel, job.state == .scheduled {
                        Text("Next: \(next)")
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundStyle(TodoCardStyle.muted.opacity(0.85))
                    } else {
                        Text(job.state.label)
                            .font(.system(
                                size: 13,
                                weight: job.state == .needs_input ? .semibold : .regular,
                                design: .rounded
                            ))
                            .foregroundStyle(footerStatusColor)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if job.state != .completed {
                    Button(action: onTogglePause) {
                        Image(systemName: job.state == .paused ? "play.fill" : "pause")
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(.primary)
                            .frame(width: 38, height: 38)
                            .background(AppSemanticColors.elevatedSurface, in: Circle())
                            .overlay {
                                Circle()
                                    .stroke(AppSemanticColors.separator, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(job.state == .paused ? "Resume schedule" : "Pause schedule")
                }
            }
            .padding(.horizontal, Self.contentHorizontalPadding)
            .frame(height: Self.footerHeight)
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
                .stroke(AppSemanticColors.separator, lineWidth: 1)
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

    private var footerStatusColor: Color {
        job.state == .needs_input ? .orange : TodoCardStyle.muted.opacity(0.85)
    }
}

/// Task card.
///
///   Row 1: state icon + state label, updated date + chevron
///   Row 2: task title in SF Pro Rounded 20
///   Row 3: live activity or latest artifact pill, plus any primary action
private struct TodoCard: View {
    let todo: Todo
    /// Toolkit logos for the pill fallback while the agent is still working.
    let connectionSlugs: [String]
    /// Agent-returned deliverables for the latest-artifact pill.
    let artifacts: [TodoArtifact]
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
        VStack(alignment: .leading, spacing: TodoCardStyle.rowSpacing) {
            topRow
            titleRow
            bottomRow
        }
        .padding(TodoCardStyle.cardPadding)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: TodoCardStyle.cardCornerRadius, style: .continuous)
                .fill(AppSemanticColors.elevatedSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: TodoCardStyle.cardCornerRadius, style: .continuous)
                .stroke(AppSemanticColors.separator, lineWidth: 1)
        }
    }

    // MARK: Rows

    private var titleRow: some View {
        Button(action: onOpen) {
            Text(displayTitle)
                .font(.system(size: 20, weight: .regular, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(todo.status == .done ? nil : 3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .id(displayTitle)
        }
        .buttonStyle(.plain)
    }

    private var topRow: some View {
        HStack(alignment: .center, spacing: 10) {
            TodoStateLabel(status: todo.status, action: onToggleComplete)

            Spacer(minLength: 8)

            Button(action: onOpen) {
                HStack(spacing: 0) {
                    Text(lastUpdatedText)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(TodoCardStyle.headerChrome)
                        .lineLimit(1)

                    Image("Cheveron_Icon")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 9, height: 9)
                        .foregroundStyle(TodoCardStyle.headerChrome)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var displayTitle: String {
        if titleStillLooksUnprepared, let prepared = preparedSummaryText {
            return prepared
        }
        return trimmedTitle ?? "Task"
    }

    private var titleStillLooksUnprepared: Bool {
        guard let title = trimmedTitle else { return true }
        guard let original = trimmedOriginalTitle else {
            return todo.status.isActive && preparedSummaryText != nil
        }
        return title.caseInsensitiveCompare(original) == .orderedSame
    }

    private var trimmedTitle: String? {
        nonEmptyTrimmed(todo.title)
    }

    private var trimmedOriginalTitle: String? {
        nonEmptyTrimmed(todo.original_title)
    }

    private var preparedSummaryText: String? {
        nonEmptyTrimmed(todo.preparation_summary)
    }

    private func nonEmptyTrimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
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
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let pillContent {
                    TodoCardInfoPill(content: pillContent)
                        .padding(.horizontal, -TodoCardStyle.artifactPillEdgeOutset)
                        .padding(.bottom, -TodoCardStyle.artifactPillBottomOutset)
                }
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
            if activity.isRunning || activity.resolvedPhase == .starting {
                return activity.primaryStatusText
            }
        }
        switch todo.status {
        case .preparing:
            if let activity, activity.isRunning || activity.resolvedPhase == .starting {
                return activity.primaryStatusText
            }
            if let summary = todo.preparation_summary, !summary.isEmpty {
                return summary
            }
            return "Preparing task..."
        case .todo: return "Ready to get started..."
        case .requested:
            if let activity, !activity.primaryStatusText.isEmpty {
                return activity.primaryStatusText
            }
            if let summary = preparedSummaryText {
                return summary
            }
            return "Queued to run..."
        case .running:
            if let activity, !activity.primaryStatusText.isEmpty {
                return activity.primaryStatusText
            }
            if let summary = preparedSummaryText {
                return summary
            }
            return "Working..."
        case .needs_auth: return "Connect an account to continue"
        case .needs_input: return "Needs your input"
        case .done: return "Done"
        case .failed: return todo.error_message ?? "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private var lastUpdatedText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(todo.updated_at) { return "Today" }
        if calendar.isDateInYesterday(todo.updated_at) { return "Yesterday" }
        return todo.updated_at.formatted(.dateTime.month(.wide).day())
    }

    private var pillContent: TodoCardInfoPill.Content? {
        if todo.status.isActive {
            let slug = connectionSlugs.first ?? todo.connection_slug
            return .activity(statusText, providerSlug: slug)
        }
        if let latestArtifactSummary {
            return .artifact(latestArtifactSummary)
        }
        switch todo.status {
        case .needs_auth, .needs_input, .failed:
            return .activity(statusText, providerSlug: connectionSlugs.first ?? todo.connection_slug)
        case .preparing, .requested, .running, .todo, .done, .cancelled:
            return nil
        }
    }

    private var latestArtifactSummary: TodoCardArtifactSummary? {
        let grouped = TodoArtifact.groupedForDisplay(artifacts)
        let candidates = (grouped.primary + grouped.emailDrafts)
            .filter(\.hasContent)
        let latest = candidates.max {
            if $0.updated_at != $1.updated_at {
                return $0.updated_at < $1.updated_at
            }
            return $0.created_at < $1.created_at
        }
        return latest.flatMap { TodoCardArtifactSummary(artifact: $0) }
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
        case .failed:
            PillButton(
                label: "Try again",
                style: .primary,
                icon: "arrow.clockwise",
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

private struct TodoStateLabel: View {
    let status: TodoStatus
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                icon
                Text(label)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(TodoCardStyle.headerChrome)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var icon: some View {
        switch status {
        case .done:
            Image("Completed_Icon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 10, height: 10)
                .foregroundStyle(TodoCardStyle.headerChrome)
        case .cancelled:
            Image("Canceled_Icon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 12, height: 12)
                .foregroundStyle(TodoCardStyle.headerChrome)
        case .preparing, .requested, .running:
            ProgressView()
                .controlSize(.small)
                .tint(TodoCardStyle.headerChrome)
                .frame(width: 20, height: 20)
        case .needs_auth, .needs_input:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(TodoCardStyle.headerChrome)
                .frame(width: 20, height: 20)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(TodoCardStyle.headerChrome)
                .frame(width: 20, height: 20)
        case .todo:
            Circle()
                .strokeBorder(TodoCardStyle.muted, lineWidth: 2)
                .frame(width: 20, height: 20)
        }
    }

    private var label: String {
        switch status {
        case .done: return "Completed"
        case .cancelled: return "Cancelled"
        case .preparing, .requested, .running: return "In Progress"
        case .needs_auth, .needs_input: return "Waiting"
        case .failed: return "Failed"
        case .todo: return "Todo"
        }
    }

    private var accessibilityLabel: String {
        switch status {
        case .done: return "Completed. Mark as not done"
        case .preparing, .requested, .running: return "In progress"
        case .todo: return "Todo. Mark as done"
        default: return label
        }
    }
}

private struct TodoCardArtifactSummary: Equatable {
    let title: String
    let providerSlug: String?
    let fallbackSystemImage: String

    init?(artifact: TodoArtifact) {
        switch artifact.kind {
        case .link:
            let title = artifact.title ?? artifact.url?.host ?? "Open link"
            self.init(title: title, providerSlug: artifact.provider, fallbackSystemImage: "link")
        case .email:
            let draft = artifact.emailDraft
            let title = artifact.title ?? draft?.subject ?? artifact.emailFallbackTitle
            self.init(title: title, providerSlug: artifact.emailProvider, fallbackSystemImage: "envelope.fill")
        case .calendar:
            let event = artifact.calendarEvent
            let title = event?.title ?? artifact.title ?? "Calendar event"
            self.init(title: title, providerSlug: "googlecalendar", fallbackSystemImage: "calendar")
        case .text:
            self.init(title: artifact.title ?? "Result", providerSlug: nil, fallbackSystemImage: "doc.text.fill")
        case .audio:
            let clip = artifact.audio
            self.init(
                title: artifact.title ?? "Spoken summary",
                providerSlug: clip?.provider,
                fallbackSystemImage: "waveform"
            )
        case .image:
            guard let ref = artifact.image else { return nil }
            let title = artifact.title ?? ref.prompt ?? Self.defaultImageTitle(provider: ref.provider)
            self.init(title: title, providerSlug: ref.provider, fallbackSystemImage: "photo")
        case .options:
            guard let payload = artifact.optionsPayload else { return nil }
            let title = artifact.title ?? payload.summary ?? payload.categoryDisplayName
            self.init(title: title, providerSlug: payload.provider, fallbackSystemImage: "list.bullet.rectangle")
        }
    }

    private init(title: String, providerSlug: String?, fallbackSystemImage: String) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Result" : title
        self.providerSlug = providerSlug?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.fallbackSystemImage = fallbackSystemImage
    }

    private static func defaultImageTitle(provider: String?) -> String {
        switch provider?.lowercased() {
        case "figma": return "Figma export"
        case "browser": return "Screenshot"
        default: return "Image"
        }
    }
}

private struct TodoCardInfoPill: View {
    enum Content: Equatable {
        case activity(String, providerSlug: String?)
        case artifact(TodoCardArtifactSummary)
    }

    let content: Content

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: TodoCardStyle.artifactPillIconSize, height: TodoCardStyle.artifactPillIconSize)
                .frame(width: TodoCardStyle.artifactPillIconCircleSize, height: TodoCardStyle.artifactPillIconCircleSize)
                .background(Color.white, in: Circle())

            Text(title)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Capsule().fill(TodoCardStyle.artifactPillBackground))
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var icon: some View {
        switch content {
        case let .activity(_, providerSlug):
            if let providerSlug, !providerSlug.isEmpty {
                ConnectionLogo(slug: providerSlug)
            } else {
                ActivityLoadingDots()
            }
        case let .artifact(summary):
            if let slug = summary.providerSlug, !slug.isEmpty {
                ConnectionLogo(slug: slug)
            } else {
                Image(systemName: summary.fallbackSystemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TodoCardStyle.muted)
            }
        }
    }

    private var title: String {
        switch content {
        case let .activity(text, _): return text
        case let .artifact(summary): return summary.title
        }
    }
}

/// Shared style tokens for the redesigned todo card. Mirrors the design
/// spec: muted #B6B6B6 for chrome text/strokes, iOS system blue tint for
/// the primary action.
private enum TodoCardStyle {
    static let muted = AppSemanticColors.mutedChrome
    static let headerChrome = AppSemanticColors.mutedChrome
    static let primaryBlue = Color(red: 0, green: 122 / 255, blue: 1)
    static let primaryBlueTint = Color(red: 0, green: 122 / 255, blue: 1).opacity(0.15)
    static let footerBackground = AppSemanticColors.footerSurface
    static let cardCornerRadius: CGFloat = 34
    /// Green used for the completed-todo toggle (iOS system green).
    static let completedGreen = Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
    /// Padding on all four sides of the card.
    static let cardPadding: CGFloat = 20
    /// Vertical gap between the three rows; keep equal so the card feels balanced.
    static let rowSpacing: CGFloat = 14
    static let connectionLogoChipSize: CGFloat = 28
    static let artifactPillBackground = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.18, alpha: 1)
            : UIColor(red: 244 / 255, green: 244 / 255, blue: 244 / 255, alpha: 1)
    })
    static let artifactPillIconSize: CGFloat = 20
    static let artifactPillIconCircleSize: CGFloat = 38
    static let artifactPillEdgeOutset: CGFloat = 14
    static let artifactPillBottomOutset: CGFloat = 12
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
                } else if status.isActive {
                    ProgressView()
                        .controlSize(.small)
                        .tint(TodoCardStyle.muted)
                } else {
                    Circle()
                        .strokeBorder(TodoCardStyle.muted, lineWidth: 3)
                }
            }
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(toggleAccessibilityLabel)
    }

    private var toggleAccessibilityLabel: String {
        if status == .done { return "Mark as not done" }
        if status.isActive { return "Task in progress" }
        return "Mark as done"
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
            case .neutral: return AppSemanticColors.neutralFill
            }
        }

        var foreground: Color {
            switch self {
            case .primary: return TodoCardStyle.primaryBlue
            case .destructive: return Color.red
            case .neutral: return Color(.secondaryLabel)
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
        chipSize * 0.38
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
            .background(AppSemanticColors.elevatedSurface, in: Circle())
            .overlay {
                Circle()
                    .strokeBorder(AppSemanticColors.separator, lineWidth: 1)
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

private enum SectionEmptyStateStyle {
    static let background = AppSemanticColors.elevatedSurface
    static let icon = AppSemanticColors.mutedChrome
    static let title = Color(.label)
    static let subtitle = Color(.secondaryLabel)
    static let cornerRadius: CGFloat = 20
    static let contentSpacing: CGFloat = 10
    static let horizontalPadding: CGFloat = 32
    static let verticalPadding: CGFloat = 32
}

private struct SectionEmptyStateCard: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: SectionEmptyStateStyle.contentSpacing) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .foregroundStyle(SectionEmptyStateStyle.icon)

            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(SectionEmptyStateStyle.title)
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(SectionEmptyStateStyle.subtitle)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, SectionEmptyStateStyle.horizontalPadding)
        .padding(.vertical, SectionEmptyStateStyle.verticalPadding)
        .background(
            SectionEmptyStateStyle.background,
            in: RoundedRectangle(cornerRadius: SectionEmptyStateStyle.cornerRadius, style: .continuous)
        )
    }
}

private struct TaskListLoadingSkeleton: View {
    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { index in
                TaskListSkeletonCard(index: index)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading tasks")
    }
}

private enum PullRefreshSpinnerStyle {
    static let topPadding: CGFloat = 122
}

private struct PullRefreshSpinner: View {
    var body: some View {
        ProgressView()
            .controlSize(.large)
            .tint(Color(.systemGray3))
            .frame(width: 44, height: 44)
            .accessibilityLabel("Refreshing")
            .allowsHitTesting(false)
    }
}

private struct TaskListSkeletonCard: View {
    let index: Int

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Circle()
                .fill(AppSemanticColors.neutralFill)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 9) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppSemanticColors.neutralFill)
                    .frame(width: titleWidth, height: 16)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(AppSemanticColors.neutralFill.opacity(0.82))
                    .frame(width: subtitleWidth, height: 12)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(
            AppSemanticColors.elevatedSurface,
            in: RoundedRectangle(cornerRadius: TodoCardStyle.cardCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: TodoCardStyle.cardCornerRadius, style: .continuous)
                .stroke(AppSemanticColors.separator, lineWidth: 1)
        }
    }

    private var titleWidth: CGFloat {
        [190, 245, 165][index % 3]
    }

    private var subtitleWidth: CGFloat {
        [128, 176, 148][index % 3]
    }
}

private struct EmptyState: View {
    let section: TodoListSection

    var body: some View {
        SectionEmptyStateCard(
            systemImage: iconName,
            title: title,
            subtitle: subtitle
        )
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
            return "Tap the + to create a task for your agent. Once it's done or cancelled, you'll see recent tasks here."
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
                .fill(AppSemanticColors.avatarPlaceholderBackground)
            if let initials, !initials.isEmpty {
                Text(initials)
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppSemanticColors.avatarPlaceholderForeground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(AppSemanticColors.avatarPlaceholderForeground)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            Circle()
                .stroke(AppSemanticColors.avatarBorder, lineWidth: 1.5)
        }
    }
}
