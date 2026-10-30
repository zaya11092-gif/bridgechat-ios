import SwiftUI

struct SettingsView: View {
    @AppStorage("provider.name") private var pName = "Ollama"
    @AppStorage("provider.baseURL") private var pBase = "http://127.0.0.1:11434/v1"
    @AppStorage("provider.apiKey") private var pKey = ""
    @AppStorage("provider.model") private var pModel = "qwen2.5:14b"
    @AppStorage("provider.systemPrompt") private var pPrompt = "You are a helpful assistant."
    @AppStorage("includeLocation") private var includeLocation = false
    @AppStorage("includeCalendar") private var includeCalendar = false
    @AppStorage("bridgeURL") private var bridgeURL = ""
    @AppStorage("useBridgeMessages") private var useBridgeMessages = false

    @State private var models: [String] = []
    @State private var status = ""
    @State private var busy = false

    var config: ProviderConfig {
        ProviderConfig(name: pName, baseURL: pBase, apiKey: pKey, model: pModel, systemPrompt: pPrompt)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    Picker("Preset", selection: $pName) {
                        ForEach(ProviderConfig.presets.keys.sorted(), id: \.self) { Text($0) }
                    }
                    .onChange(of: pName) { _, newName in
                        if let preset = ProviderConfig.presets[newName] {
                            pBase = preset.baseURL
                            pModel = preset.model
                        }
                        Task { await fetchModels(silent: true) }
                    }
                    TextField("Base URL (incl. /v1)", text: $pBase)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: pBase) { _, _ in Task { await fetchModels(silent: true) } }
                    SecureField("API key (empty for local)", text: $pKey)
                        .onChange(of: pKey) { _, _ in Task { await fetchModels(silent: true) } }
                }

                Section("Model") {
                    if !models.isEmpty {
                        Picker("Model", selection: $pModel) {
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    TextField("or type a model id", text: $pModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(busy ? "Fetching..." : "Fetch model list") {
                        Task { await fetchModels() }
                    }
                    .disabled(busy)
                    if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
                }

                Section("System prompt") {
                    TextEditor(text: $pPrompt).frame(minHeight: 60)
                }

                Section {
                    Toggle("Share current location on send", isOn: $includeLocation)
                    Toggle("Share next 7 days of calendar", isOn: $includeCalendar)
                } header: { Text("Device data (with permission)") }
                footer: { Text("Photos are attached per message from the Chat tab. iOS shows a permission prompt the first time location or calendar is used.") }

                Section {
                    TextField("Bridge URL (optional)", text: $bridgeURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Include backup messages from bridge", isOn: $useBridgeMessages)
                } header: { Text("grok-bridge (optional)") }
                footer: { Text("If your PC runs grok-bridge, its iPhone-backup message history can feed this app's context. Nothing is sent anywhere except the provider you chose.") }
            }
            .navigationTitle("Settings")
            .task { await fetchModels(silent: true) }
        }
    }

    private func fetchModels(silent: Bool = false) async {
        guard !pBase.isEmpty else { return }
        busy = true
        if !silent { status = "fetching..." }
        do {
            models = try await LLMService(config: config).fetchModels()
            status = "\(models.count) models"
            if !models.contains(pModel), let first = models.first { pModel = first }
        } catch {
            status = silent ? "" : "failed: \(error.localizedDescription)"
        }
        busy = false
    }
}
