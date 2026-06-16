import SwiftUI

struct ModelSettingsView: View {
    @State private var catalog: [AgentModelProviderOption] = []
    @State private var setting: AgentModelSetting?
    @State private var selectedProviderID = ""
    @State private var selectedModelID = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        List {
            if loading && catalog.isEmpty {
                Section { ProgressView() }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }

            if !catalog.isEmpty {
                Section {
                    Picker("Provider", selection: $selectedProviderID) {
                        ForEach(catalog) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }
                } header: {
                    Text("Provider")
                } footer: {
                    Text("Hermes agent models are routed through OpenRouter.")
                }

                if let provider = selectedProvider {
                    Section {
                        Picker("Model", selection: $selectedModelID) {
                            ForEach(selectableModels(for: provider)) { model in
                                Text(model.name).tag(model.id)
                            }
                        }

                        if let model = selectedModel {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(model.label)
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(labelColor(model.label).opacity(0.14), in: Capsule())
                                        .foregroundStyle(labelColor(model.label))
                                    Text(model.id)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Text(model.description)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("Model")
                    } footer: {
                        Text("Doit manages provider API keys centrally. Users only choose from supported models.")
                    }

                    let locked = lockedModels(for: provider)
                    if !locked.isEmpty {
                        Section {
                            ForEach(locked) { model in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.name)
                                        Text("Premium — invite only")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "lock.fill")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } header: {
                            Text("Coming Soon")
                        }
                    }
                }

                if let setting {
                    Section {
                        HStack {
                            Text("Status")
                            Spacer()
                            Text(setting.apply_status.label)
                                .foregroundStyle(statusColor(setting.apply_status))
                        }
                        if let error = setting.apply_error, !error.isEmpty {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    } header: {
                        Text("Hermes")
                    } footer: {
                        Text("Changes are applied on the VM before the agent starts its next task.")
                    }
                }

                Section {
                    Button(saving ? "Saving..." : "Save Model Settings") {
                        Task { await save() }
                    }
                    .disabled(!canSave || saving)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.white)
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: selectedProviderID) { _, _ in
            guard let provider = selectedProvider else { return }
            let selectable = selectableModels(for: provider)
            if !selectable.contains(where: { $0.id == selectedModelID }) {
                selectedModelID = selectable.first?.id ?? ""
            }
        }
    }

    private var selectedProvider: AgentModelProviderOption? {
        catalog.first { $0.id == selectedProviderID }
    }

    private var selectedModel: AgentModelOption? {
        selectedProvider?.models.first { $0.id == selectedModelID }
    }

    private var canSave: Bool {
        guard let model = selectedModel else { return false }
        return selectedProvider != nil && !model.isLocked
    }

    private func selectableModels(for provider: AgentModelProviderOption) -> [AgentModelOption] {
        provider.models.filter { !$0.isLocked }
    }

    private func lockedModels(for provider: AgentModelProviderOption) -> [AgentModelOption] {
        provider.models.filter(\.isLocked)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let response = try await AgentSettingsAPI.getModelSettings()
            catalog = response.catalog
            setting = response.setting
            if let setting = response.setting,
               let provider = response.catalog.first(where: { $0.id == setting.provider }),
               provider.models.contains(where: { $0.id == setting.model && !$0.isLocked }) {
                selectedProviderID = setting.provider
                selectedModelID = setting.model
            } else if let provider = response.catalog.first {
                selectedProviderID = provider.id
                selectedModelID = selectableModels(for: provider).first?.id ?? ""
            }
            error = nil
        } catch {
            self.error = "Couldn't load model settings: \(error.localizedDescription)"
        }
    }

    private func save() async {
        guard let model = selectedModel, !model.isLocked else { return }
        saving = true
        defer { saving = false }
        do {
            setting = try await AgentSettingsAPI.updateModelSettings(
                provider: selectedProviderID,
                model: selectedModelID
            )
            error = nil
        } catch {
            self.error = "Couldn't save model settings: \(error.localizedDescription)"
        }
    }

    private func statusColor(_ status: AgentModelApplyStatus) -> Color {
        switch status {
        case .pending: return .orange
        case .applied: return .green
        case .failed: return .red
        }
    }

    private func labelColor(_ label: String) -> Color {
        switch label {
        case "Premium", "Strong+": return .purple
        case "Strong", "Legacy Strong", "Balanced+": return .blue
        case "Efficient", "Balanced": return .green
        case "Budget": return .orange
        default: return .secondary
        }
    }
}
