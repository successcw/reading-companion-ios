import AVFoundation
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var speech = SpeechRecognizer()
    @StateObject private var tts = TTSPlayer()
    @StateObject private var server = LocalHTTPServer()
    private let llm = LLMClient()

    @State private var context = ReadingContext.empty
    @State private var turns: [ChatTurn] = []
    @State private var partial = ""
    @State private var assistantID: UUID?
    @State private var pendingText = ""
    @State private var revealTimer: Timer?
    @State private var isThinking = false
    @State private var responseID: UUID?
    @State private var status = "正在准备…"
    @State private var showSettings = false
    @State private var address = ""

    @State private var apiKey = KeychainStore.read("opencode_api_key")
    @State private var model = UserDefaults.standard.string(forKey: "llm_model") ?? "deepseek-v4.1-flash"
    @State private var tencentSecretId = KeychainStore.read("tencent_secret_id")
    @State private var tencentSecretKey = KeychainStore.read("tencent_secret_key")
    @State private var tencentRegion = UserDefaults.standard.string(forKey: "tencent_region") ?? "ap-guangzhou"
    @State private var portText = UserDefaults.standard.string(forKey: "server_port") ?? "8790"
    @State private var token = UserDefaults.standard.string(forKey: "server_token") ?? "change-me"

    private let cream = Color(red: 0.98, green: 0.95, blue: 0.89)
    private let ink = Color(red: 0.24, green: 0.18, blue: 0.13)
    private let orange = Color(red: 0.86, green: 0.47, blue: 0.18)

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                topBar
                contextCard
                    .padding(.top, 14)
                transcript
                    .padding(.horizontal, 2)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.28), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.top, 6)
                if !partial.isEmpty {
                    Text(partial)
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(orange)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.top, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                listeningPill
                    .padding(.top, 10)
                    .padding(.bottom, 10)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
        }
        .onAppear(perform: setup)
        .onChange(of: speech.transcript) { _, value in
            // Show the user's sentence as soon as Apple Speech emits partials,
            // not only after the assistant starts replying.
            partial = value
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            speech.stop()
            server.stop()
            tts.stop()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                tts: tts,
                apiKey: $apiKey,
                model: $model,
                tencentSecretId: $tencentSecretId,
                tencentSecretKey: $tencentSecretKey,
                tencentRegion: $tencentRegion,
                portText: $portText,
                token: $token,
                address: address,
                onSave: applySettings
            )
        }
    }

    private var background: some View {
        GeometryReader { proxy in
            ZStack {
                Image("Cat")
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .blur(radius: 0.6)
                    .opacity(0.48)
                LinearGradient(
                    colors: [cream.opacity(0.97), cream.opacity(0.52), cream.opacity(0.97)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("橘猫陪读")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink)
                Text("读到哪，就陪你聊到哪")
                    .font(.system(size: 12))
                    .foregroundStyle(ink.opacity(0.55))
            }
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.7))
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(context.book.isEmpty ? orange.opacity(0.35) : Color.green.opacity(0.85))
                    .frame(width: 7, height: 7)
                Text(context.book.isEmpty ? "等 Kindle 翻页…" : context.book)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ink.opacity(0.85))
                    .lineLimit(1)
                Spacer()
                if !context.book.isEmpty {
                    Text(context.pageLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ink.opacity(0.5))
                }
            }
            if !context.chapter.isEmpty {
                Text(context.chapter)
                    .font(.system(size: 12))
                    .foregroundStyle(ink.opacity(0.5))
                    .lineLimit(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(orange.opacity(0.13))
                    Capsule()
                        .fill(orange.opacity(0.75))
                        .frame(width: max(4, geo.size.width * min(100, max(0, context.progress)) / 100))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.white.opacity(0.52), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.55), lineWidth: 1)
        )
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(turns) { turn in
                        turnView(turn)
                    }
                    if isThinking {
                        HStack(spacing: 6) {
                            ProgressView().tint(orange)
                            Text("在想…")
                                .font(.system(size: 13))
                                .foregroundStyle(ink.opacity(0.5))
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.bottom)
        }
    }

    private func turnView(_ turn: ChatTurn) -> some View {
        HStack {
            if turn.role == .user { Spacer(minLength: 24) }
            Text(turn.text)
                .font(.system(size: turn.role == .assistant ? 18 : 16,
                              design: turn.role == .assistant ? .serif : .rounded))
                .foregroundStyle(ink.opacity(0.9))
                .lineSpacing(turn.role == .assistant ? 5 : 3)
                .padding(.horizontal, turn.role == .assistant ? 0 : 13)
                .padding(.vertical, turn.role == .assistant ? 2 : 9)
                .background(
                    turn.role == .user ? orange.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                )
            if turn.role == .assistant { Spacer(minLength: 24) }
        }
    }

    private var listeningPill: some View {
        HStack(spacing: 10) {
            catIndicator
            VStack(alignment: .leading, spacing: 1) {
                Text(displayStatus)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(ink.opacity(0.8))
                Text(hintText)
                    .font(.system(size: 11))
                    .foregroundStyle(ink.opacity(0.45))
            }
            Spacer()
            if isThinking || tts.isSpeaking {
                Button {
                    stopResponding()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(orange)
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.75), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("停止回答")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.5), lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture {
            toggleRecording()
        }
    }

    private var catIndicator: some View {
        TimelineView(.animation(minimumInterval: 0.16)) { timeline in
            catFrame(at: timeline.date)
        }
    }

    private func catFrame(at date: Date) -> some View {
        let tick = Int(date.timeIntervalSinceReferenceDate / 0.16)
        let talking = tts.isAudioActive
        let listening = speech.isRecording
        let name: String
        if talking {
            let talkFrames = ["CatTalk1", "CatTalk2", "CatTalk3"]
            name = talkFrames[tick % talkFrames.count]
        } else if listening {
            name = tick % 2 == 0 ? "CatListen1" : "CatListen2"
        } else {
            name = "CatIdle"
        }
        return Image(name)
            .resizable()
            .scaledToFill()
            .frame(width: 40, height: 40)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1.5))
    }

    private func toggleRecording() {
        guard !isThinking, !tts.isSpeaking, !speech.isTranscribing else { return }
        if speech.isRecording {
            speech.endRecording()
        } else {
            speech.beginRecording()
        }
    }

    private var waveBars: some View {
        TimelineView(.animation(minimumInterval: 0.08)) { timeline in
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<4, id: \.self) { index in
                    let phase = timeline.date.timeIntervalSinceReferenceDate * 4 + Double(index)
                    let active = tts.isSpeaking || isThinking
                    let mic = max(speech.level, active ? 0.2 : 0.04)
                    let wobble = 0.55 + 0.45 * abs(sin(phase))
                    let level = min(1, mic * wobble * 2.2)
                    Capsule()
                        .fill(orange.opacity(level > 0.18 ? 0.8 : 0.3))
                        .frame(width: 3, height: 5 + 13 * min(1, level))
                }
            }
            .frame(width: 28)
        }
    }

    private var displayStatus: String {
        if isThinking { return "在想…" }
        if tts.isSpeaking { return "说话中" }
        return speech.status
    }

    private var hintText: String {
        if isThinking { return "点右侧停止可打断" }
        if tts.isSpeaking { return "轻点停止回答" }
        if speech.isRecording { return "再点一下发送" }
        if speech.isTranscribing { return "正在识别…" }
        return "轻点任意位置"
    }

    private func setup() {
        UIApplication.shared.isIdleTimerDisabled = true
        address = "http://\(LocalNetwork.bestAddress()):\(portText)/context"
        server.token = token
        server.onContext = { newContext in
            withAnimation(.easeOut(duration: 0.2)) {
                context = newContext
            }
            var phrases = [newContext.book, newContext.chapter, "微信读书", "这一页"]
            let pieces = newContext.text
                .components(separatedBy: CharacterSet(charactersIn: "。！？!?\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 4 }
            phrases.append(contentsOf: pieces.prefix(6))
            speech.contextualStrings = phrases
        }
        restartServer()
        speech.configureTencent(secretId: tencentSecretId,
                                secretKey: tencentSecretKey,
                                region: tencentRegion)
        speech.onUtterance = handleUtterance
        speech.start()
    }

    private func restartServer() {
        let port = UInt16(portText) ?? 8790
        server.start(port: port)
        address = "http://\(LocalNetwork.bestAddress()):\(port)/context"
    }

    private func applySettings() {
        KeychainStore.save(apiKey, for: "opencode_api_key")
        KeychainStore.save(tencentSecretId, for: "tencent_secret_id")
        KeychainStore.save(tencentSecretKey, for: "tencent_secret_key")
        UserDefaults.standard.set(model, forKey: "llm_model")
        UserDefaults.standard.set(tencentRegion, forKey: "tencent_region")
        speech.configureTencent(secretId: tencentSecretId,
                                secretKey: tencentSecretKey,
                                region: tencentRegion)
        UserDefaults.standard.set(portText, forKey: "server_port")
        UserDefaults.standard.set(token, forKey: "server_token")
        server.token = token
        restartServer()
    }

    private func startRevealTimer() {
        revealTimer?.invalidate()
        revealTimer = Timer.scheduledTimer(withTimeInterval: 0.055, repeats: true) { _ in
            guard let index = turns.firstIndex(where: { $0.id == assistantID }) else { return }
            if pendingText.isEmpty { return }
            let take = min(3, pendingText.count)
            let end = pendingText.index(pendingText.startIndex, offsetBy: take)
            let chunk = String(pendingText[..<end])
            pendingText.removeFirst(take)
            turns[index].text += chunk
        }
    }

    private func stopRevealTimer() {
        revealTimer?.invalidate()
        revealTimer = nil
    }

    private func stopResponding() {
        llm.cancel()
        responseID = nil
        isThinking = false
        stopRevealTimer()
        pendingText = ""
        tts.stop()
        if let id = assistantID, let index = turns.firstIndex(where: { $0.id == id }),
           turns[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            turns.remove(at: index)
        }
        assistantID = nil
        speech.prepare()
    }

    private func handleUtterance(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        partial = ""
        turns.append(ChatTurn(role: .user, text: cleaned))
        let assistantTurn = ChatTurn(role: .assistant, text: "")
        turns.append(assistantTurn)
        assistantID = assistantTurn.id
        pendingText = ""
        stopRevealTimer()
        isThinking = true
        speech.pause()
        let requestID = UUID()
        responseID = requestID

        tts.beginStreaming {
            assistantID = nil
            speech.prepare()
        }

        let config = LLMConfig(baseURL: "https://opencode.ai/zen/go/v1",
                               model: model,
                               apiKey: apiKey)
        llm.stream(turns: turns, context: context, config: config) { delta in
            guard responseID == requestID else { return }
            pendingText += delta
            if revealTimer == nil {
                startRevealTimer()
            }
            tts.appendStreaming(delta)
        } onDone: { result in
            guard responseID == requestID else { return }
            responseID = nil
            isThinking = false
            switch result {
            case .success:
                if !pendingText.isEmpty, let index = turns.firstIndex(where: { $0.id == assistantTurn.id }) {
                    turns[index].text += pendingText
                    pendingText = ""
                }
                stopRevealTimer()
                tts.finishStreaming()
            case .failure(let error):
                tts.stop()
                if let index = turns.firstIndex(where: { $0.id == assistantTurn.id }) {
                    turns[index].text = "请求失败：\(error.localizedDescription)"
                }
                assistantID = nil
                stopRevealTimer()
                speech.prepare()
            }
        }
    }

}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var tts: TTSPlayer

    @Binding var apiKey: String
    @Binding var model: String
    @Binding var tencentSecretId: String
    @Binding var tencentSecretKey: String
    @Binding var tencentRegion: String
    @Binding var portText: String
    @Binding var token: String
    let address: String
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("OpenCode Go") {
                    SecureField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("模型", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Base URL: https://opencode.ai/zen/go/v1")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("语音识别") {
                    SecureField("腾讯云 SecretId", text: $tencentSecretId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("腾讯云 SecretKey", text: $tencentSecretKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("地域", text: $tencentRegion)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("配置后使用腾讯云一句话识别；留空则使用 Apple Speech。密钥只存本机 Keychain。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("在「语音识别控制台 > API 密钥管理」取 SecretId / SecretKey，不是 SDKAppID。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("朗读音色") {
                    Toggle("使用 Edge 在线音色", isOn: $tts.useEdge)
                    if tts.useEdge {
                        Picker("音色", selection: $tts.edgeVoiceID) {
                            ForEach(tts.edgeVoices) { voice in
                                Text(voice.label).tag(voice.id)
                            }
                        }
                        Text("Edge 音色在线合成，失败会自动回退系统语音。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("使用 iOS 系统语音。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("试听") {
                        tts.speak("你好，我是你的读书陪读。")
                    }
                }

                Section("Kindle 连接") {
                    TextField("端口", text: $portText)
                        .keyboardType(.numberPad)
                    TextField("Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text(address)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("把地址和 Token 填进 KOReader 插件的 config.lua。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("App 尽量保持前台；锁屏太久 iOS 会暂停本地服务。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave()
                        dismiss()
                    }
                }
            }
        }
    }
}
