import AVFoundation

/// player → timePitch (speed) → 10-band EQ → bass boost → voice (EQ + compressor) → peak limiter → balance mixer
/// → main mixer (volume) → output.
/// All methods are called on the main thread.
///
/// Gapless: the next file is scheduled on the same player node right behind the current one when the
/// formats match, so there's no gap between tracks. `onAdvanced` fires when playback crosses into it.
final class AudioEngine {
    static let eqFrequencies: [Float] = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000]

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let eq = AVAudioUnitEQ(numberOfBands: 10)
    private let bass = AVAudioUnitEQ(numberOfBands: 2)
    private let voice = AVAudioUnitEQ(numberOfBands: 2)
    private let compressor = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    private let balanceMixer = AVAudioMixerNode()
    private let analyzer = SpectrumAnalyzer()

    private var file: AVAudioFile?
    /// Queued for gapless playback after `file`.
    private var nextFile: AVAudioFile?
    /// Items scheduled on the player, in play order, with their frame counts.
    private var pending: [(file: AVAudioFile, frames: AVAudioFramePosition)] = []
    private var connectedFormat: AVAudioFormat?
    private var startFrame: AVAudioFramePosition = 0
    /// Player sample time at which the current file's segment began (moves forward on gapless advance).
    private var sampleBase: AVAudioFramePosition = 0
    private var needsSchedule = true
    private var pausedAt: Double?
    private var token = 0

    private(set) var isPlaying = false
    private(set) var duration: Double = 0

    /// Fired on the main thread when the last scheduled track plays to its end.
    var onFinished: (() -> Void)?
    /// Fired on the main thread when playback moves into the gapless-queued file.
    var onAdvanced: (() -> Void)?
    /// Fired on the main thread ~40×/s while audio is flowing.
    var onVisual: ((_ bars: [Float], _ wave: [Float]) -> Void)?

    /// Switch the output device to each file's sample rate (macOS), so lossless isn't resampled.
    var matchOutputRate = true

    init() {
        [player, timePitch, eq, bass, voice, compressor, limiter, balanceMixer].forEach(engine.attach)
        for (i, band) in eq.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = Self.eqFrequencies[i]
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = false
        }
        // Bass boost: a low shelf, plus a subsonic high-pass so small speakers don't flap at 20 Hz.
        bass.bands[0].filterType = .lowShelf
        bass.bands[0].frequency = 100
        bass.bands[0].gain = 0
        bass.bands[0].bypass = false
        bass.bands[1].filterType = .highPass
        bass.bands[1].frequency = 25
        bass.bands[1].bypass = false
        bass.bypass = true
        // Voice: body around 250 Hz and presence around 2.8 kHz, where speech and vocals live.
        voice.bands[0].filterType = .parametric
        voice.bands[0].frequency = 250
        voice.bands[0].bandwidth = 1.2
        voice.bands[1].filterType = .parametric
        voice.bands[1].frequency = 2800
        voice.bands[1].bandwidth = 1.5
        voice.bands.forEach { $0.bypass = false }
        voice.bypass = true
        compressor.bypass = true
        connect(format: nil)
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.handleConfigurationChange() }
    }

    // MARK: Transport

    var sampleRate: Double { file?.processingFormat.sampleRate ?? 44100 }

    /// The rate the hardware is actually running at.
    var outputSampleRate: Double { engine.outputNode.outputFormat(forBus: 0).sampleRate }

    var currentTime: Double {
        if !isPlaying { return pausedAt ?? Double(startFrame) / sampleRate }
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return Double(startFrame) / sampleRate }
        let t = Double(startFrame + max(0, playerTime.sampleTime - sampleBase)) / sampleRate
        return min(t, duration)
    }

    func load(url: URL) throws {
        stop()
        let f = try AVAudioFile(forReading: url)
        let fmt = f.processingFormat
        let rateChanged = adaptOutputRate(to: fmt.sampleRate)
        if rateChanged || connectedFormat.map({ !$0.isEqual(fmt) }) ?? true {
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
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
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
        nextFile = nil
        pending = []
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

    /// Queue a file to follow the current one without a gap. Returns false when it can't be gapless
    /// (different sample rate / channel count, unreadable); the caller then loads it normally.
    @discardableResult
    func queueNext(url: URL) -> Bool {
        guard let file, let f = try? AVAudioFile(forReading: url),
              f.processingFormat.isEqual(file.processingFormat) else { return false }
        nextFile = f
        if !needsSchedule, pending.count == 1 { append(f, token: token) }
        return true
    }

    /// Forget the queued file. If it's already scheduled, re-schedule the current one from where it is.
    func dropNext() {
        nextFile = nil
        guard pending.count > 1 else { return }
        seek(to: currentTime)
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let file else { return }
        token += 1
        let current = token
        sampleBase = 0
        pending = []
        needsSchedule = false
        let remaining = file.length - frame
        if remaining > 0 {
            pending.append((file, remaining))
            player.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(remaining),
                                   at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async { self?.segmentEnded(token: current) }
            }
        } else {
            pending.append((file, 0))
            DispatchQueue.main.async { [weak self] in self?.segmentEnded(token: current) }
        }
        if let next = nextFile { append(next, token: current) }
    }

    private func append(_ f: AVAudioFile, token current: Int) {
        pending.append((f, f.length))
        player.scheduleSegment(f, startingFrame: 0, frameCount: AVAudioFrameCount(f.length),
                               at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.segmentEnded(token: current) }
        }
    }

    private func segmentEnded(token current: Int) {
        guard token == current, isPlaying, !pending.isEmpty else { return }
        let ended = pending.removeFirst()
        if let upcoming = pending.first {
            // Crossed into the gapless-queued file.
            sampleBase += ended.frames
            file = upcoming.file
            nextFile = nil
            startFrame = 0
            duration = Double(upcoming.file.length) / upcoming.file.processingFormat.sampleRate
            onAdvanced?()
        } else {
            isPlaying = false
            needsSchedule = true
            startFrame = file?.length ?? 0
            onFinished?()
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

    /// Bass boost in dB (0 = off).
    var bassBoost: Float {
        get { bass.bypass ? 0 : bass.bands[0].gain }
        set {
            bass.bands[0].gain = newValue
            bass.bypass = newValue <= 0
        }
    }

    /// Voice boost strength in dB at the presence peak (0 = off). Also compresses gently so quiet
    /// words come up, with matching make-up gain.
    var voiceBoost: Float = 0 {
        didSet {
            let on = voiceBoost > 0
            voice.bypass = !on
            compressor.bypass = !on
            voice.bands[0].gain = voiceBoost * 0.4
            voice.bands[1].gain = voiceBoost
            // AUDynamicsProcessor: 0 threshold, 1 headroom, 4 attack, 5 release, 6 overall (make-up) gain.
            let au = compressor.audioUnit
            AudioUnitSetParameter(au, 0, kAudioUnitScope_Global, 0, -18 - voiceBoost, 0)
            AudioUnitSetParameter(au, 1, kAudioUnitScope_Global, 0, 6, 0)
            AudioUnitSetParameter(au, 4, kAudioUnitScope_Global, 0, 0.005, 0)
            AudioUnitSetParameter(au, 5, kAudioUnitScope_Global, 0, 0.12, 0)
            AudioUnitSetParameter(au, 6, kAudioUnitScope_Global, 0, voiceBoost * 0.5, 0)
        }
    }

    /// Clipping protection. AUPeakLimiter is bit-transparent below 0 dBFS and only pulls down peaks
    /// that would clip, so boosts keep their level (no static attenuation, which sounded dull).
    var clipGuard: Bool {
        get { !limiter.bypass }
        set { limiter.bypass = !newValue }
    }

    // MARK: Graph

    private func connect(format: AVAudioFormat?) {
        bass.removeTap(onBus: 0)
        for node in [player, timePitch, eq, bass, voice, compressor, limiter, balanceMixer] as [AVAudioNode] {
            engine.disconnectNodeOutput(node)
        }
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: eq, format: format)
        engine.connect(eq, to: bass, format: format)
        engine.connect(bass, to: voice, format: format)
        engine.connect(voice, to: compressor, format: format)
        engine.connect(compressor, to: limiter, format: format)
        engine.connect(limiter, to: balanceMixer, format: format)
        engine.connect(balanceMixer, to: engine.mainMixerNode, format: nil)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        connectedFormat = format
        // Tap before the volume stage so the visualizer doesn't shrink with the volume knob.
        // Core Audio often delivers ~100 ms buffers regardless of the size hint, so slice them
        // and release each slice at its own time to keep the visualizer smooth.
        bass.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
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

    /// Returns true if the hardware rate was changed.
    private func adaptOutputRate(to rate: Double) -> Bool {
        guard matchOutputRate else { return false }
        #if os(macOS)
        return OutputDevice.match(rate)
        #else
        let session = AVAudioSession.sharedInstance()
        guard session.preferredSampleRate != rate else { return false }
        try? session.setPreferredSampleRate(rate)
        return true
        #endif
    }

    /// Output device changed (headphones, AirPods, sample-rate switch): the engine stops itself;
    /// rebuild and resume from the same spot.
    private func handleConfigurationChange() {
        let wasPlaying = isPlaying
        let position = currentTime
        token += 1
        player.stop()
        isPlaying = false
        connect(format: connectedFormat)
        startFrame = AVAudioFramePosition(position * sampleRate)
        pausedAt = position
        needsSchedule = true
        if wasPlaying { play() }
    }
}
