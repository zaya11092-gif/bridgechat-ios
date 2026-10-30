import SwiftUI
import PhotosUI
import CoreLocation

struct ChatView: View {
    @AppStorage("provider.name") private var pName = "Ollama"
    @AppStorage("provider.baseURL") private var pBase = "http://127.0.0.1:11434/v1"
    @AppStorage("provider.apiKey") private var pKey = ""
    @AppStorage("provider.model") private var pModel = "qwen2.5:14b"
    @AppStorage("provider.systemPrompt") private var pPrompt = "You are a helpful assistant."
    @AppStorage("includeLocation") private var includeLocation = false
    @AppStorage("includeCalendar") private var includeCalendar = false
    @AppStorage("bridgeURL") private var bridgeURL = ""
    @AppStorage("useBridgeMessages") private var useBridgeMessages = false

    @State private var turns: [ChatTurn] = []
    @State private var input = ""
    @State private var pendingImages: [String] = []
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var streaming = false
    @State private var errorText = ""

    private let locator = LocationOneShot()

    var config: ProviderConfig {
        ProviderConfig(name: pName, baseURL: pBase, apiKey: pKey, model: pModel, systemPrompt: pPrompt)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(turns) { turn in
                                Bubble(turn: turn).id(turn.id)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: turns.last?.text) { _, _ in
                        if let last = turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                    .onChange(of: turns.count) { _, _ in
                        if let last = turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                if !errorText.isEmpty {
                    Text(errorText).font(.footnote).foregroundStyle(.red).padding(.horizontal)
                }
                inputBar
            }
            .navigationTitle(pName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { turns.removeAll() }
                }
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            if !pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(pendingImages.indices, id: \.self) { i in
                        if let ui = uiImage(pendingImages[i]) {
                            Image(uiImage: ui).resizable().scaledToFill()
                                .frame(width: 56, height: 56).clipped().cornerRadius(8)
                        }
                        Button { pendingImages.remove(at: i) } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                    } }
                }.padding(.horizontal)
            }
            HStack(spacing: 10) {
                PhotosPicker(selection: $pickerSelection, matching: .images) {
                    Image(systemName: "photo")
                }
                .onChange(of: pickerSelection) { _, items in
                    Task {
                        for item in items {
                            if let data = try? await item.loadTransferable(type: Data.self),
                               let img = UIImage(data: data),
                               let url = ImageKit.toDataURL(img) {
                                pendingImages.append(url)
                            }
                        }
                        pickerSelection = []
                    }
                }
                TextField("Message", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: streaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty && pendingImages.isEmpty && !streaming)
            }
            .padding(10)
        }
        .background(.bar)
    }

    private func send() {
        if streaming {
            streaming = false   // soft stop; current request finishes its turn
            return
        }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        guard !text.isEmpty || !images.isEmpty else { return }
        input = ""
        pendingImages = []
        errorText = ""
        turns.append(ChatTurn(role: .user, text: text.isEmpty ? "(photos)" : text, images: images))
        let assistant = ChatTurn(role: .assistant, text: "", isStreaming: true)
        turns.append(assistant)
        streaming = true
        let assistantId = assistant.id

        Task {
            do {
                try await runCompletion(assistantId: assistantId, userText: text, images: images)
            } catch {
                appendToTurn(assistantId, "⚠️ \(error.localizedDescription)")
            }
            markDone(assistantId)
            streaming = false
        }
    }

    private func runCompletion(assistantId: UUID, userText: String, images: [String]) async throws {
        var messages: [[String: Any]] = []
        if !pPrompt.isEmpty {
            messages.append(["role": "system", "content": pPrompt])
        }
        for t in turns where t.id != assistantId && t.role != .system {
            if t.text.isEmpty { continue }
            messages.append(t.payload())
        }
        var deviceContext = ""
        if includeLocation {
            deviceContext += DeviceContextBuilder.build(
                location: await locator.current(),
                calendar: nil, bridgeMessages: nil)
        }
        if includeCalendar {
            let cal = await CalendarReader.nextWeek()
            deviceContext += DeviceContextBuilder.build(
                location: nil, calendar: cal, bridgeMessages: nil)
        }
        if useBridgeMessages, !bridgeURL.isEmpty {
            let msgs = await fetchBridgeMessages()
            deviceContext += DeviceContextBuilder.build(
                location: nil, calendar: nil, bridgeMessages: msgs)
        }
        // attach device context + images to the final user turn
        if !deviceContext.isEmpty, let lastUser = messages.lastIndex(where: { $0["role"] as? String == "user" }) {
            var turn = messages[lastUser]
            if let content = turn["content"] as? String {
                turn["content"] = content + deviceContext
            } else if var parts = turn["content"] as? [[String: Any]] {
                if !parts.isEmpty, let old = parts[0]["text"] as? String {
                    parts[0]["text"] = old + deviceContext
                }
                turn["content"] = parts
            }
            messages[lastUser] = turn
        }
        if images.isEmpty, let lastUser = messages.lastIndex(where: { $0["role"] as? String == "user" }),
           messages[lastUser]["content"] == nil {
            messages[lastUser]["content"] = userText
        }

        let service = LLMService(config: config)
        try await service.streamChat(messages: messages) { delta in
            appendToTurn(assistantId, delta)
        }
    }

    private func fetchBridgeMessages() async -> String {
        guard let url = URL(string: bridgeURL.trimmingCharacters(in: .whitespaces) + "/messages/transcript") else {
            return "bridge URL invalid"
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct Resp: Decodable { let transcript: String }
            return try JSONDecoder().decode(Resp.self, from: data).transcript
        } catch {
            return "bridge unavailable (\(error.localizedDescription))"
        }
    }

    @MainActor
    private func appendToTurn(_ id: UUID, _ text: String) {
        if let i = turns.firstIndex(where: { $0.id == id }) {
            turns[i].text += text
        }
    }

    @MainActor
    private func markDone(_ id: UUID) {
        if let i = turns.firstIndex(where: { $0.id == id }) {
            turns[i].isStreaming = false
        }
    }

    private func uiImage(_ dataURL: String) -> UIImage? {
        guard let range = dataURL.range(of: "base64,") else { return nil }
        guard let data = Data(base64Encoded: String(dataURL[range.upperBound...])) else { return nil }
        return UIImage(data: data)
    }
}

struct Bubble: View {
    let turn: ChatTurn

    var body: some View {
        HStack {
            if turn.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                if !turn.images.isEmpty {
                    HStack {
                        ForEach(turn.images.indices, id: \.self) { i in
                            photoThumb(turn.images[i])
                        }
                    }
                }
                if !turn.text.isEmpty {
                    Text(turn.text)
                        .textSelection(.enabled)
                } else if turn.isStreaming {
                    Text("...").foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(turn.role == .user ? Color.accentColor.opacity(0.25) : Color(.systemGray6))
            .cornerRadius(14)
            if turn.role == .assistant { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private func photoThumb(_ dataURL: String) -> some View {
        if let range = dataURL.range(of: "base64,"),
           let data = Data(base64Encoded: String(dataURL[range.upperBound...])),
           let img = UIImage(data: data) {
            Image(uiImage: img).resizable().scaledToFill()
                .frame(width: 72, height: 72).clipped().cornerRadius(8)
        }
    }
}
