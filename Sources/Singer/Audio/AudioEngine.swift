import AVFoundation

/// player → timePitch (speed) → 10-band EQ → balance mixer → main mixer (volume) → output.
/// All methods are called on the main thread.
final class AudioEngine {
    static let eqFrequencies: [Float] = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000]

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let eq = AVAudioUnitEQ(numberOfBands: 10)
    private let balanceMixer = AVAudioMixerNode()
    private let analyzer = SpectrumAnalyzer()

    private var file: AVAudioFile?
    private var connectedFormat: AVAudioFormat?
    private var startFrame: AVAudioFramePosition = 0
    private var needsSchedule = true
    private var pausedAt: Double?
    private var token = 0

    private(set) var isPlaying = false
    private(set) var duration: Double = 0

    /// Fired on the main thread when a track plays to its end.
    var onFinished: (() -> Void)?
    /// Fired on the main thread ~40×/s while audio is flowing.
    var onVisual: ((_ bars: [Float], _ wave: [Float]) -> Void)?

    init() {
        [player, timePitch, eq, balanceMixer].forEach(engine.attach)
        for (i, band) in eq.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = Self.eqFrequencies[i]
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = false
        }
        connect(format: nil)
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.handleConfigurationChange() }
    }

    // MARK: Transport

    var sampleRate: Double { file?.processingFormat.sampleRate ?? 44100 }

    var currentTime: Double {
        if !isPlaying { return pausedAt ?? Double(startFrame) / sampleRate }
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return Double(startFrame) / sampleRate }
        let t = Double(startFrame + max(0, playerTime.sampleTime)) / sampleRate
        return min(t, duration)
    }

    func load(url: URL) throws {
        stop()
        let f = try AVAudioFile(forReading: url)
        let fmt = f.processingFormat
        if connectedFormat.map({ !$0.isEqual(fmt) }) ?? true {
            engine.stop()
            connect(format: fmt)
        }
        file = f
        duration = Double(f.length) / fmt.sampleRate
        startFrame = 0
        pausedAt = 0
        needsSchedule = true
    }

    func play() {
        guard file != nil else { return }
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch { NSLog("Singer: engine start failed: \(error)"); return }
        }
        if needsSchedule { schedule(from: startFrame) }
        player.play()
        isPlaying = true
        pausedAt = nil
    }

    func pause() {
        guard isPlaying else { return }
        pausedAt = currentTime
        player.pause()
        isPlaying = false
    }

    func stop() {
        token += 1
        player.stop()
        isPlaying = false
        startFrame = 0
        pausedAt = 0
        needsSchedule = true
    }

    func seek(to seconds: Double) {
        guard let file else { return }
        let wasPlaying = isPlaying
        token += 1
        player.stop()
        isPlaying = false
        let frame = AVAudioFramePosition(max(0, min(seconds, duration)) * sampleRate)
        startFrame = min(frame, file.length)
        pausedAt = Double(startFrame) / sampleRate
        needsSchedule = true
        if wasPlaying { play() }
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let file else { return }
        token += 1
        let current = token
        let remaining = file.length - frame
        needsSchedule = false
        guard remaining > 0 else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.token == current else { return }
                self.isPlaying = false
                self.onFinished?()
            }
            return
        }
        player.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(remaining),
                               at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.token == current, self.isPlaying else { return }
                self.isPlaying = false
                self.needsSchedule = true
                self.startFrame = file.length
                self.onFinished?()
            }
        }
    }

    // MARK: Sound controls

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }
    var balance: Float {
        get { balanceMixer.pan }
        set { balanceMixer.pan = newValue }
    }
    var rate: Float {
        get { timePitch.rate }
        set { timePitch.rate = newValue }
    }
    var eqEnabled: Bool {
        get { !eq.bypass }
        set { eq.bypass = !newValue }
    }
    var preamp: Float {
        get { eq.globalGain }
        set { eq.globalGain = newValue }
    }
    func setGain(_ db: Float, band: Int) { eq.bands[band].gain = db }

    // MARK: Graph

    private func connect(format: AVAudioFormat?) {
        eq.removeTap(onBus: 0)
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(timePitch)
        engine.disconnectNodeOutput(eq)
        engine.disconnectNodeOutput(balanceMixer)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: eq, format: format)
        engine.connect(eq, to: balanceMixer, format: format)
        engine.connect(balanceMixer, to: engine.mainMixerNode, format: nil)
        connectedFormat = format
        // Tap before the volume stage so the visualizer doesn't shrink with the volume knob.
        // Core Audio often delivers ~100 ms buffers regardless of the size hint, so slice them
        // and release each slice at its own time to keep the visualizer smooth.
        eq.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            let slice = self.analyzer.size
            let sliceDuration = Double(slice) / buffer.format.sampleRate
            let count = max(1, Int(buffer.frameLength) / slice)
            for k in 0..<count {
                guard let r = self.analyzer.process(buffer, offset: k * slice) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * sliceDuration) {
                    self.onVisual?(r.bars, r.wave)
                }
            }
        }
    }

    /// Output device changed (headphones, AirPods…): the engine stops itself; rebuild and resume.
    private func handleConfigurationChange() {
        let wasPlaying = isPlaying
        let position = currentTime
        token += 1
        player.stop()
        isPlaying = false
        let fmt = connectedFormat
        connect(format: fmt)
        startFrame = AVAudioFramePosition(position * sampleRate)
        pausedAt = position
        needsSchedule = true
        if wasPlaying { play() }
    }
}
