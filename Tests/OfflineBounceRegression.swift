import AppKit
import AVFoundation
import AudioToolbox
import Foundation
import Darwin

@main
enum OfflineBounceRegression {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw NSError(domain: "OfflineBounceRegression", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func fourCC(_ value: String) -> UInt32 {
        value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func render(_ unit: VideoSamplerAudioUnit, notes: [Int], time: Double = 0,
                       frames: UInt32 = 512) throws -> [Float] {
        let buffer = AVAudioPCMBuffer(pcmFormat: unit.outputBusses[0].format, frameCapacity: frames)!
        buffer.frameLength = frames
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = time
        timestamp.mFlags = .sampleTimeValid
        var flags: UInt32 = 0
        let events = UnsafeMutablePointer<AURenderEvent>.allocate(capacity: max(1, notes.count))
        events.initialize(repeating: AURenderEvent(), count: max(1, notes.count))
        defer {
            events.deinitialize(count: max(1, notes.count))
            events.deallocate()
        }
        for (index, note) in notes.enumerated() {
            events[index].MIDI.eventType = .MIDI
            events[index].MIDI.eventSampleTime = AUEventSampleTime(time)
            events[index].MIDI.length = 3
            events[index].MIDI.data = (0x90, UInt8(note), 100)
            events[index].head.next = index + 1 < notes.count ? events.advanced(by: index + 1) : nil
        }
        let status = unit.internalRenderBlock(
            &flags, &timestamp, frames, 0, buffer.mutableAudioBufferList,
            notes.isEmpty ? nil : UnsafePointer(events), nil
        )
        try require(status == noErr, "Render failed: \(status)")
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(frames)))
    }

    @MainActor
    static func main() async throws {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice, componentSubType: fourCC("fbts"),
            componentManufacturer: fourCC("FgSn"), componentFlags: 0, componentFlagsMask: 0
        )
        AUAudioUnit.registerSubclass(VideoSamplerAudioUnit.self, as: description,
                                    name: "Fingersonic: Offline Regression", version: 1)
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let savedURL = url.deletingLastPathComponent().appendingPathComponent("saved-session.plist")
        if CommandLine.arguments.contains("--restore") {
            let data = try Data(contentsOf: savedURL)
            let state = try PropertyListSerialization.propertyList(from: data, options: 0, format: nil) as! [String: Any]
            let expected = try JSONDecoder().decode([PadState].self, from: state[VideoSamplerStateKeys.pads] as! Data)
            let coldUnit = try VideoSamplerAudioUnit(componentDescription: description)
            coldUnit.fullStateForDocument = state
            try require(coldUnit.pads == expected, "New-process document restore lost pad configuration")
            coldUnit.isRenderingOffline = true
            try coldUnit.allocateRenderResources()
            let output = try render(coldUnit, notes: expected.map(\.midiNote))
            try require(output.contains { abs($0) > 0.01 }, "New-process restored bookmarks did not load audio")
            try require(abs(coldUnit.parameterTree!.parameter(withAddress: 0)!.value - 0.73) < 0.0001,
                        "Document restore lost output gain")
            let reopened = VideoSamplerViewModel(audioUnit: coldUnit)
            try require(reopened.pads == expected, "Reopened editor displayed empty pads")
            coldUnit.deallocateRenderResources()
            print("New-process project restore passed: bookmarks, filenames, trim, MIDI notes, gain, playable audio, reopened editor")
            return
        }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
        var pads = PadState.defaults
        for index in pads.indices {
            pads[index].bookmarkData = bookmark
            pads[index].fileName = url.lastPathComponent
            pads[index].duration = 0.5
            pads[index].clipStart = 0.05
            pads[index].clipEnd = 0.25
        }
        try require(pads[0].resolvingURL() != nil, "Fixture bookmark could not be resolved")
        let unit = try VideoSamplerAudioUnit(componentDescription: description)
        unit.maximumFramesToRender = 512
        unit.fullState = [VideoSamplerStateKeys.pads: try JSONEncoder().encode(pads)]
        unit.isRenderingOffline = true
        let started = Date()
        // Immediately allocate after restoration, before detached decoders finish.
        try unit.allocateRenderResources()
        let notes = pads.map(\.midiNote)
        let reference = try render(unit, notes: notes)
        try require(reference.contains { abs($0) > 0.01 }, "First offline buffer was silent")
        try require(unit.consumeTriggeredNote() == nil, "Offline render queued a video")
        unit.reset()
        let silence = try render(unit, notes: [])
        try require(silence.allSatisfy { $0 == 0 }, "Reset failed to clear playing voices")

        // Native PCM must survive resource allocation and output-rate changes.
        for rate in [44_100.0, 96_000.0, 48_000.0] {
            unit.deallocateRenderResources()
            try unit.outputBusses[0].setFormat(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!)
            try unit.allocateRenderResources()
            let output = try render(unit, notes: notes)
            try require(output.contains { abs($0) > 0.01 }, "Reallocation lost samples at \(rate) Hz")
            if rate == 48_000 {
                try require(output == reference, "Repeated Bounce changed PCM output")
            }
        }

        // Render a long project faster than wall clock, with no GUI consumer.
        unit.reset()
        for block in 0..<10_000 {
            let output = try render(unit, notes: notes, time: Double(block * 512))
            try require(output.allSatisfy(\.isFinite), "Non-finite output during accelerated Bounce")
        }
        try require(unit.consumeTriggeredNote() == nil, "Accelerated Bounce filled the UI queue")

        unit.reset()
        unit.isRenderingOffline = false
        let realtime = try render(unit, notes: notes)
        try require(realtime == reference, "Offline and realtime audio differ")
        let model = VideoSamplerViewModel(audioUnit: unit)
        model.pollMIDI()
        try require(model.activeVideos.count == 10, "Realtime ten-pad multiview did not resume")
        unit.isRenderingOffline = true
        model.pollMIDI()
        try require(model.activeVideos.isEmpty && model.padFlash.isEmpty,
                    "Offline transition did not stop videos and pad activity")
        try require(model.lastMIDIText == "Offline Bounce · Audio Only", "Offline UI status was not shown")
        unit.isRenderingOffline = false
        model.pollMIDI()
        _ = try render(unit, notes: [36])
        model.pollMIDI()
        try require(model.activeVideos.count == 1, "Realtime video did not resume after Bounce")
        // A short offline render can start and finish between timer callbacks.
        unit.isRenderingOffline = true
        _ = try render(unit, notes: notes)
        unit.isRenderingOffline = false
        model.pollMIDI()
        try require(model.activeVideos.isEmpty, "Fast Bounce left stale multiview tiles")

        // A removed clip must not be resurrected by a pending old decoder.
        unit.deallocateRenderResources()
        unit.fullState = [VideoSamplerStateKeys.pads: try JSONEncoder().encode(pads)]
        var removed = pads
        removed[0].bookmarkData = nil
        unit.updatePads(removed, changedPad: removed[0], clearedNote: removed[0].midiNote)
        unit.isRenderingOffline = true
        try unit.allocateRenderResources()
        let removedOutput = try render(unit, notes: [removed[0].midiNote])
        try require(removedOutput.allSatisfy { $0 == 0 }, "Obsolete decode resurrected a removed clip")
        unit.deallocateRenderResources()
        print("Offline Bounce regression passed: immediate restore, 10-pad polyphony, 3 sample rates, 100,000 hits, identical PCM, reset, UI transitions, decode cancellation (\(String(format: "%.2f", Date().timeIntervalSince(started)))s)")

        var savedPads = pads
        savedPads[0].midiNote = 47
        savedPads[0].clipStart = 0.07
        savedPads[0].clipEnd = 0.23
        let oldRevision = unit.parameterTree!.parameter(withAddress: 1)!.value
        unit.updatePads(savedPads, changedPad: savedPads[0])
        unit.parameterTree?.parameter(withAddress: 0)?.value = 0.73
        try require(unit.parameterTree!.parameter(withAddress: 1)!.value != oldRevision,
                    "Configuration edit did not notify the host")
        let state = unit.fullStateForDocument!
        try require(state[VideoSamplerStateKeys.pads] as? Data != nil, "Document omitted sample state")
        let stateData = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
        try stateData.write(to: savedURL, options: .atomic)
        let archived = try PropertyListSerialization.propertyList(from: stateData, options: 0, format: nil) as! [String: Any]
        let restoredUnit = try VideoSamplerAudioUnit(componentDescription: description)
        restoredUnit.fullStateForDocument = archived
        try require(restoredUnit.pads == savedPads, "Document state roundtrip changed pads")
        let reopened = VideoSamplerViewModel(audioUnit: restoredUnit)
        try require(reopened.pads == savedPads, "Editor recreation discarded restored pads")
        restoredUnit.fullState = archived
        try require(restoredUnit.pads == savedPads, "Legacy session compatibility broke")
        restoredUnit.fullState = [:] // Parameter-only host updates must not erase samples.
        try require(restoredUnit.pads == savedPads, "Partial host state erased loaded videos")
        let legacyUnit = try VideoSamplerAudioUnit(componentDescription: description)
        let legacyGain = AUParameterTree.createParameter(
            withIdentifier: "gain", name: "Output Gain", address: 0, min: 0, max: 1.5,
            unit: .linearGain, unitName: nil, flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: nil, dependentParameters: nil
        )
        legacyGain.value = 0.73
        legacyUnit.parameterTree = AUParameterTree.createTree(withChildren: [legacyGain])
        legacyUnit.fullState = [VideoSamplerStateKeys.pads: try JSONEncoder().encode(savedPads),
                                VideoSamplerStateKeys.gain: NSNumber(value: 0.73)]
        restoredUnit.fullState = legacyUnit.fullState
        try require(restoredUnit.pads == savedPads, "Older gain-only parameter layout failed to restore")
        print("Document configuration serialized and restored: \(stateData.count) bytes")

        // A real AVAudioEngine offline graph exercises the public host render
        // API and the AUv2 property bridge used by desktop DAWs, not just DSP.
        let node: AVAudioUnit = try await withCheckedThrowingContinuation { continuation in
            AVAudioUnit.instantiate(with: description, options: []) { node, error in
                if let node { continuation.resume(returning: node) }
                else { continuation.resume(throwing: error ?? NSError(domain: "OfflineBounceRegression", code: 2)) }
            }
        }
        node.auAudioUnit.fullStateForDocument = archived
        node.auAudioUnit.isRenderingOffline = true
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        try engine.start()
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        let waveURL = url.deletingLastPathComponent().appendingPathComponent("offline-bounce.wav")
        var fileSettings = format.settings
        fileSettings.removeValue(forKey: AVLinearPCMIsNonInterleaved)
        let wave = try AVAudioFile(forWriting: waveURL, settings: fileSettings)
        var audible = false
        for block in 0..<1000 {
            if block % 10 == 0 {
                for pad in savedPads {
                    let bytes: [UInt8] = [0x90, UInt8(pad.midiNote), 100]
                    bytes.withUnsafeBufferPointer {
                        node.auAudioUnit.scheduleMIDIEventBlock?(AUEventSampleTimeImmediate, 0, 3, $0.baseAddress!)
                    }
                }
            }
            let status = try engine.renderOffline(512, to: pcm)
            try require(status == .success, "AVAudioEngine offline render failed: \(status.rawValue)")
            if UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)).contains(where: { abs($0) > 0.01 }) {
                audible = true
            }
            try wave.write(from: pcm)
        }
        try require(audible, "Actual offline host export was silent")
        var bridgedState: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        let status = AudioUnitGetProperty(node.audioUnit, kAudioUnitProperty_ClassInfoFromDocument,
                                         kAudioUnitScope_Global, 0, &bridgedState, &size)
        try require(status == noErr, "DAW document-state bridge failed: \(status)")
        let bridged = bridgedState!.takeRetainedValue() as! [String: Any]
        fflush(stdout)
        let bridgedPads = try JSONDecoder().decode([PadState].self, from: bridged[VideoSamplerStateKeys.pads] as! Data)
        try require(bridgedPads == savedPads, "AUv2 DAW bridge lost pad configuration")
        engine.stop()
        engine.disableManualRenderingMode()
        print("AVAudioEngine offline export passed: 512,000 frames written, scheduled MIDI, ten-pad mixing, DAW document-state bridge")

        let factory = AudioUnitViewController()
        let first = try factory.createAudioUnit(with: description)
        (first as! VideoSamplerAudioUnit).fullStateForDocument = archived
        let again = try factory.createAudioUnit(with: description)
        try require(first === again && (again as! VideoSamplerAudioUnit).pads == savedPads,
                    "Editor factory recreated an empty sampler")
        let separate = try AudioUnitViewController().createAudioUnit(with: description)
        try require(first !== separate && (separate as! VideoSamplerAudioUnit).pads.allSatisfy { $0.bookmarkData == nil },
                    "Independent tracks shared sample configuration")
        print("Persistence tests passed: document/property-list roundtrip, partial/legacy state, editor factory reuse, independent tracks")
    }
}
