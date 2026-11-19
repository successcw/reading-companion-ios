import AVFoundation
import Foundation
import SwiftEdgeTTS

struct EdgeVoiceOption: Identifiable, Hashable {
    let id: String
    let label: String
}

final class TTSPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    @Published var isSpeaking = false
    @Published var isAudioActive = false
    @Published var spokenRange: NSRange?
    @Published var useEdge: Bool {
        didSet { UserDefaults.standard.set(useEdge, forKey: "tts_use_edge") }
    }
    @Published var edgeVoiceID: String {
        didSet { UserDefaults.standard.set(edgeVoiceID, forKey: "tts_edge_voice") }
    }

    let edgeVoices: [EdgeVoiceOption] = [
        EdgeVoiceOption(id: "zh-CN-XiaoxiaoNeural", label: "晓晓 · 女声，自然"),
        EdgeVoiceOption(id: "zh-CN-YunxiNeural", label: "云希 · 男声，年轻"),
        EdgeVoiceOption(id: "zh-CN-XiaoyiNeural", label: "晓伊 · 女声，活泼"),
        EdgeVoiceOption(id: "zh-CN-YunjianNeural", label: "云健 · 男声，沉稳"),
        EdgeVoiceOption(id: "zh-CN-liaoning-XiaobeiNeural", label: "晓北 · 女声，东北"),
    ]

    private struct QueuedSpeech {
        let id: UUID
        let text: String
    }

    private let edge: EdgeTTSService
    private let system = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var synthesisTask: Task<Void, Never>?

    private var queue: [QueuedSpeech] = []
    private var synthCache: [UUID: Task<URL, Error>] = [:]
    private var queueRunning = false
    private var queueFinished = false
    private var queueOnFinish: (() -> Void)?
    private var streamBuffer = ""
    private var playerCompletion: (() -> Void)?
    private var systemCompletion: (() -> Void)?
    private var fallbackText = ""
    private var playbackGeneration = 0

    override init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 25
        edge = EdgeTTSService(session: URLSession(configuration: configuration))
        useEdge = UserDefaults.standard.object(forKey: "tts_use_edge") as? Bool ?? true
        edgeVoiceID = UserDefaults.standard.string(forKey: "tts_edge_voice") ?? "zh-CN-XiaoxiaoNeural"
        super.init()
        system.delegate = self
    }

    // MARK: - Streaming

    func beginStreaming(onFinish: @escaping () -> Void) {
        stop()
        queueOnFinish = onFinish
        queue = []
        synthCache = [:]
        streamBuffer = ""
        queueRunning = false
        queueFinished = false
        isSpeaking = true
    }

    func appendStreaming(_ delta: String) {
        guard isSpeaking else { return }
        streamBuffer += delta
        let stops = CharacterSet(charactersIn: "。！？!?；;\n")
        while let range = streamBuffer.rangeOfCharacter(from: stops) {
            let sentence = String(streamBuffer[..<range.upperBound])
            streamBuffer = String(streamBuffer[range.upperBound...])
            enqueue(sentence)
        }
        if streamBuffer.count > 45 {
            if let cut = streamBuffer.lastIndex(of: "，") ?? streamBuffer.lastIndex(of: ",")
                ?? streamBuffer.lastIndex(of: "、") ?? streamBuffer.lastIndex(of: " ") {
                let sentence = String(streamBuffer[...cut])
                streamBuffer = String(streamBuffer[streamBuffer.index(after: cut)...])
                enqueue(sentence)
            }
        }
    }

    func finishStreaming() {
        if !streamBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            enqueue(streamBuffer)
            streamBuffer = ""
        }
        queueFinished = true
        pump()
    }

    private func enqueue(_ raw: String) {
        let text = cleanForSpeech(raw)
        guard !text.isEmpty else { return }
        let item = QueuedSpeech(id: UUID(), text: text)
        queue.append(item)
        // Synthesize ahead while the previous sentence is still playing, so
        // punctuation does not create a long silent gap.
        if useEdge {
            synthCache[item.id] = makeSynthesisTask(text)
        }
        pump()
    }

    private func makeSynthesisTask(_ text: String) -> Task<URL, Error> {
        Task {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("tts-\(UUID().uuidString).mp3")
            _ = try await edge.synthesize(
                text: text,
                voice: edgeVoiceID,
                outputURL: url,
                rate: "+0%",
                volume: "+0%",
                pitch: "+0Hz"
            )
            return url
        }
    }

    private func pump() {
        guard !queueRunning, isSpeaking else { return }
        guard !queue.isEmpty else {
            if queueFinished { finishQueue() }
            return
        }
        queueRunning = true
        let item = queue.removeFirst()
        print("TTS: sentence start \(item.text.prefix(24))")
        let completion: () -> Void = { [weak self] in
            guard let self else { return }
            self.queueRunning = false
            self.pump()
        }
        let generation = playbackGeneration
        if let task = synthCache.removeValue(forKey: item.id) {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let url = try await task.value
                    guard !Task.isCancelled,
                          self.playbackGeneration == generation,
                          self.isSpeaking else { return }
                    await MainActor.run {
                        self.playFile(url, completion: completion, generation: generation)
                    }
                } catch {
                    print("Edge TTS: failed \(error)")
                    guard !Task.isCancelled,
                          self.playbackGeneration == generation,
                          self.isSpeaking else { return }
                    await MainActor.run {
                        self.speakSystem(item.text, completion: completion, generation: generation)
                    }
                }
            }
        } else {
            speakSystem(item.text, completion: completion, generation: generation)
        }
    }

    private func finishQueue() {
        guard isSpeaking else { return }
        isSpeaking = false
        isAudioActive = false
        spokenRange = nil
        let callback = queueOnFinish
        queueOnFinish = nil
        callback?()
    }

    // MARK: - One-off preview

    func speak(_ text: String, onFinish: (() -> Void)? = nil) {
        let cleaned = cleanForSpeech(text)
        guard !cleaned.isEmpty else {
            onFinish?()
            return
        }
        stop()
        isSpeaking = true
        let item = QueuedSpeech(id: UUID(), text: cleaned)
        queue = [item]
        queueFinished = true
        if useEdge { synthCache[item.id] = makeSynthesisTask(cleaned) }
        queueOnFinish = onFinish
        pump()
    }

    // MARK: - Playback

    private func configurePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP])
            try session.setActive(true)
            let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
            print("TTS: playback route \(outputs)")
        } catch {
            print("TTS: playback session failed \(error)")
        }
    }

    private func playFile(_ url: URL, completion: @escaping () -> Void, generation: Int) {
        guard playbackGeneration == generation, isSpeaking else { return }
        configurePlaybackSession()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            playerCompletion = completion
            player.play()
            isAudioActive = true
        } catch {
            print("TTS: player failed \(error)")
            speakSystem(fallbackText, completion: completion, generation: generation)
        }
    }

    private func speakSystem(_ raw: String, completion: @escaping () -> Void, generation: Int) {
        guard playbackGeneration == generation, isSpeaking else { return }
        let text = cleanForSpeech(raw)
        fallbackText = text
        configurePlaybackSession()
        player?.stop()
        player = nil
        playerCompletion = nil
        systemCompletion = completion
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = bestSystemVoice()
        utterance.rate = 0.47
        utterance.pitchMultiplier = 1.02
        utterance.volume = 1.0
        isAudioActive = true
        system.speak(utterance)
    }

    private func bestSystemVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
        return voices.first ?? AVSpeechSynthesisVoice(language: "zh-CN")
    }

    private func completeCurrent() {
        if let callback = playerCompletion {
            playerCompletion = nil
            callback()
            return
        }
        if let callback = systemCompletion {
            systemCompletion = nil
            callback()
        }
    }

    func stop() {
        playbackGeneration &+= 1
        synthesisTask?.cancel()
        synthesisTask = nil
        queue.forEach { synthCache[$0.id]?.cancel() }
        synthCache.values.forEach { $0.cancel() }
        synthCache.removeAll()
        queue.removeAll()
        streamBuffer = ""
        queueRunning = false
        queueFinished = false
        queueOnFinish = nil
        player?.stop()
        player = nil
        playerCompletion = nil
        systemCompletion = nil
        if system.isSpeaking {
            system.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        isAudioActive = false
        spokenRange = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.completeCurrent() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.completeCurrent() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.spokenRange = characterRange }
    }

    private func cleanForSpeech(_ text: String) -> String {
        var value = text
        value = value.replacingOccurrences(of: "**", with: "")
        value = value.replacingOccurrences(of: "*", with: "")
        value = value.replacingOccurrences(of: "`", with: "")
        value = value.replacingOccurrences(of: "#", with: "")
        value = value.replacingOccurrences(of: "> ", with: "")
        value = value.replacingOccurrences(of: "- ", with: "")
        value = value.replacingOccurrences(of: "——", with: "，")
        value = value.replacingOccurrences(of: "...", with: "。")
        value = value.replacingOccurrences(of: "…", with: "。")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
