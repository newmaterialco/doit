import SwiftUI

struct MemoryView: View {
    @Environment(AuthModel.self) private var auth

    @State private var memories: [AgentMemory] = []
    @State private var loading = true
    @State private var error: String?
    @State private var showAddSheet = false
    @State private var automaticSuggestionsEnabled = true
    @State private var customInstructions = ""
    @State private var savingSettings = false

    var body: some View {
        List {
            Section {
                Text("This controls what Doit will remember for future tasks. Doit learns durable preferences and facts after conversations, you can pin your own, and remembered items are synced into Hermes before the next run.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("How memory works") {
                Label("Passbook shows the newest things Doit learned about you.", systemImage: "menucard")
                Label("Settings lets you edit or forget them.", systemImage: "slider.horizontal.3")
                Label("Remembered items are sent to the agent.", systemImage: "checkmark.seal")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            Section("Controls") {
                Toggle("Automatic memory learning", isOn: $automaticSuggestionsEnabled)
                    .onChange(of: automaticSuggestionsEnabled) { _, _ in
                        Task { await saveSettings() }
                    }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom memory instructions")
                        .font(.subheadline.weight(.semibold))
                    Text("Example: remember writing preferences, but do not remember personal contacts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $customInstructions)
                        .frame(minHeight: 90)
                    Button(savingSettings ? "Saving..." : "Save Instructions") {
                        Task { await saveSettings() }
                    }
                    .disabled(savingSettings)
                }
            }

            if loading && memories.isEmpty {
                Section { ProgressView() }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }

            if memories.isEmpty && !loading {
                Section {
                    ContentUnavailableView(
                        "Nothing remembered yet",
                        systemImage: "brain.head.profile",
                        description: Text("Tap + to pin something Doit should remember. Memories learned from conversations will show up here and in Passbook.")
                    )
                }
            } else {
                ForEach(memorySections, id: \.id) { section in
                    let group = section.memories
                    if !group.isEmpty {
                        Section {
                            ForEach(group) { memory in
                                NavigationLink {
                                    MemoryEditorView(existing: memory) { updated in
                                        await save(memory, draft: updated)
                                    }
                                } label: {
                                    MemoryRow(memory: memory)
                                }
                            }
                            .onDelete { offsets in
                                deleteRows(in: group, at: offsets)
                            }
                        } header: {
                            Text(section.title)
                        } footer: {
                            Text(section.hint)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppSemanticColors.surface)
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add memory")
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack {
                MemoryEditorView(existing: nil) { draft in
                    await create(draft)
                    showAddSheet = false
                }
            }
        }
    }

    private var userID: UUID? {
        if case .signedIn(let userID) = auth.state {
            return userID
        }
        return nil
    }

    private var memorySections: [MemorySection] {
        [
            MemorySection(
                id: "about-you",
                title: MemoryTarget.user.label,
                hint: "Preferences, identity, communication style. Lands in USER.md.",
                memories: memories.filter { $0.isUsableMemory && $0.effectiveTarget == .user }
            ),
            MemorySection(
                id: "agent-notes",
                title: MemoryTarget.memory.label,
                hint: "Workflow facts, conventions, lessons. Lands in MEMORY.md.",
                memories: memories.filter { $0.isUsableMemory && $0.effectiveTarget == .memory }
            ),
            MemorySection(
                id: "rejected",
                title: "Rejected",
                hint: "Doit will not use these unless you edit and save them again.",
                memories: memories.filter { $0.effectiveMemoryStatus == .rejected }
            ),
        ]
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            async let memoriesTask = MemoriesAPI.list()
            if let userID {
                async let settingsTask = MemorySettingsAPI.get(userID: userID)
                let settings = try await settingsTask
                automaticSuggestionsEnabled = settings.automatic_suggestions_enabled
                customInstructions = settings.custom_instructions ?? ""
            }
            memories = try await memoriesTask
            error = nil
        } catch {
            self.error = "Couldn't load memories: \(error.localizedDescription)"
        }
    }

    private func saveSettings() async {
        guard let userID else { return }
        savingSettings = true
        defer { savingSettings = false }
        do {
            let settings = try await MemorySettingsAPI.upsert(
                userID: userID,
                automaticSuggestionsEnabled: automaticSuggestionsEnabled,
                customInstructions: customInstructions
            )
            automaticSuggestionsEnabled = settings.automatic_suggestions_enabled
            customInstructions = settings.custom_instructions ?? ""
            error = nil
        } catch {
            self.error = "Couldn't save memory settings: \(error.localizedDescription)"
        }
    }

    private func create(_ draft: MemoryDraft) async {
        guard let userID else { return }
        do {
            let memory = try await MemoriesAPI.create(
                title: draft.title,
                body: draft.body,
                category: draft.category,
                target: draft.target,
                userID: userID
            )
            memories.insert(memory, at: 0)
            error = nil
        } catch {
            self.error = "Couldn't save memory: \(error.localizedDescription)"
        }
    }

    private func save(_ memory: AgentMemory, draft: MemoryDraft) async {
        do {
            var updated = memory
            updated.title = draft.title
            updated.body = draft.body
            updated.category = draft.category.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            updated.target = draft.target
            try await MemoriesAPI.update(updated)
            await load()
        } catch {
            self.error = "Couldn't update memory: \(error.localizedDescription)"
        }
    }

    private func deleteRows(in group: [AgentMemory], at offsets: IndexSet) {
        let toDelete = offsets.map { group[$0] }
        memories.removeAll { row in toDelete.contains(where: { $0.id == row.id }) }
        Task {
            for memory in toDelete {
                try? await MemoriesAPI.delete(memory.id)
            }
        }
    }
}

private struct MemorySection {
    let id: String
    let title: String
    let hint: String
    let memories: [AgentMemory]
}

private struct MemoryRow: View {
    let memory: AgentMemory

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(memory.title)
                    .font(.headline)
                if let category = memory.category, !category.isEmpty {
                    Text(category)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                        .foregroundStyle(.blue)
                }
                Spacer(minLength: 4)
                MemorySyncBadge(memory: memory)
            }
            Text(memory.body)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if let reason = memory.memory_reason, !reason.isEmpty {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let error = memory.sync_error, !error.isEmpty,
               memory.effectiveSyncStatus == .failed {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MemorySyncBadge: View {
    let memory: AgentMemory

    var body: some View {
        let (text, color): (String, Color) = {
            switch (memory.effectiveMemoryStatus, memory.effectiveSource, memory.effectiveSyncStatus) {
            case (.proposed, _, _):
                return ("Learned", .blue)
            case (.rejected, _, _):
                return ("Rejected", .gray)
            case (.deleted, _, _):
                return ("Forgotten", .gray)
            case (.active, .hermes, _):
                return ("Learned by agent", .purple)
            case (.active, .doit, .synced):
                return ("Learned", .blue)
            case (.active, .doit, .pending):
                return ("Syncing", .orange)
            case (.active, .doit, .failed):
                return ("Sync failed", .red)
            case (.active, .user, .synced):
                return ("Pinned", .green)
            case (.active, .user, .pending):
                return ("Syncing", .orange)
            case (.active, .user, .failed):
                return ("Sync failed", .red)
            }
        }()
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }
}

struct MemoryDraft {
    var title: String
    var body: String
    var category: String
    var target: MemoryTarget
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private struct MemoryEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let existing: AgentMemory?
    let onSave: (MemoryDraft) async -> Void

    @State private var title: String
    @State private var bodyText: String
    @State private var category: String
    @State private var target: MemoryTarget
    @State private var saving = false

    init(existing: AgentMemory?, onSave: @escaping (MemoryDraft) async -> Void) {
        self.existing = existing
        self.onSave = onSave
        _title = State(initialValue: existing?.title ?? "")
        _bodyText = State(initialValue: existing?.body ?? "")
        _category = State(initialValue: existing?.category ?? "")
        _target = State(initialValue: existing?.effectiveTarget ?? .user)
    }

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $target) {
                    ForEach(MemoryTarget.allCases, id: \.self) { value in
                        Text(value.label).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                Text(target.hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Title", text: $title)
                TextField("Category (optional)", text: $category)
                    .textInputAutocapitalization(.words)
            }
            Section("What should the agent remember?") {
                TextEditor(text: $bodyText)
                    .frame(minHeight: 140)
            }

            if let existing, existing.effectiveSource == .hermes {
                Section {
                    Label(
                        "doit wrote this one. Edits will overwrite it and re-pin the entry.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(existing == nil ? "Add Memory" : "Edit Memory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(saving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving..." : "Save") {
                    Task { await save() }
                }
                .disabled(!canSave || saving)
            }
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() async {
        saving = true
        defer { saving = false }
        await onSave(
            MemoryDraft(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                body: bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
                category: category.trimmingCharacters(in: .whitespacesAndNewlines),
                target: target
            )
        )
        dismiss()
    }
}
