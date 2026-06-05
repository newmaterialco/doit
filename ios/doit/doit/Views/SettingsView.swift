import PhotosUI
import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthModel.self) private var auth
    @Environment(TodoStore.self) private var store
    @AppStorage("settings.modelDisplayName") private var cachedModelDisplayName = ""
    @State private var modelCatalog: [AgentModelProviderOption] = []
    @State private var modelSetting: AgentModelSetting?
    @State private var selectedModelName: String?
    @State private var modelSettingsLoading = true
    @State private var modelSettingsSaving = false
    @State private var modelSettingsError: String?
    @State private var showModelPicker = false
    @State private var activeRoute: SettingsRoute?
    @State private var displayedRoute: SettingsRoute?

    var onDismiss: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ZStack {
                    ZStack(alignment: .topLeading) {
                        settingsRoot(minHeight: proxy.size.height - 96)
                            .offset(x: activeRoute == nil ? 0 : -proxy.size.width)

                        if let displayedRoute {
                            settingsDestination(displayedRoute)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .background(Color.white)
                                .offset(x: activeRoute == nil ? proxy.size.width : 0)
                        }
                    }
                    .clipped()
                    .animation(settingsNavigationAnimation, value: activeRoute)

                    if showModelPicker {
                        modelPickerBackdrop
                            .transition(.opacity)
                            .zIndex(2)

                        modelPickerPanel(height: modelPickerHeight(for: proxy.size.height))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .zIndex(3)
                    }
                }
                .animation(settingsNavigationAnimation, value: showModelPicker)
            }
            .background(Color.white)
            .toolbar(.hidden, for: .navigationBar)
            .task { await loadModelSettings() }
        }
    }

    private func settingsRoot(minHeight: CGFloat) -> some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            openRoute(.userProfile(
                                displayName: auth.displayName,
                                avatarImageData: auth.avatarImageData,
                                avatarURL: auth.avatarURL
                            ))
                        } label: {
                            PersonRow(
                                avatar: .user(
                                    initials: auth.initials,
                                    imageData: auth.avatarImageData,
                                    url: auth.avatarURL
                                ),
                                title: auth.displayName,
                                subtitle: joinedSubtitle
                            )
                        }
                        .buttonStyle(.plain)
                        SettingsDivider(leadingPadding: 90)

                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            openRoute(.agentProfile(lastRunText: agentLastRunSubtitle))
                        } label: {
                            PersonRow(
                                avatar: .agent,
                                title: "doit",
                                subtitle: agentLastRunSubtitle
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    SectionLabel("Settings")
                        .padding(.top, 30)

                    SettingsGroup {
                        modelSettingsButton
                        SettingsDivider(leadingPadding: 66)
                        settingsRouteButton(.connections)
                        SettingsDivider(leadingPadding: 66)
                        settingsRouteButton(.memory)
                    }

                    Spacer()
                        .frame(height: 52)

                    Button {
                        Task {
                            await auth.signOut()
                            close()
                        }
                    } label: {
                        SettingsRow(
                            icon: "rectangle.portrait.and.arrow.right",
                            title: "Sign out",
                            showsChevron: false
                        )
                    }
                    .buttonStyle(.plain)
                }
                .frame(minHeight: minHeight, alignment: .top)
                .padding(.top, 72)
                .padding(.bottom, 32)
            }
            .scrollContentBackground(.hidden)

            settingsHeader
        }
    }

    private var modelSettingsButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            presentModelPicker()
        } label: {
            SettingsRow(
                icon: "square.3.layers.3d.middle.filled",
                title: "Model",
                value: displayedModelName,
                trailingSystemName: "ellipsis",
                trailingRotation: .degrees(90)
            )
        }
        .buttonStyle(.plain)
    }

    private func settingsRouteButton(_ route: SettingsRoute, value: String? = nil) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            openRoute(route)
        } label: {
            SettingsRow(icon: route.icon, title: route.title, value: value)
        }
        .buttonStyle(.plain)
    }

    private func settingsDestination(_ route: SettingsRoute) -> some View {
        ZStack(alignment: .top) {
            route.content
                .padding(.top, 60)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
                .toolbar(.hidden, for: .navigationBar)

            SettingsPageHeader(title: route.title) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                closeRoute()
            }
        }
        .background(Color.white)
    }

    private func openRoute(_ route: SettingsRoute) {
        displayedRoute = route
        DispatchQueue.main.async {
            withAnimation(settingsNavigationAnimation) {
                activeRoute = route
            }
        }
    }

    private func closeRoute() {
        withAnimation(settingsNavigationAnimation) {
            activeRoute = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            if activeRoute == nil {
                displayedRoute = nil
            }
        }
    }

    private var modelPickerBackdrop: some View {
        Color.black.opacity(0.16)
            .ignoresSafeArea(.all)
            .contentShape(Rectangle())
            .onTapGesture {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                dismissModelPicker()
            }
    }

    private func modelPickerPanel(height: CGFloat) -> some View {
        VStack {
            Spacer()
            ModelPickerCard(
                catalog: modelCatalog,
                selectedSetting: modelSetting,
                loading: modelSettingsLoading,
                saving: modelSettingsSaving,
                error: modelSettingsError,
                height: height,
                onClose: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    dismissModelPicker()
                },
                onSelect: { provider, model in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task { await saveModelSelection(provider: provider, model: model) }
                }
            )
            .padding(.horizontal, 18)
            .padding(.bottom, 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var settingsHeader: some View {
        ZStack {
            Text("Settings")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(white: 0.08))

            HStack {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.8)
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(white: 0.58))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close settings")

                Spacer()
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 56)
        .padding(.bottom, 4)
        .background(Color.white)
        .zIndex(1)
    }

    private func loadModelSettings() async {
        modelSettingsLoading = true
        defer { modelSettingsLoading = false }
        do {
            let response = try await AgentSettingsAPI.getModelSettings()
            modelCatalog = response.catalog
            modelSetting = response.setting
            guard let setting = response.setting else {
                selectedModelName = nil
                cachedModelDisplayName = ""
                modelSettingsError = nil
                return
            }

            let name = displayName(for: setting, in: response.catalog)
            selectedModelName = name
            cachedModelDisplayName = name
            modelSettingsError = nil
        } catch {
            selectedModelName = nil
            modelSettingsError = "Couldn't load model settings: \(error.localizedDescription)"
        }
    }

    private func presentModelPicker() {
        if modelCatalog.isEmpty && !modelSettingsLoading {
            Task { await loadModelSettings() }
        }
        withAnimation(settingsNavigationAnimation) {
            showModelPicker = true
        }
    }

    private func dismissModelPicker() {
        withAnimation(settingsNavigationAnimation) {
            showModelPicker = false
        }
    }

    private func saveModelSelection(
        provider: AgentModelProviderOption,
        model: AgentModelOption
    ) async {
        guard !modelSettingsSaving else { return }
        modelSettingsSaving = true
        defer { modelSettingsSaving = false }

        do {
            let updated = try await AgentSettingsAPI.updateModelSettings(
                provider: provider.id,
                model: model.id
            )
            modelSetting = updated
            let name = "\(provider.name) - \(model.name)"
            selectedModelName = name
            cachedModelDisplayName = name
            modelSettingsError = nil
            dismissModelPicker()
        } catch {
            modelSettingsError = "Couldn't save model settings: \(error.localizedDescription)"
        }
    }

    private var displayedModelName: String? {
        selectedModelName ?? (cachedModelDisplayName.isEmpty ? nil : cachedModelDisplayName)
    }

    private func displayName(
        for setting: AgentModelSetting,
        in catalog: [AgentModelProviderOption]
    ) -> String {
        guard let provider = catalog.first(where: { $0.id == setting.provider }) else {
            return setting.model
        }
        let modelName = provider.models.first { $0.id == setting.model }?.name ?? setting.model
        return "\(provider.name) - \(modelName)"
    }

    private func modelPickerHeight(for containerHeight: CGFloat) -> CGFloat {
        min(UIScreen.main.bounds.height * 0.5, containerHeight - 36)
    }

    private func close() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    private var settingsNavigationAnimation: Animation {
        .spring(response: 0.36, dampingFraction: 0.78)
    }

    private var joinedSubtitle: String {
        guard let joinedAt = auth.joinedAt else { return "Joined doit" }
        return "Joined \(joinedAt.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    private var agentLastRunSubtitle: String {
        let todoDates = store.todos.map(\.updated_at)
        let cronDates = store.cronJobs.flatMap { [$0.last_run_at, Optional($0.updated_at)].compactMap { $0 } }
        let activityDates = store.agentActivityByTodoID.values.map(\.updated_at)
        guard let latest = (todoDates + cronDates + activityDates).max() else {
            return "No runs yet"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last run \(formatter.localizedString(for: latest, relativeTo: Date()))"
    }
}

private enum SettingsRoute: Hashable {
    case userProfile(displayName: String, avatarImageData: Data?, avatarURL: URL?)
    case agentProfile(lastRunText: String)
    case connections
    case memory

    var title: String {
        switch self {
        case .userProfile:
            return "You"
        case .agentProfile:
            return "doit"
        case .connections: return "Connections"
        case .memory: return "Memory"
        }
    }

    var icon: String {
        switch self {
        case .userProfile: return "person.crop.circle"
        case .agentProfile: return "sparkles"
        case .connections: return "arrow.left.arrow.right"
        case .memory: return "book.pages"
        }
    }

    @ViewBuilder
    var content: some View {
        switch self {
        case .userProfile(let displayName, let avatarImageData, let avatarURL):
            UserProfileView(
                initialDisplayName: displayName,
                initialAvatarImageData: avatarImageData,
                initialAvatarURL: avatarURL
            )
        case .agentProfile(let lastRunText):
            AgentProfileView(lastRunText: lastRunText)
        case .connections:
            IntegrationsView()
        case .memory:
            MemoryView()
        }
    }
}

private struct SettingsPageHeader: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(white: 0.08))

            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(white: 0.58))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")

                Spacer()
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 56)
        .padding(.bottom, 4)
        .background(Color.white)
        .zIndex(1)
    }
}

private struct SettingsRow: View {
    let icon: String
    let title: String
    var value: String?
    var showsChevron = true
    var trailingSystemName = "chevron.right"
    var trailingRotation: Angle = .zero

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Color(white: 0.58))
                .frame(width: 34, height: 38)

            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(white: 0.18))

            Spacer(minLength: 12)

            if let value, !value.isEmpty {
                Text(value)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(white: 0.42))
                    .lineLimit(1)
            }

            if showsChevron {
                Image(systemName: trailingSystemName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(white: 0.72))
                    .rotationEffect(trailingRotation)
            }
        }
        .frame(minHeight: 54)
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
    }
}

private struct PersonRow: View {
    let avatar: ProfileAvatar.Kind
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 16) {
            ProfileAvatar(kind: avatar, size: 54)
                .id("settings-row-avatar-\(title)")

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(white: 0.16))
                Text(subtitle)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(white: 0.58))
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(white: 0.72))
        }
        .frame(minHeight: 78)
        .padding(.horizontal, 20)
    }
}

private struct ModelPickerCard: View {
    let catalog: [AgentModelProviderOption]
    let selectedSetting: AgentModelSetting?
    let loading: Bool
    let saving: Bool
    let error: String?
    let height: CGFloat
    let onClose: () -> Void
    let onSelect: (AgentModelProviderOption, AgentModelOption) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Select a model")
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
                .accessibilityLabel("Close model picker")
            }
            .padding(.leading, 22)
            .padding(.trailing, 16)
            .padding(.top, 22)
            .padding(.bottom, 16)

            SettingsDivider()

            Group {
                if loading && catalog.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if let error {
                                Text(error)
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 14)
                                SettingsDivider(leadingPadding: 20)
                            }

                            ForEach(catalog) { provider in
                                ForEach(provider.models) { model in
                                    ModelPickerRow(
                                        provider: provider,
                                        model: model,
                                        isSelected: selectedSetting?.provider == provider.id
                                            && selectedSetting?.model == model.id,
                                        saving: saving,
                                        onSelect: { onSelect(provider, model) }
                                    )
                                    SettingsDivider(leadingPadding: 72)
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: height)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 28, y: 18)
    }
}

private struct ModelPickerRow: View {
    let provider: AgentModelProviderOption
    let model: AgentModelOption
    let isSelected: Bool
    let saving: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                ModelProviderLogo(providerID: provider.id)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(provider.name) - \(model.name)")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(white: 0.14))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    HStack(spacing: 7) {
                        Text(priceLabel(for: model.label))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(white: 0.72))

                        Circle()
                            .fill(Color(white: 0.78))
                            .frame(width: 3, height: 3)

                        Text(model.label)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color(white: 0.52))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 12)

                if saving && isSelected {
                    ProgressView()
                        .controlSize(.small)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.green)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(saving)
    }

    private func priceLabel(for label: String) -> String {
        switch label {
        case "Premium":
            return "$$$"
        case "Strong", "Legacy Strong", "Balanced":
            return "$$"
        case "Efficient", "Budget":
            return "$"
        default:
            return "$$"
        }
    }

    private func labelColor(_ label: String) -> Color {
        switch label {
        case "Premium": return .purple
        case "Strong", "Legacy Strong": return .blue
        case "Efficient", "Balanced": return .green
        case "Budget": return .orange
        default: return .secondary
        }
    }
}

private struct ModelProviderLogo: View {
    let providerID: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(white: 0.96))

            if providerID == "openai" || providerID == "anthropic" {
                Image(providerID)
                    .resizable()
                    .scaledToFit()
                    .padding(7)
            } else {
                Text(providerID.prefix(1).uppercased())
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(white: 0.32))
            }
        }
        .frame(width: 38, height: 38)
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color(white: 0.9), lineWidth: 1)
        }
    }
}

struct ProfileAvatar: View {
    enum Kind {
        case user(initials: String?, imageData: Data?, url: URL?)
        case agent
    }

    let kind: Kind
    let size: CGFloat

    var body: some View {
        Group {
            switch kind {
            case .user(let initials, let imageData, let url):
                if let imageData, let image = UIImage(data: imageData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if let url {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .scaledToFill()
                        } else {
                            initialsFallback(initials)
                        }
                    }
                } else {
                    initialsFallback(initials)
                }
            case .agent:
                Image("doit_pofile")
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(Color(white: 0.9), lineWidth: 1)
        }
    }

    private func initialsFallback(_ initials: String?) -> some View {
        ZStack {
            Circle()
                .fill(Color.black)

            if let initials, !initials.isEmpty {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }
}

private struct UserProfileView: View {
    @Environment(AuthModel.self) private var auth
    @State private var displayName = ""
    @State private var avatarImageData: Data?
    @State private var originalAvatarURL: URL?
    @State private var photoSelection: PhotosPickerItem?
    @State private var saving = false
    @State private var error: String?

    init(
        initialDisplayName: String? = nil,
        initialAvatarImageData: Data? = nil,
        initialAvatarURL: URL? = nil
    ) {
        _displayName = State(initialValue: initialDisplayName ?? "")
        _avatarImageData = State(initialValue: initialAvatarImageData)
        _originalAvatarURL = State(initialValue: initialAvatarURL)
    }

    var body: some View {
        VStack(spacing: 28) {
            PhotosPicker(selection: $photoSelection, matching: .images, photoLibrary: .shared()) {
                VStack(spacing: 10) {
                    ProfileAvatar(
                        kind: .user(
                            initials: initials(for: currentDisplayName),
                            imageData: currentAvatarImageData,
                            url: currentAvatarImageData == nil ? currentAvatarURL : nil
                        ),
                        size: 92
                    )
                    .id("profile-editor-avatar")
                    Text("Change Photo")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(white: 0.36))
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 28)

            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(white: 0.58))
                TextField("Your name", text: $displayName)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .textInputAutocapitalization(.words)
                    .padding(.vertical, 12)
                SettingsDivider(leadingPadding: 0)
            }
            .padding(.horizontal, 20)

            if let error {
                Text(error)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .navigationTitle("You")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving" : "Save") {
                    Task { await save() }
                }
                .disabled(saving)
            }
        }
        .onAppear {
            if displayName.isEmpty {
                displayName = auth.displayName
            }
            if avatarImageData == nil {
                avatarImageData = auth.avatarImageData
            }
            if originalAvatarURL == nil {
                originalAvatarURL = auth.avatarURL
            }
        }
        .onChange(of: photoSelection) { _, newValue in
            guard let newValue else { return }
            Task { await loadPhoto(newValue) }
        }
    }

    private var currentDisplayName: String {
        displayName.isEmpty ? auth.displayName : displayName
    }

    private var currentAvatarImageData: Data? {
        avatarImageData ?? auth.avatarImageData
    }

    private var currentAvatarURL: URL? {
        originalAvatarURL ?? auth.avatarURL
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let resized = image.resizedToFill(maxDimension: 320),
                  let jpegData = resized.jpegData(compressionQuality: 0.72)
            else {
                error = "Couldn't load that photo."
                return
            }
            avatarImageData = jpegData
            error = nil
        } catch {
            self.error = "Couldn't load that photo."
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await auth.updateProfile(displayName: displayName, avatarImageData: avatarImageData)
            error = nil
        } catch {
            self.error = "Couldn't save your profile."
        }
    }

    private func initials(for name: String) -> String? {
        let parts = name.split(separator: " ")
        let first = parts.first?.first.map { String($0).uppercased() } ?? ""
        let last = parts.dropFirst().first?.first.map { String($0).uppercased() } ?? ""
        let combined = first + last
        return combined.isEmpty ? nil : combined
    }
}

private struct AgentProfileView: View {
    let lastRunText: String

    var body: some View {
        VStack(spacing: 18) {
            ProfileAvatar(kind: .agent, size: 92)
                .padding(.top, 28)
            Text("doit")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(white: 0.14))
            Text(lastRunText)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Color(white: 0.58))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .navigationTitle("doit")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SettingsGroup<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsDivider(leadingPadding: 66)
            content
                .buttonStyle(.plain)
            SettingsDivider(leadingPadding: 66)
        }
    }
}

private struct SectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(white: 0.68))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
}

private struct SettingsDivider: View {
    var leadingPadding: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color(white: 0.94))
            .frame(height: 1)
            .padding(.leading, leadingPadding)
    }
}

private extension UIImage {
    func resizedToFill(maxDimension: CGFloat) -> UIImage? {
        let longestSide = max(size.width, size.height)
        guard longestSide > 0 else { return nil }
        let scale = min(1, maxDimension / longestSide)
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
