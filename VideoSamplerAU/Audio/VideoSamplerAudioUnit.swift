import AVFoundation
import AudioToolbox
import Foundation

public final class VideoSamplerAudioUnit: AUAudioUnit, @unchecked Sendable {
    private let kernel = VideoSamplerDSPBridge()
    private var outputBus: AUAudioUnitBus!
    private var outputBusArray: AUAudioUnitBusArray!
    private let stateQueue = DispatchQueue(label: "com.fingersonic.video-sampler.state")
    private let clipLoadGroup = DispatchGroup()
    private var padLoadGenerations: [UUID: UInt64] = [:]
    private var nextLoadGeneration: UInt64 = 0
    private var clipLoadErrors: [UUID: String] = [:]

    private var storedPads: [PadState] = PadState.defaults
    private var configurationRevision: AUValue = 0
    var pads: [PadState] { stateQueue.sync { storedPads } }
    var onStateRestored: (([PadState]) -> Void)?

    @objc override public init(
        componentDescription: AudioComponentDescription,
        options: AudioComponentInstantiationOptions = []
    ) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        try super.init(componentDescription: componentDescription, options: options)
        outputBus = try AUAudioUnitBus(format: format)
        outputBus.maximumChannelCount = 2
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        setupParameterTree()
    }

    public override var outputBusses: AUAudioUnitBusArray { outputBusArray }
    public override var audioUnitMIDIProtocol: MIDIProtocolID { kernel.midiProtocol }
    public override var canProcessInPlace: Bool { false }

    public override var isRenderingOffline: Bool {
        get { kernel.isRenderingOffline }
        set {
            kernel.isRenderingOffline = newValue
            super.isRenderingOffline = newValue
        }
    }

    var visualActivityGeneration: UInt64 { kernel.visualActivityGeneration }

    func discardVisualTriggers() { kernel.discardTriggerEvents() }

    public override var maximumFramesToRender: AUAudioFrameCount {
        get { kernel.maximumFramesToRender }
        set { kernel.maximumFramesToRender = newValue }
    }

    public override var shouldBypassEffect: Bool {
        get { kernel.isBypassed }
        set { kernel.isBypassed = newValue }
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        kernel.renderBlock
    }

    public override func allocateRenderResources() throws {
        // A host can restore a new instance immediately before offline Bounce.
        // Wait here, never inside the render block, so its very first MIDI note
        // has decoded PCM ready. Decoders do not need the main queue.
        if isRenderingOffline {
            guard clipLoadGroup.wait(timeout: .now() + 15) == .success else {
                throw audioLoadError("Audio is still loading. Please wait before bouncing.")
            }
            if let failure = stateQueue.sync(execute: { clipLoadErrors.values.first }) {
                throw audioLoadError(failure)
            }
        }
        let format = outputBus.format
        kernel.setChannelCount(format.channelCount, maximumFrames: maximumFramesToRender)
        kernel.initialize(withChannelCount: Int32(format.channelCount), sampleRate: format.sampleRate)
        try super.allocateRenderResources()
        // Clips retain their native sample rate and are resampled by the DSP.
        // Reallocating for Bounce must not clear/redecode the sample bank.
    }

    public override func deallocateRenderResources() {
        kernel.deInitialize()
        super.deallocateRenderResources()
    }

    public override func reset() {
        kernel.reset()
        super.reset()
    }

    public override var fullState: [String: Any]? {
        get {
            var state = super.fullState ?? [:]
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(pads) {
                state[VideoSamplerStateKeys.pads] = data
            }
            state[VideoSamplerStateKeys.gain] = kernel.gain
            return state
        }
        set {
            super.fullState = newValue
            // Preserve the superclass's reserved "data" (parameter payload).
            // Pad JSON uses its own stable key and contains the file bookmarks.
            if let data = newValue?[VideoSamplerStateKeys.pads] as? Data,
               let restored = try? JSONDecoder().decode([PadState].self, from: data),
               !restored.isEmpty {
                let normalized = PadState.migratingLegacyLayout(restored).map { pad in
                    var pad = pad
                    pad.normalize()
                    return pad
                }
                stateQueue.sync { storedPads = normalized }
                reloadAllClips()
            }
            if let gain = newValue?[VideoSamplerStateKeys.gain] as? NSNumber {
                kernel.gain = gain.floatValue
                parameterTree?.parameter(withAddress: 0)?.value = gain.floatValue
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onStateRestored?(self.pads)
            }
        }
    }

    // Logic's project-saving API is distinct from its user-preset API.
    // Both routes must carry the same per-instance bookmarks and clip ranges.
    public override var fullStateForDocument: [String: Any]? {
        get { fullState }
        set { fullState = newValue }
    }

    func updatePads(_ newPads: [PadState], changedPad: PadState? = nil, clearedNote: Int? = nil) {
        stateQueue.sync { storedPads = newPads }
        if let clearedNote { kernel.clearClip(forNote: Int32(clearedNote)) }
        if let changedPad {
            load(pad: changedPad)
        }
        signalConfigurationChanged()
    }

    private func signalConfigurationChanged() {
        // Video/trim/note edits are not gain changes. Give hosts a non-realtime
        // meta-parameter notification so they invalidate cached AU state and
        // mark the project as edited instead of saving an old empty bank.
        let revision = stateQueue.sync { () -> AUValue in
            configurationRevision = configurationRevision >= 16_777_215 ? 1 : configurationRevision + 1
            return configurationRevision
        }
        parameterTree?.parameter(withAddress: 1)?.value = revision
        willChangeValue(forKey: "fullState")
        willChangeValue(forKey: "fullStateForDocument")
        didChangeValue(forKey: "fullStateForDocument")
        didChangeValue(forKey: "fullState")
    }

    func reloadAllClips() {
        stateQueue.sync {
            // Invalidate old tasks without reusing generation numbers. An
            // obsolete completion must not overwrite restored clips.
            padLoadGenerations.removeAll()
            clipLoadErrors.removeAll()
            for note in 0...127 { kernel.clearClip(forNote: Int32(note)) }
        }
        for pad in pads where pad.bookmarkData != nil { load(pad: pad) }
    }

    func consumeTriggeredNote() -> (note: Int, velocity: Int)? {
        let packed = kernel.consumeNextTriggerEvent()
        guard packed != UInt32.max else { return nil }
        return (
            note: Int(packed & 0xFF),
            velocity: Int((packed >> 8) & 0xFF)
        )
    }

    private func load(pad: PadState) {
        let generation = stateQueue.sync { () -> UInt64 in
            nextLoadGeneration &+= 1
            padLoadGenerations[pad.id] = nextLoadGeneration
            clipLoadErrors[pad.id] = nil
            // Do not play the old range while the new range is decoding.
            kernel.clearClip(forNote: Int32(pad.midiNote))
            return nextLoadGeneration
        }
        guard let url = pad.resolvingURL() else {
            if pad.bookmarkData != nil {
                stateQueue.sync {
                    if padLoadGenerations[pad.id] == generation {
                        clipLoadErrors[pad.id] = "Unable to access \(pad.fileName ?? pad.name). Please choose the file again."
                    }
                }
            }
            return
        }
        let loadGroup = clipLoadGroup
        loadGroup.enter()
        Task.detached(priority: .userInitiated) { [weak self, loadGroup] in
            defer { loadGroup.leave() }
            do {
                let decoded = try await VideoClipLoader.decode(
                    url: url,
                    start: pad.clipStart,
                    end: pad.clipEnd
                )
                guard let self else { return }
                self.stateQueue.sync {
                    guard self.padLoadGenerations[pad.id] == generation else { return }
                    decoded.left.withUnsafeBufferPointer { left in
                        decoded.right.withUnsafeBufferPointer { right in
                            self.kernel.setClip(
                                note: Int32(pad.midiNote),
                                left: left.baseAddress!,
                                right: right.baseAddress,
                                frameCount: Int32(left.count),
                                sampleRate: decoded.sampleRate
                            )
                        }
                    }
                }
            } catch {
                guard let self else { return }
                self.stateQueue.sync {
                    guard self.padLoadGenerations[pad.id] == generation else { return }
                    self.clipLoadErrors[pad.id] = "\(pad.fileName ?? pad.name): \(error.localizedDescription)"
                    self.kernel.clearClip(forNote: Int32(pad.midiNote))
                }
            }
        }
    }

    private func audioLoadError(_ message: String) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(kAudioUnitErr_FailedInitialization),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func setupParameterTree() {
        let gain = AUParameterTree.createParameter(
            withIdentifier: "gain",
            name: "Output Gain",
            address: 0,
            min: 0,
            max: 1.5,
            unit: .linearGain,
            unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: nil,
            dependentParameters: nil
        )
        gain.value = 1
        let configuration = AUParameterTree.createParameter(
            withIdentifier: "configurationRevision", name: "Sample Configuration",
            address: 1, min: 0, max: 16_777_215, unit: .indexed, unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable, .flag_NonRealTime, .flag_IsGlobalMeta, .flag_ExpertMode],
            valueStrings: nil, dependentParameters: nil
        )
        let tree = AUParameterTree.createTree(withChildren: [gain, configuration])
        tree.implementorValueObserver = { [weak self] parameter, value in
            if parameter.address == 0 { self?.kernel.gain = value }
            if parameter.address == 1, let self {
                self.stateQueue.sync { self.configurationRevision = value }
            }
        }
        tree.implementorValueProvider = { [weak self] parameter in
            guard let self else { return 0 }
            if parameter.address == 0 { return self.kernel.gain }
            return self.stateQueue.sync { self.configurationRevision }
        }
        parameterTree = tree
    }
}
