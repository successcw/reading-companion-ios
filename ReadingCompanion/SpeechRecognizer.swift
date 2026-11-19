import AVFoundation
import Foundation
import Speech

final class SpeechRecognizer: NSObject, ObservableObject {
    @Published var transcript: String = ""
    @Published var isListening: Bool = false
    @Published var isRecording: Bool = false
    @Published var isTranscribing: Bool = false
    @Published var level: CGFloat = 0
    @Published var status: String = "点这里开始说话"

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
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: 16_000,
                                             channels: 1,
                                             interleaved: true)!
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var taskGeneration = 0
    private var finalWatchdog: DispatchWorkItem?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var capturePCM = Data()
    private var recorder: AVAudioRecorder?
    private var recorderURL: URL?
    private var meterTimer: Timer?
    private var recordingStarted = Date()
    private var lastLog = Date.distantPast

    private var started = false
    private var authorized = false
    private var speechAuthorized = false
    private var paused = false
    private var wantsRecording = false
    private var pendingStart = false
    private var tapInstalled = false

    private var tencentSecretId = ""
    private var tencentSecretKey = ""
    private var tencentRegion = "ap-guangzhou"
    private let tencentClient = TencentASRClient()

    // Audio-session recovery state. Interruptions can happen while the user
    // is recording; never leave the engine in a half-started state.
    private var retryWork: DispatchWorkItem?
    private var retryDelay: TimeInterval = 0.5
    private var suppressRouteChangesUntil = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    private var tencentConfig: TencentASRConfig {
        TencentASRConfig(secretId: tencentSecretId,
                         secretKey: tencentSecretKey,
                         region: tencentRegion)
    }

    private var useTencent: Bool {
        tencentConfig.isConfigured
    }

    override init() {
        super.init()
        installSessionObservers()
    }

    deinit {
        retryWork?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func configureTencent(secretId: String, secretKey: String, region: String) {
        tencentSecretId = secretId.trimmingCharacters(in: .whitespacesAndNewlines)
        tencentSecretKey = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        tencentRegion = region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "ap-guangzhou" : region.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isRecording {
            status = "点这里开始说话"
        }
        print("ASR: engine \(useTencent ? "Tencent one-sentence" : "Apple Speech")")
    }

    func start() {
        guard !started else { return }
        started = true
        print("ASR: start")
        requestMicrophone()
    }

    private func requestMicrophone() {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            authorized = true
            status = "点这里开始说话"
            if pendingStart { beginRecording() }
        case .denied:
            authorized = false
            status = "麦克风未授权"
        default:
            session.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.authorized = granted
                    print("ASR: mic granted \(granted)")
                    if granted {
                        self.status = "点这里开始说话"
                        if self.pendingStart { self.beginRecording() }
                    } else {
                        self.status = "麦克风未授权"
                    }
                }
            }
        }
    }

    func beginRecording() {
        guard !paused, !isTranscribing else { return }
        if isRecording {
            endRecording()
            return
        }

        if !authorized {
            pendingStart = true
            status = "正在等待麦克风权限…"
            requestMicrophone()
            return
        }

        if !useTencent && !speechAuthorized {
            pendingStart = true
            status = "正在准备语音识别…"
            SFSpeechRecognizer.requestAuthorization { [weak self] auth in
                DispatchQueue.main.async {
                    guard let self else { return }
                    print("ASR: speech auth \(auth.rawValue)")
                    guard auth == .authorized else {
                        self.pendingStart = false
                        self.status = "语音识别未授权"
                        return
                    }
                    self.speechAuthorized = true
                    if self.pendingStart {
                        self.pendingStart = false
                        self.startCapture()
                    }
                }
            }
            return
        }

        pendingStart = false
        startCapture()
    }

    private func startCapture() {
        guard !isRecording else { return }
        isRecording = true
        isListening = true
        isTranscribing = false
        transcript = ""
        capturePCM.removeAll()
        recordingStarted = Date()
        wantsRecording = true
        if useTencent {
            startTencentRecorder()
        } else {
            beginAppleRequest()
            status = "识别中，点一下发送"
            activateAndStart()
        }
    }

    func endRecording() {
        guard isRecording else { return }
        isRecording = false
        isListening = false
        wantsRecording = false
        retryWork?.cancel()
        retryWork = nil

        let duration = Date().timeIntervalSince(recordingStarted)
        guard duration >= 0.35 else {
            resetAppleRequest()
            stopEngineAndDeactivate()
            isTranscribing = false
            status = "说话时间太短"
            return
        }

        isTranscribing = true
        if useTencent {
            recorder?.stop()
            let wav = recorderURL.flatMap { try? Data(contentsOf: $0) } ?? Data()
            cleanupRecorder()
            stopEngineAndDeactivate()
            guard !wav.isEmpty else {
                status = "没有录到声音，点一下重试"
                return
            }
            print("ASR: Tencent upload wav=\(wav.count) bytes duration=\(String(format: "%.2f", duration))s")
            guard wav.count <= 3_000_000 else {
                status = "录音太长，请分句说"
                return
            }
            status = "识别中…"
            tencentClient.transcribe(wav: wav, config: tencentConfig) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case let .success(text):
                        self.deliver(text)
                    case let .failure(error):
                        print("ASR: Tencent error \(error.localizedDescription)")
                        self.isTranscribing = false
                        self.stopEngineAndDeactivate()
                        self.level = 0
                        self.status = "识别失败：\(error.localizedDescription)"
                    }
                }
            }
        } else {
            request?.endAudio()
            stopEngineAndDeactivate()
            status = "识别中…"
            scheduleFinalWatchdog()
        }
    }

    private func deliver(_ raw: String) {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        print("ASR: final \(cleaned)")
        finalWatchdog?.cancel()
        finalWatchdog = nil
        taskGeneration += 1
        task = nil
        request = nil
        capturePCM.removeAll()
        DispatchQueue.main.async {
            self.isRecording = false
            self.isListening = false
            self.isTranscribing = false
            self.level = 0
            self.status = "点这里开始说话"
            self.transcript = ""
            if cleaned.count >= 1 {
                self.onUtterance?(cleaned)
            }
        }
    }

    private func beginAppleRequest() {
        guard let recognizer, recognizer.isAvailable else {
            print("ASR: recognizer unavailable")
            status = "语音识别暂不可用"
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
        // Apple's server model is noticeably better than the on-device zh-CN
        // model for homophones and book-specific names.
        request.requiresOnDeviceRecognition = false
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
                guard generation == self.taskGeneration else { return }
                let nsError = error as NSError
                let noSpeech = (nsError.domain == "SFSpeechRecognizerErrorDomain" && nsError.code == 203)
                    || error.localizedDescription.localizedCaseInsensitiveContains("No speech detected")
                    || error.localizedDescription.contains("未检测到")
                self.resetAppleRequest(
                    generation: generation,
                    status: noSpeech ? "没听清，点一下重试" : "识别失败：\(error.localizedDescription)"
                )
            }
        }
    }

    private func deliverFinal(_ text: String, generation: Int) {
        guard generation == taskGeneration else { return }
        deliver(text)
    }

    private func resetAppleRequest(generation: Int? = nil, status: String? = nil) {
        if let generation, generation != taskGeneration { return }
        print("ASR: reset request")
        finalWatchdog?.cancel()
        finalWatchdog = nil
        taskGeneration += 1
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        capturePCM.removeAll()
        isRecording = false
        isListening = false
        isTranscribing = false
        level = 0
        DispatchQueue.main.async {
            self.status = status ?? "点这里开始说话"
        }
    }

    private func scheduleFinalWatchdog() {
        let generation = taskGeneration
        finalWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, generation == self.taskGeneration else { return }
            print("ASR: final watchdog \(self.transcript)")
            self.deliverFinal(self.transcript, generation: generation)
        }
        finalWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: watchdog)
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard authorized, wantsRecording, !paused else { return }
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

        if useTencent {
            appendPCM(buffer)
        } else {
            request?.append(buffer)
        }

        // One-sentence ASR accepts at most 60 seconds. Cut automatically so the
        // upload never exceeds the API limit.
        if Date().timeIntervalSince(recordingStarted) >= 59 {
            DispatchQueue.main.async { self.endRecording() }
        }
    }

    private func startTencentRecorder() {
        cleanupRecorder()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.defaultToSpeaker])
            try session.setActive(true)
            if session.currentRoute.inputs.first?.portType != .builtInMic,
               let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtIn)
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("asr-\(UUID().uuidString).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                throw NSError(domain: "ASR", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "录音启动失败"])
            }
            self.recorder = recorder
            self.recorderURL = url
            meterTimer?.invalidate()
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                let db = recorder.averagePower(forChannel: 0)
                let normalized = max(0, min(1, (db + 50) / 50))
                DispatchQueue.main.async { self.level = CGFloat(normalized) }
            }
            status = "录音中，点一下发送"
            print("ASR: recorder started \(url.lastPathComponent)")
        } catch {
            wantsRecording = false
            isRecording = false
            isListening = false
            status = "麦克风启动失败"
            print("ASR: recorder failed \(error)")
        }
    }

    private func cleanupRecorder() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        recorder = nil
        if let recorderURL {
            try? FileManager.default.removeItem(at: recorderURL)
        }
        recorderURL = nil
    }

    private func appendPCM(_ buffer: AVAudioPCMBuffer) {
        let inputFormat = buffer.format
        if converter == nil || converterInputFormat?.sampleRate != inputFormat.sampleRate
            || converterInputFormat?.channelCount != inputFormat.channelCount {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            converterInputFormat = inputFormat
        }
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status == .haveData,
              output.frameLength > 0,
              let samples = output.int16ChannelData?[0] else {
            if let conversionError {
                print("ASR: conversion error \(conversionError)")
            }
            return
        }
        capturePCM.append(Data(bytes: samples,
                               count: Int(output.frameLength) * MemoryLayout<Int16>.size))
    }

    private func activateAndStart() {
        guard wantsRecording, !paused else { return }
        retryWork?.cancel()
        retryWork = nil

        let session = AVAudioSession.sharedInstance()
        do {
            // Rebuild the graph on every attempt; after an interruption the old
            // tap/engine can be stale even if start() appears to succeed.
            stopEngine()
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.defaultToSpeaker])
            try session.setActive(true)
            if session.currentRoute.inputs.first?.portType != .builtInMic,
               let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtIn)
            }
            installTapIfNeeded()
            engine.prepare()
            try engine.start()
            retryDelay = 0.5
            suppressRouteChangesUntil = Date().addingTimeInterval(1.0)
            let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
            print("ASR: engine started, input \(inputs)")
            if isRecording {
                status = useTencent ? "录音中，点一下发送" : "识别中，点一下发送"
            }
        } catch {
            print("ASR: activate failed \(error)")
            status = "麦克风被占用，正在恢复…"
            scheduleRetry()
        }
    }

    private func scheduleRetry(after delay: TimeInterval? = nil) {
        guard wantsRecording, !paused else { return }
        retryWork?.cancel()
        let wait = delay ?? retryDelay
        retryDelay = min(retryDelay * 2, 5)
        let work = DispatchWorkItem { [weak self] in
            self?.activateAndStart()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func stopEngine() {
        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    private func stopEngineAndDeactivate() {
        stopEngine()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func installTapIfNeeded() {
        guard !tapInstalled else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            print("ASR: no input format")
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }
        tapInstalled = true
        print("ASR: tap installed")
    }

    private func installSessionObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            self?.handleRouteChange(note)
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            self?.handleMediaServicesReset()
        })
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            guard wantsRecording, !paused else { return }
            print("ASR: interrupted while recording")
            wantsRecording = false
            isRecording = false
            isListening = false
            pendingStart = false
            retryWork?.cancel()
            retryWork = nil
            cleanupRecorder()
            resetAppleRequest(status: "麦克风被占用，点一下重试")
            stopEngine()
            level = 0
            status = "麦克风被占用，点一下重试"
        case .ended:
            // Push-to-talk: do not automatically reopen the mic after a call or
            // another recorder. The next tap will start a fresh recording.
            print("ASR: interruption ended")
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard wantsRecording, !paused, !useTencent else { return }
        guard Date() >= suppressRouteChangesUntil else { return }
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        print("ASR: route change reason \(reason.rawValue)")
        // Rebuilding on category/configuration changes caused by our own
        // setCategory/setPreferredInput creates an endless restart loop and
        // chops the utterance into pieces. Only react to real device changes.
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable:
            scheduleRetry(after: 0.2)
        default:
            return
        }
    }

    private func handleMediaServicesReset() {
        guard wantsRecording, !paused, !useTencent else { return }
        print("ASR: media services reset")
        retryDelay = 0.5
        scheduleRetry(after: 0.2)
    }

    /// Called after TTS stops. It does not open the microphone; the user must
    /// tap the mic button to start a new utterance.
    func prepare() {
        paused = false
        wantsRecording = false
        isRecording = false
        isListening = false
        isTranscribing = false
        pendingStart = false
        retryWork?.cancel()
        retryWork = nil
        cleanupRecorder()
        resetAppleRequest()
        stopEngineAndDeactivate()
        level = 0
        status = "点这里开始说话"
    }

    func pause() {
        prepare()
    }

    func resume() {
        prepare()
    }

    func stop() {
        prepare()
    }
}
