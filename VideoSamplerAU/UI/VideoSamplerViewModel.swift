import AppKit
import AVFoundation
import Foundation

// Instances are created, mutated, and released only by the main-actor view
// model. The unchecked conformance lets AVPlayer's sendable completion
// closures carry the identity back into a MainActor task.
final class ActiveVideoPlayback: Identifiable, @unchecked Sendable {
    let id = UUID()
    let padID: UUID
    let padName: String
    let player: AVPlayer

    private let url: URL
    private let accessedSecurityScope: Bool
    private let clipEnd: Double
    private let clipDuration: Double
    private let loadDeadline: Date
    private var playbackDeadline: Date?
    var boundaryObserver: Any?

    init(pad: PadState, url: URL) {
        padID = pad.id
        padName = pad.name
        self.url = url
        clipEnd = pad.clipEnd
        clipDuration = max(0.05, pad.clipEnd - pad.clipStart)
        loadDeadline = Date().addingTimeInterval(max(3.0, clipDuration + 2.0))
        accessedSecurityScope = url.startAccessingSecurityScopedResource()
        player = AVPlayer(playerItem: AVPlayerItem(url: url))
        player.isMuted = true
        player.volume = 0
        player.actionAtItemEnd = .pause
    }

    func markStarted(at date: Date = Date()) {
        // Boundary callbacks can be skipped when several players start close
        // together, so keep an independent clip-duration deadline.
        playbackDeadline = date.addingTimeInterval(clipDuration + 0.75)
    }

    func shouldFinish(at date: Date) -> Bool {
        if player.currentItem?.status == .failed { return true }
        guard let playbackDeadline else {
            // Discard an item whose asynchronous seek never completes.
            return date >= loadDeadline
        }
        let seconds = player.currentTime().seconds
        if seconds.isFinite, seconds >= clipEnd - 0.02 { return true }
        return date >= playbackDeadline
    }

    func stop() {
        player.pause()
        if let boundaryObserver {
            player.removeTimeObserver(boundaryObserver)
            self.boundaryObserver = nil
        }
        player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil)
    }

    deinit {
        stop()
        if accessedSecurityScope {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

@MainActor
final class VideoSamplerViewModel: ObservableObject {
    @Published var pads: [PadState]
    @Published var selectedPadID: UUID
    @Published var learningPadID: UUID?
    @Published var padFlash: [UUID: Double] = [:]
    @Published var lastMIDIText = "Logic MIDI · Waiting for Note"
    @Published var errorMessage: String?
    @Published private(set) var activeVideos: [ActiveVideoPlayback] = []

    let player = AVPlayer()
    let audioUnit: VideoSamplerAudioUnit
    private var timer: Timer?
    private var previewBoundaryObserver: Any?
    private var securityScopedVideo: (url: URL, accessed: Bool)?
    private var visualActivityGeneration: UInt64

    init(audioUnit: VideoSamplerAudioUnit) {
        self.audioUnit = audioUnit
        visualActivityGeneration = audioUnit.visualActivityGeneration
        // The AVPlayer is visual-only. Audio is rendered exclusively by the
        // Audio Unit so Logic receives one sample-accurate signal path.
        player.isMuted = true
        player.volume = 0
        let restoredPads = audioUnit.pads.isEmpty ? PadState.defaults : audioUnit.pads
        let initialPads = PadState.migratingLegacyLayout(restoredPads)
        pads = initialPads
        selectedPadID = initialPads[0].id
        if initialPads != restoredPads {
            audioUnit.updatePads(initialPads)
            audioUnit.reloadAllClips()
        }
        audioUnit.onStateRestored = { [weak self] restored in
            self?.restore(PadState.migratingLegacyLayout(restored), original: restored)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMIDI() }
        }
    }

    deinit {
        timer?.invalidate()
        if let previewBoundaryObserver {
            player.removeTimeObserver(previewBoundaryObserver)
        }
        if let securityScopedVideo, securityScopedVideo.accessed {
            securityScopedVideo.url.stopAccessingSecurityScopedResource()
        }
    }

    var selectedPad: PadState? { pads.first(where: { $0.id == selectedPadID }) }

    private func restore(_ restored: [PadState], original: [PadState]) {
        guard !restored.isEmpty else { return }
        pads = restored
        if !restored.contains(where: { $0.id == selectedPadID }) {
            selectedPadID = restored[0].id
        }
        if restored != original {
            audioUnit.updatePads(restored)
            audioUnit.reloadAllClips()
        }
    }

    func chooseVideo(for id: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Video with an Audio Track"
        panel.prompt = "Choose Video"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .audiovisualContent]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Create the app-scoped bookmark synchronously while the Powerbox grant
        // from NSOpenPanel is still active. AUv3 runs out-of-process, so waiting
        // until after an async AVFoundation load can lose the temporary grant.
        let bookmark: Data
        do {
            bookmark = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            errorMessage = "Unable to save video access permission: \(error.localizedDescription)"
            return
        }

        Task {
            var stale = false
            let securedURL: URL
            do {
                securedURL = try URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
            } catch {
                errorMessage = "Unable to restore video access permission: \(error.localizedDescription)"
                return
            }

            let accessed = securedURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { securedURL.stopAccessingSecurityScopedResource() }
            }
            do {
                let asset = AVURLAsset(url: securedURL)
                let duration = try await asset.load(.duration).seconds
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                guard duration.isFinite, duration > 0, !tracks.isEmpty else {
                    errorMessage = "This file does not contain a readable audio track."
                    return
                }
                updatePad(id: id, reloadAudio: true) { pad in
                    pad.bookmarkData = bookmark
                    pad.fileName = securedURL.lastPathComponent
                    pad.duration = duration
                    pad.clipStart = 0
                    pad.clipEnd = min(2, duration)
                    pad.normalize()
                }
                previewSelected(autoplay: false)
            } catch {
                errorMessage = "Unable to read the video: \(error.localizedDescription)"
            }
        }
    }

    func removeVideo(from id: UUID) {
        guard let index = pads.firstIndex(where: { $0.id == id }) else { return }
        let oldNote = pads[index].midiNote
        pads[index].bookmarkData = nil
        pads[index].fileName = nil
        pads[index].clipStart = 0
        pads[index].clipEnd = 1
        pads[index].duration = 1
        audioUnit.updatePads(pads, changedPad: pads[index], clearedNote: oldNote)
        stopActiveVideo(for: id)
        player.pause()
    }

    func setStart(_ value: Double, id: UUID, commit: Bool) {
        updatePad(id: id, reloadAudio: commit) { pad in
            pad.clipStart = value
            pad.normalize()
        }
        if let pad = pads.first(where: { $0.id == id }) {
            previewFrame(for: pad, at: pad.clipStart)
        }
    }

    func setEnd(_ value: Double, id: UUID, commit: Bool) {
        updatePad(id: id, reloadAudio: commit) { pad in
            pad.clipEnd = value
            pad.normalize()
        }
        if let pad = pads.first(where: { $0.id == id }) {
            previewFrame(for: pad, at: pad.clipEnd)
        }
    }

    func setNote(_ note: Int, id: UUID) {
        guard let index = pads.firstIndex(where: { $0.id == id }) else { return }
        let oldNote = pads[index].midiNote
        pads[index].midiNote = min(127, max(0, note))
        audioUnit.updatePads(pads, changedPad: pads[index], clearedNote: oldNote)
    }

    func trigger(_ pad: PadState) {
        guard !audioUnit.isRenderingOffline else { return }
        selectedPadID = pad.id
        sendNote(note: pad.midiNote, velocity: 110)
    }

    func previewSelected(autoplay: Bool) {
        guard !audioUnit.isRenderingOffline else { return }
        guard let pad = selectedPad, let url = pad.resolvingURL() else { return }
        activateSecurityScope(for: url)
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.seek(to: CMTime(seconds: pad.clipStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if autoplay { player.play() }
    }

    func reset() {
        player.pause()
        stopAllActiveVideos()
        pads = PadState.defaults
        selectedPadID = pads[0].id
        audioUnit.updatePads(pads)
        audioUnit.reloadAllClips()
    }

    private func updatePad(id: UUID, reloadAudio: Bool, change: (inout PadState) -> Void) {
        guard let index = pads.firstIndex(where: { $0.id == id }) else { return }
        change(&pads[index])
        audioUnit.updatePads(pads, changedPad: reloadAudio ? pads[index] : nil)
    }

    private func sendNote(note: Int, velocity: UInt8) {
        let bytes = [UInt8(0x90), UInt8(note & 0x7F), velocity]
        bytes.withUnsafeBufferPointer { buffer in
            _ = audioUnit.scheduleMIDIEventBlock?(AUEventSampleTimeImmediate, 0, 3, buffer.baseAddress!)
        }
    }

    func pollMIDI() {
        let generation = audioUnit.visualActivityGeneration
        if generation != visualActivityGeneration {
            visualActivityGeneration = generation
            stopAllActiveVideos()
            player.pause()
            player.currentItem?.cancelPendingSeeks()
            player.replaceCurrentItem(with: nil)
            padFlash.removeAll()
        }
        guard !audioUnit.isRenderingOffline else {
            audioUnit.discardVisualTriggers()
            lastMIDIText = "Offline Bounce · Audio Only"
            return
        }
        if lastMIDIText == "Offline Bounce · Audio Only" {
            lastMIDIText = "Logic MIDI · Waiting for Note"
        }
        cleanupFinishedVideos()

        // A live producer can refill the ring while we consume it. Bound each
        // GUI pass, and show only the latest hit for each pad in that pass;
        // every audio hit still receives its own sample-accurate DSP voice.
        var latestHits: [(pad: PadState, note: Int, velocity: Int)] = []
        for _ in 0..<128 {
            guard let event = audioUnit.consumeTriggeredNote() else { break }
            if let learningPadID {
                setNote(event.note, id: learningPadID)
                self.learningPadID = nil
                lastMIDIText = "MIDI Learn · Note \(event.note)"
                continue
            }
            guard let pad = pads.first(where: { $0.midiNote == event.note }) else { continue }
            latestHits.removeAll { $0.pad.id == pad.id }
            latestHits.append((pad, event.note, event.velocity))
        }
        guard !audioUnit.isRenderingOffline,
              generation == audioUnit.visualActivityGeneration else { return }
        for hit in latestHits {
            let pad = hit.pad
            selectedPadID = pad.id
            playVideo(pad)
            flash(id: pad.id)
            lastMIDIText =
                "Note \(hit.note) · Velocity \(hit.velocity) · " +
                "\(activeVideos.count) Playing"
        }
    }

    private func playVideo(_ pad: PadState) {
        guard !audioUnit.isRenderingOffline else { return }
        let generation = audioUnit.visualActivityGeneration
        guard let url = pad.resolvingURL() else { return }
        stopActiveVideo(for: pad.id)

        if activeVideos.count >= 10, let oldest = activeVideos.first {
            oldest.stop()
            activeVideos.removeFirst()
        }

        let playback = ActiveVideoPlayback(pad: pad, url: url)
        activeVideos.append(playback)
        let end = CMTime(seconds: pad.clipEnd, preferredTimescale: 60_000)
        playback.boundaryObserver = playback.player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: end)],
            queue: .main
        ) { [weak self, weak playback] in
            guard let playback else { return }
            Task { @MainActor in
                self?.finishActiveVideo(id: playback.id)
            }
        }

        let start = CMTime(seconds: pad.clipStart, preferredTimescale: 60_000)
        playback.player.seek(
            to: start,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self, weak playback] ready in
            guard ready, let playback else { return }
            Task { @MainActor in
                guard let self,
                      !self.audioUnit.isRenderingOffline,
                      self.audioUnit.visualActivityGeneration == generation,
                      self.activeVideos.contains(where: { $0.id == playback.id }) else { return }
                playback.markStarted()
                playback.player.play()
            }
        }
    }

    private func cleanupFinishedVideos() {
        let now = Date()
        let finishedIDs = activeVideos
            .filter { $0.shouldFinish(at: now) }
            .map(\.id)
        finishedIDs.forEach { finishActiveVideo(id: $0) }
    }

    private func finishActiveVideo(id: UUID) {
        guard let index = activeVideos.firstIndex(where: { $0.id == id }) else {
            return
        }
        activeVideos[index].stop()
        activeVideos.remove(at: index)
        if activeVideos.isEmpty {
            lastMIDIText = "Logic MIDI · Waiting for Note"
            if !audioUnit.isRenderingOffline { previewSelected(autoplay: false) }
        } else {
            lastMIDIText = "\(activeVideos.count) Videos Playing"
        }
    }

    private func stopActiveVideo(for padID: UUID) {
        let stopping = activeVideos.filter { $0.padID == padID }
        stopping.forEach { $0.stop() }
        activeVideos.removeAll { $0.padID == padID }
    }

    private func stopAllActiveVideos() {
        activeVideos.forEach { $0.stop() }
        activeVideos.removeAll()
        lastMIDIText = "Logic MIDI · Waiting for Note"
    }

    private func previewFrame(for pad: PadState, at seconds: Double) {
        guard !audioUnit.isRenderingOffline else { return }
        guard pad.id == selectedPadID, let url = pad.resolvingURL() else { return }
        activateSecurityScope(for: url)
        player.pause()
        if let previewBoundaryObserver {
            player.removeTimeObserver(previewBoundaryObserver)
            self.previewBoundaryObserver = nil
        }
        let currentURL = (player.currentItem?.asset as? AVURLAsset)?.url
        if currentURL != url {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
        }
        let latestVisibleFrame = max(0, pad.duration - (1.0 / 600.0))
        let target = min(max(0, seconds), latestVisibleFrame)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func flash(id: UUID) {
        let token = Date().timeIntervalSinceReferenceDate
        padFlash[id] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard self?.padFlash[id] == token else { return }
            self?.padFlash[id] = nil
        }
    }

    private func activateSecurityScope(for url: URL) {
        if securityScopedVideo?.url == url { return }
        if let previous = securityScopedVideo, previous.accessed {
            previous.url.stopAccessingSecurityScopedResource()
        }
        securityScopedVideo = (url, url.startAccessingSecurityScopedResource())
    }
}
