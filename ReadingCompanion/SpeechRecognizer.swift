import AVFoundation
import Foundation
import Speech

final class SpeechRecognizer: NSObject, ObservableObject {
    @Published var transcript: String = ""
    @Published var isListening: Bool = false
    @Published var level: CGFloat = 0
    @Published var status: String = "待机"

    var onUtterance: ((String) -> Void)?

    private let recognizer: SFSpeechRecognizer? = {
        for identifier in ["zh-CN", "zh-Hans", "zh"] {
            if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)) {
                return recognizer
            }
        }
        return nil
    }()
    var contextualStrings: [String] = []
    private let engine = AVAudioEngine()
    private let audioQueue = DispatchQueue(label: "com.cg.readingcompanion.speech")
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var taskGeneration = 0
    private var hasSpeech = false
    private var speechStarted = Date()
    private var lastVoice = Date()
    private var paused = false
    private var started = false
    private var authorized = false
    private var lastLog = Date.distantPast
    private var tapInstalled = false

    private let speechThreshold: Float = 0.002
    private let silenceSeconds: TimeInterval = 2.2
    private let minSpeechSeconds: TimeInterval = 0.35
    private let maxUtteranceSeconds: TimeInterval = 15
    private var preRoll: [AVAudioPCMBuffer] = []

    func start() {
        guard !started else { return }
        started = true
        print("ASR: start")
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self else { return }
            print("ASR: speech auth \(status.rawValue)")
            guard status == .authorized else {
                DispatchQueue.main.async { self.status = "语音识别未授权" }
                return
            }
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                print("ASR: mic granted \(granted)")
                guard granted else {
                    DispatchQueue.main.async { self.status = "麦克风未授权" }
                    return
                }
                DispatchQueue.main.async {
                    self.authorized = true
                    self.configureAudio()
                }
            }
        }
    }

    private func configureAudio() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.defaultToSpeaker])
            try session.setActive(true, options: [])
            // AirPods' noise cancellation often eats Chinese sentence starts and
            // makes Apple Speech much worse in noisy rooms. Prefer the phone mic.
            if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtIn)
            }
            let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
            print("ASR: input route \(inputs)")
        } catch {
            status = "音频初始化失败"
            return
        }

        installTapIfNeeded()
        engine.prepare()
        do {
            try engine.start()
            print("ASR: engine started")
            status = "我在听"
        } catch {
            status = "麦克风启动失败"
        }
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard authorized, !paused else { return }
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var sum: Float = 0
        for i in 0..<count {
            let value = channel[i]
            sum += value * value
        }
        let rms = sqrt(sum / Float(count))
        if Date().timeIntervalSince(lastLog) > 1 {
            lastLog = Date()
            print("ASR: rms \(rms)")
        }
        let level = min(1, CGFloat(rms) * 18)
        DispatchQueue.main.async { self.level = level }

        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let source = buffer.floatChannelData,
              let destination = copy.floatChannelData else { return }
        copy.frameLength = buffer.frameLength
        for channel in 0..<Int(buffer.format.channelCount) {
            memcpy(destination[channel], source[channel],
                   Int(buffer.frameLength) * MemoryLayout<Float>.size)
        }

        audioQueue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            if !self.hasSpeech {
                self.preRoll.append(copy)
                if self.preRoll.count > 4 { self.preRoll.removeFirst() }
            }
            if rms > self.speechThreshold {
                if !self.hasSpeech {
                    self.hasSpeech = true
                    self.speechStarted = now
                    self.beginRequest()
                    for buffered in self.preRoll {
                        self.request?.append(buffered)
                    }
                    self.preRoll.removeAll()
                    DispatchQueue.main.async { self.isListening = true; self.status = "我在听" }
                }
                self.lastVoice = now
            }

            // Keep feeding the recognizer during the silence grace period too.
            // This is what preserves soft trailing syllables before endAudio().
            if self.hasSpeech {
                self.request?.append(copy)
            }

            if self.hasSpeech,
               now.timeIntervalSince(self.lastVoice) > self.silenceSeconds,
               now.timeIntervalSince(self.speechStarted) > self.minSpeechSeconds {
                self.hasSpeech = false
                self.finishRequest()
            } else if self.hasSpeech,
                      now.timeIntervalSince(self.speechStarted) > self.maxUtteranceSeconds {
                // A long, noisy stretch with no clear pause: cut a segment so it
                // is not merged into one giant, low-accuracy utterance.
                self.hasSpeech = false
                self.finishRequest()
            }
        }
    }

    private func beginRequest() {
        guard let recognizer, recognizer.isAvailable else {
            print("ASR: recognizer unavailable")
            return
        }
        print("ASR: begin request")
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
        }
        // Use the Chinese on-device model when available; it is usually more
        // accurate than the server for quiet, close-mic reading sessions.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request
        taskGeneration += 1
        let generation = taskGeneration
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                print("ASR: partial \(text)")
                DispatchQueue.main.async { self.transcript = text }
                if result.isFinal {
                    self.deliverFinal(text, generation: generation)
                }
            }
            if let error {
                print("ASR: error \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.status = "识别失败：\(error.localizedDescription)"
                }
                self.deliverFinal(self.transcript, generation: generation)
            }
        }
    }

    private func deliverFinal(_ text: String, generation: Int) {
        guard generation == taskGeneration else { return }
        print("ASR: final \(text)")
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        taskGeneration += 1
        task = nil
        request = nil
        DispatchQueue.main.async {
            self.isListening = false
            self.level = 0
            self.status = "我在听"
            if cleaned.count >= 2 {
                self.transcript = ""
                self.onUtterance?(cleaned)
            }
        }
    }

    private func finishRequest() {
        print("ASR: finish")
        request?.endAudio()
        DispatchQueue.main.async { self.isListening = false }
    }

    func pause() {
        paused = true
        taskGeneration += 1
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        hasSpeech = false
        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        print("ASR: paused")
    }

    func resume() {
        paused = false
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.defaultToSpeaker])
            try session.setActive(true)
            if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtIn)
            }
        } catch {
            status = "麦克风恢复失败"
            return
        }
        installTapIfNeeded()
        if !engine.isRunning {
            do { try engine.start() } catch { print("ASR: resume engine failed \(error)") }
        }
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        print("ASR: resumed input \(inputs)")
        status = "我在听"
    }

    private func installTapIfNeeded() {
        guard !tapInstalled else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            status = "没有可用麦克风"
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }
        tapInstalled = true
        print("ASR: tap installed")
    }

    func stop() {
        paused = true
        taskGeneration += 1
        request?.endAudio()
        task?.cancel()
        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }
}
