import CoreAudioKit
import SwiftUI

private final class AudioUnitFactoryState: @unchecked Sendable {
    private let lock = NSLock()
    private var unit: VideoSamplerAudioUnit?

    func getOrCreate(_ description: AudioComponentDescription) throws -> VideoSamplerAudioUnit {
        lock.lock()
        defer { lock.unlock() }
        if let unit { return unit }
        let created = try VideoSamplerAudioUnit(componentDescription: description, options: [])
        unit = created
        return created
    }
}

@MainActor
public final class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    private let fullInterfaceSize = NSSize(width: 1060, height: 740)
    private var audioUnit: VideoSamplerAudioUnit?
    private var hostingController: NSHostingController<VideoSamplerMainView>?
    private nonisolated let factoryState = AudioUnitFactoryState()
    private weak var configuredAudioUnit: VideoSamplerAudioUnit?

    public override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: fullInterfaceSize))
        preferredContentSize = fullInterfaceSize
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = fullInterfaceSize
        view.setFrameSize(fullInterfaceSize)
        if let audioUnit { configureView(for: audioUnit) }
    }

    nonisolated public func createAudioUnit(
        with componentDescription: AudioComponentDescription
    ) throws -> AUAudioUnit {
        // Hosts may create a separate unit for offline Bounce. DSP creation
        // must not synchronously wait for the UI (or sync onto the main queue
        // when the factory itself is already running there).
        let unit = try factoryState.getOrCreate(componentDescription)
        DispatchQueue.main.async { [weak self] in
            self?.audioUnit = unit
            self?.configureView(for: unit)
        }
        return unit
    }

    private func configureView(for audioUnit: VideoSamplerAudioUnit) {
        // A headless Bounce instance does not need a view. If the host asks
        // for one later, viewDidLoad will attach it using the existing unit.
        guard isViewLoaded else { return }
        // Closing/reopening or re-requesting this editor must not construct a
        // fresh empty sampler or replace the model of an already loaded unit.
        if configuredAudioUnit === audioUnit, hostingController != nil { return }
        if let hostingController {
            hostingController.view.removeFromSuperview()
            hostingController.removeFromParent()
        }
        let model = VideoSamplerViewModel(audioUnit: audioUnit)
        let host = NSHostingController(rootView: VideoSamplerMainView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostingController = host
        configuredAudioUnit = audioUnit
        preferredContentSize = fullInterfaceSize
        view.setFrameSize(fullInterfaceSize)
    }
}
