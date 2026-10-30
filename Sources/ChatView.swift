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
    private let spring = Animation.spring(response: 0.35, dampingFraction: 0.85)

    var config: ProviderConfig {
        ProviderConfig(name: pName, baseURL: pBase, apiKey: pKey, model: pModel, systemPrompt: pPrompt)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(turns) { turn in
                                Bubble(turn: turn)
                                    .id(turn.id)
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .opacity))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
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
            .navigationTitle(pModel.isEmpty ? pName : pModel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(spring) { turns.removeAll() }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                }
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            if !pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingImages.indices, id: \.self) { i in
                            thumb(pendingImages[i], onDelete: { withAnimation(spring) { pendingImages.remove(at: i) } })
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            HStack(spacing: 12) {
                PhotosPicker(selection: $pickerSelection, matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .onChange(of: pickerSelection) { _, items in
                    Task {
                        for item in items {
                            if let data = try? await item.loadTransferable(type: Data.self),
                               let img = UIImage(data: data),
                               let url = ImageKit.toDataURL(img) {
                                withAnimation(spring) { pendingImages.append(url) }
                            }
                        }
                        pickerSelection = []
                    }
                }
                TextField("Message", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(20)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: streaming ? "stop.fill" : "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(canSend || streaming ? Color.accentColor : Color(.systemGray4))
                        .clipShape(Circle())
                        .scaleEffect(streaming ? 0.92 : 1.0)
                        .animation(spring, value: streaming)
                }
                .disabled(!canSend && !streaming)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty
    }

    private func send() {
        if streaming {
            streaming = false   // soft stop; the running request finishes silently
            return
        }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        guard canSend else { return }
        input = ""
        errorText = ""
        withAnimation(spring) {
            pendingImages = []
            turns.append(ChatTurn(role: .user, text: text.isEmpty ? "(photos)" : text, images: images))
            turns.append(ChatTurn(role: .assistant, text: "", isStreaming: true))
        }
        streaming = true
        let assistantId = turns.last!.id

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
                location: await locator.current(), calendar: nil, bridgeMessages: nil)
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
        if !deviceContext.isEmpty,
           let lastUser = messages.lastIndex(where: { $0["role"] as? String == "user" }) {
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
        if images.isEmpty,
           let lastUser = messages.lastIndex(where: { $0["role"] as? String == "user" }),
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

    private func thumb(_ dataURL: String, onDelete: @escaping () -> Void) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let range = dataURL.range(of: "base64,"),
                   let data = Data(base64Encoded: String(dataURL[range.upperBound...])),
                   let img = UIImage(data: data) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Color.secondary
                }
            }
            .frame(width: 60, height: 60)
            .clipped()
            .cornerRadius(10)
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 6, y: -6)
        }
    }
}

// MARK: - message bubble, caret, typing dots

struct Bubble: View {
    let turn: ChatTurn
    private let bubbleShape = UnevenRoundedRectangle(topLeadingRadius: 18,
                                                     bottomLeadingRadius: 18,
                                                     bottomTrailingRadius: 18,
                                                     topTrailingRadius: 6,
                                                     style: .continuous)

    var body: some View {
        HStack(alignment: .bottom) {
            if turn.role == .user { Spacer(minLength: 56) }
            VStack(alignment: .leading, spacing: 8) {
                if !turn.images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(turn.images.indices, id: \.self) { i in
                            photoThumb(turn.images[i])
                        }
                    }
                }
                if turn.role == .assistant && turn.isStreaming && turn.text.isEmpty {
                    TypingIndicator()
                } else if !turn.text.isEmpty {
                    HStack(alignment: .bottom, spacing: 1) {
                        Text(turn.text)
                            .textSelection(.enabled)
                        if turn.isStreaming { Caret() }
                    }
                }
            }
            .modifier(BubbleChrome(role: turn.role, shape: bubbleShape))
            if turn.role == .assistant { Spacer(minLength: 56) }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity))
    }

    @ViewBuilder
    private func photoThumb(_ dataURL: String) -> some View {
        if let range = dataURL.range(of: "base64,"),
           let data = Data(base64Encoded: String(dataURL[range.upperBound...])),
           let img = UIImage(data: data) {
            Image(uiImage: img).resizable().scaledToFill()
                .frame(width: 170, height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

struct BubbleChrome: ViewModifier {
    let role: ChatTurn.Role
    let shape: UnevenRoundedRectangle

    func body(content: Content) -> some View {
        if role == .user {
            content
                .padding(11)
                .background(shape.fill(Color.accentColor.opacity(0.22)))
        } else {
            content.padding(.vertical, 2)
        }
    }
}

struct Caret: View {
    @State private var visible = true
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(width: 3, height: 15)
            .opacity(visible ? 1 : 0)
            .animation(.easeInOut(duration: 0.45).repeatForever(), value: visible)
            .onAppear { visible.toggle() }
    }
}

struct TypingIndicator: View {
    @State private var phase = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .scaleEffect(phase ? 1.0 : 0.55)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.18),
                               value: phase)
            }
        }
        .padding(.vertical, 6)
        .onAppear { phase = true }
    }
}
