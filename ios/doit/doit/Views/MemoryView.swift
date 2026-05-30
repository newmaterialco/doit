import SwiftUI

struct MemoryView: View {
    @Environment(AuthModel.self) private var auth

    @State private var memories: [AgentMemory] = []
    @State private var loading = true
    @State private var error: String?
    @State private var showAddSheet = false

    var body: some View {
        List {
            Section {
                Text("This is Hermes' built-in memory. The agent reads it at the start of every task and curates it as it learns. Entries you add here are pinned and reach the agent before the next run; entries with the \"Learned by agent\" tag were saved by Hermes itself. Memory is bounded, so the agent may consolidate older notes over time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                        description: Text("Tap + to pin something the agent should remember. Hermes will also add things here on its own as it works on your todos.")
                    )
                }
            } else {
                ForEach(MemoryTarget.allCases, id: \.self) { target in
                    let group = memories.filter { $0.effectiveTarget == target }
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
                            Text(target.label)
                        } footer: {
                            Text(target.hint)
                        }
                    }
                }
            }
        }
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

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            memories = try await MemoriesAPI.list()
            error = nil
        } catch {
            self.error = "Couldn't load memories: \(error.localizedDescription)"
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
            switch (memory.effectiveSource, memory.effectiveSyncStatus) {
            case (.hermes, _):
                return ("Learned by agent", .purple)
            case (.user, .synced):
                return ("Pinned", .green)
            case (.user, .pending):
                return ("Syncing", .orange)
            case (.user, .failed):
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
                        "Hermes wrote this one. Edits will overwrite it and re-pin the entry.",
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
