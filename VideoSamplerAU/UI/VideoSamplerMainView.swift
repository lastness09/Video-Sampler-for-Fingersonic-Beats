import AppKit
import AVFoundation
import AVKit
import SwiftUI

private struct SamplerPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

private enum Theme {
    static let background = Color(red: 0.05, green: 0.06, blue: 0.08)
    static let panel = Color(red: 0.085, green: 0.10, blue: 0.13)
    static let line = Color.white.opacity(0.09)
    static let muted = Color.white.opacity(0.55)
    static let accent = Color(red: 0.34, green: 0.92, blue: 0.76)
    static let loaded = Color(red: 0.38, green: 0.91, blue: 0.49)
    static let colors: [Color] = [
        .teal, .cyan, .mint, .orange, .purple, .red, .indigo, .blue,
        .pink, .yellow, .green, .orange, .red, .cyan, .purple, .mint
    ]
}

private enum DevicePadShape {
    case round
    case openHat
    case kick
}

private struct DevicePadPosition {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let shape: DevicePadShape
}

private struct OpenHatPadShape: Shape {
    func path(in rect: CGRect) -> Path {
        // The physical pad is a circle with a second circle cut out of its
        // lower-right side. Calculate both intersections and draw the two
        // exact circular arcs instead of approximating them with hand-tuned
        // Bezier control points.
        let outerCenter = CGPoint(x: 0.50, y: 0.50)
        let outerRadius: CGFloat = 0.48
        let biteCenter = CGPoint(x: 1.10, y: 1.25)
        let biteRadius: CGFloat = 0.79

        let dx = biteCenter.x - outerCenter.x
        let dy = biteCenter.y - outerCenter.y
        let centerDistance = hypot(dx, dy)
        let alongCenters = (
            outerRadius * outerRadius - biteRadius * biteRadius + centerDistance * centerDistance
        ) / (2 * centerDistance)
        let perpendicular = sqrt(max(0, outerRadius * outerRadius - alongCenters * alongCenters))
        let base = CGPoint(
            x: outerCenter.x + alongCenters * dx / centerDistance,
            y: outerCenter.y + alongCenters * dy / centerDistance
        )
        let offset = CGPoint(
            x: -dy * perpendicular / centerDistance,
            y: dx * perpendicular / centerDistance
        )
        let intersections = [
            CGPoint(x: base.x + offset.x, y: base.y + offset.y),
            CGPoint(x: base.x - offset.x, y: base.y - offset.y)
        ]
        let lower = intersections.max(by: { $0.y < $1.y })!
        let right = intersections.max(by: { $0.x < $1.x })!

        func mapped(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: rect.minX + point.x * rect.width,
                y: rect.minY + point.y * rect.height
            )
        }

        func circlePoint(center: CGPoint, radius: CGFloat, angle: CGFloat) -> CGPoint {
            CGPoint(
                x: center.x + radius * cos(angle),
                y: center.y + radius * sin(angle)
            )
        }

        var path = Path()
        let outerStart = atan2(lower.y - outerCenter.y, lower.x - outerCenter.x)
        var outerEnd = atan2(right.y - outerCenter.y, right.x - outerCenter.x)
        while outerEnd <= outerStart { outerEnd += 2 * .pi }
        path.move(to: mapped(lower))
        for step in 1...72 {
            let progress = CGFloat(step) / 72
            let angle = outerStart + (outerEnd - outerStart) * progress
            path.addLine(to: mapped(circlePoint(center: outerCenter, radius: outerRadius, angle: angle)))
        }

        let biteStart = atan2(right.y - biteCenter.y, right.x - biteCenter.x)
        var biteEnd = atan2(lower.y - biteCenter.y, lower.x - biteCenter.x)
        while biteEnd >= biteStart { biteEnd -= 2 * .pi }
        for step in 1...40 {
            let progress = CGFloat(step) / 40
            let angle = biteStart + (biteEnd - biteStart) * progress
            path.addLine(to: mapped(circlePoint(center: biteCenter, radius: biteRadius, angle: angle)))
        }
        path.closeSubpath()
        return path
    }
}

private struct KickPadShape: Shape {
    func path(in rect: CGRect) -> Path {
        // Geometry measured in the original 1285 x 586 hardware image.
        // The top is a circular arc. Each corner is a circle tangent to
        // that arc and/or a straight side; all joins share the same tangent.
        let referenceRect = CGRect(x: 533.6605, y: 352.4134, width: 217.679, height: 130.2092)
        let topCenter = CGPoint(x: 642.62, y: 566.39)
        let topRadius: CGFloat = 211.14
        let sideSlope: CGFloat = 0.17305
        let rightIntercept: CGFloat = 667.82
        let bottomY: CGFloat = 480.50
        let shoulderRadius: CGFloat = 10
        let bottomRadius: CGFloat = 16
        let normalLength = hypot(1, sideSlope)
        let rightNormal = CGVector(dx: 1 / normalLength, dy: -sideSlope / normalLength)
        let leftNormal = CGVector(dx: -1 / normalLength, dy: -sideSlope / normalLength)
        let rightOffset = rightIntercept / normalLength
        let leftOffset = (rightIntercept - 2 * topCenter.x) / normalLength

        func offset(_ center: CGPoint, by radius: CGFloat, along normal: CGVector) -> CGPoint {
            CGPoint(x: center.x + radius * normal.dx, y: center.y + radius * normal.dy)
        }

        func shoulder(normal: CGVector, lineOffset: CGFloat) -> (center: CGPoint, top: CGPoint, side: CGPoint) {
            // The fillet center lies on the inset side line and on a circle
            // of radius R-r, making the two circles internally tangent.
            let insetRadius = topRadius - shoulderRadius
            let distance = lineOffset - shoulderRadius -
                (normal.dx * topCenter.x + normal.dy * topCenter.y)
            let projection = offset(topCenter, by: distance, along: normal)
            let alongLine = sqrt(max(0, insetRadius * insetRadius - distance * distance))
            let tangent = CGVector(dx: -normal.dy, dy: normal.dx)
            let first = offset(projection, by: alongLine, along: tangent)
            let second = offset(projection, by: -alongLine, along: tangent)
            let center = first.y < second.y ? first : second
            let top = CGPoint(
                x: topCenter.x + (center.x - topCenter.x) * topRadius / insetRadius,
                y: topCenter.y + (center.y - topCenter.y) * topRadius / insetRadius
            )
            return (center, top, offset(center, by: shoulderRadius, along: normal))
        }

        func lowerCorner(normal: CGVector, lineOffset: CGFloat) -> (center: CGPoint, side: CGPoint, bottom: CGPoint) {
            let centerY = bottomY - bottomRadius
            let center = CGPoint(
                x: (lineOffset - bottomRadius - normal.dy * centerY) / normal.dx,
                y: centerY
            )
            return (
                center,
                offset(center, by: bottomRadius, along: normal),
                CGPoint(x: center.x, y: bottomY)
            )
        }

        let upperLeft = shoulder(normal: leftNormal, lineOffset: leftOffset)
        let upperRight = shoulder(normal: rightNormal, lineOffset: rightOffset)
        let lowerLeft = lowerCorner(normal: leftNormal, lineOffset: leftOffset)
        let lowerRight = lowerCorner(normal: rightNormal, lineOffset: rightOffset)
        let outline = CGMutablePath()

        func addArc(center: CGPoint, radius: CGFloat, from start: CGPoint, to end: CGPoint) {
            let startAngle = atan2(start.y - center.y, start.x - center.x)
            var endAngle = atan2(end.y - center.y, end.x - center.x)
            while endAngle <= startAngle { endAngle += 2 * .pi }
            outline.addArc(
                center: center, radius: radius,
                startAngle: startAngle, endAngle: endAngle, clockwise: false
            )
        }

        outline.move(to: upperLeft.top)
        addArc(center: topCenter, radius: topRadius, from: upperLeft.top, to: upperRight.top)
        addArc(center: upperRight.center, radius: shoulderRadius, from: upperRight.top, to: upperRight.side)
        outline.addLine(to: lowerRight.side)
        addArc(center: lowerRight.center, radius: bottomRadius, from: lowerRight.side, to: lowerRight.bottom)
        outline.addLine(to: lowerLeft.bottom)
        addArc(center: lowerLeft.center, radius: bottomRadius, from: lowerLeft.bottom, to: lowerLeft.side)
        outline.addLine(to: upperLeft.side)
        addArc(center: upperLeft.center, radius: shoulderRadius, from: upperLeft.side, to: upperLeft.top)
        outline.closeSubpath()

        let scaleX = rect.width / referenceRect.width
        let scaleY = rect.height / referenceRect.height
        return Path(outline).applying(CGAffineTransform(
            a: scaleX, b: 0, c: 0, d: scaleY,
            tx: rect.minX - referenceRect.minX * scaleX,
            ty: rect.minY - referenceRect.minY * scaleY
        ))
    }
}

struct VideoSamplerMainView: View {
    @StateObject var model: VideoSamplerViewModel

    // Copied from the physical-pad map in Sampler_for_FingersonicBeats.
    private let devicePositions = [
        DevicePadPosition(x: 14.09, y: 49.49, width: 11.19, height: 23.11, shape: .openHat),
        DevicePadPosition(x: 27.43, y: 39.33, width: 12.61, height: 27.65, shape: .round),
        DevicePadPosition(x: 20.23, y: 63.91, width: 10.55, height: 22.87, shape: .round),
        DevicePadPosition(x: 33.85, y: 68.43, width: 11.48, height: 25.09, shape: .round),
        DevicePadPosition(x: 43.58, y: 48.55, width: 9.36, height: 20.48, shape: .round),
        DevicePadPosition(x: 50.00, y: 71.25, width: 16.94, height: 22.22, shape: .kick),
        DevicePadPosition(x: 56.50, y: 48.55, width: 9.36, height: 20.48, shape: .round),
        DevicePadPosition(x: 72.18, y: 36.69, width: 13.82, height: 30.20, shape: .round),
        DevicePadPosition(x: 67.35, y: 69.45, width: 12.57, height: 27.47, shape: .round),
        DevicePadPosition(x: 85.33, y: 58.60, width: 10.54, height: 23.04, shape: .round)
    ]

    private static let hardwareImage: NSImage? = {
        let bundle = Bundle(for: AudioUnitViewController.self)
        guard let url = bundle.url(forResource: "FingersonicBeatsPads", withExtension: "jpg") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 760 {
                wideLayout(width: geometry.size.width)
            } else {
                compactLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .alert("Video Sampler", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func wideLayout(width: CGFloat) -> some View {
        let inspectorWidth = min(340, max(310, width * 0.31))
        return HStack(spacing: 0) {
            mainContent
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(Theme.line)

            inspectorContent
                .padding(12)
                .frame(width: inspectorWidth)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var compactLayout: some View {
        ScrollView {
            VStack(spacing: 0) {
                mainContent.padding(10)
                Divider().overlay(Theme.line)
                inspectorContent.padding(10)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var mainContent: some View {
        VStack(spacing: 8) {
            player
            playerToolbar
            hardwarePanel
                .padding(.top, 4)
        }
    }

    private var playerToolbar: some View {
        HStack(spacing: 8) {
            if let pad = model.selectedPad {
                VStack(alignment: .leading, spacing: 1) {
                    Text(pad.name)
                        .font(.system(size: 10, weight: .black, design: .rounded))
                    Text(pad.fileName ?? "No video loaded")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button {
                    model.chooseVideo(for: pad.id)
                } label: {
                    Label(
                        pad.fileName == nil ? "Choose Video" : "Replace Video",
                        systemImage: "folder"
                    )
                    .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    model.trigger(pad)
                } label: {
                    Label("Preview", systemImage: "play.fill")
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Theme.accent)
                .foregroundStyle(.black)
                .disabled(pad.bookmarkData == nil)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(Theme.line) }
    }

    private var player: some View {
        ZStack {
            Color.black
            if model.activeVideos.isEmpty {
                SamplerPlayerView(player: model.player)
                    .allowsHitTesting(false)
            } else {
                compositeVideoGrid
            }
            if model.activeVideos.isEmpty && model.selectedPad?.bookmarkData == nil {
                VStack(spacing: 8) {
                    Image(systemName: "film.stack").font(.system(size: 28, weight: .light))
                    Text("Choose a video with an audio track for this pad")
                        .font(.system(size: 12, weight: .medium))
                    Text("Tip: click any empty pad below to load a video")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(Color.white.opacity(0.38))
            }
            VStack {
                HStack(spacing: 8) {
                    Text(
                        model.activeVideos.isEmpty
                            ? "VIDEO SAMPLER · AU INSTRUMENT"
                            : "LIVE MULTIVIEW · \(model.activeVideos.count) CLIPS"
                    )
                        .lineLimit(1).minimumScaleFactor(0.65)
                    Spacer(minLength: 6)
                    Text(model.lastMIDIText)
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1).minimumScaleFactor(0.65)
                }
                .font(.system(size: 10, weight: .black, design: .rounded))
                .tracking(0.7)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.62))
                Spacer()
            }
        }
        .aspectRatio(16 / 6.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Theme.line) }
    }

    private var compositeVideoGrid: some View {
        GeometryReader { proxy in
            let count = model.activeVideos.count
            let columns = videoGridColumns(for: count)
            let rows = max(1, Int(ceil(Double(count) / Double(columns))))
            let spacing: CGFloat = 2
            let cellWidth =
                (proxy.size.width - CGFloat(columns - 1) * spacing) /
                CGFloat(columns)
            let cellHeight =
                (proxy.size.height - CGFloat(rows - 1) * spacing) /
                CGFloat(rows)

            ForEach(Array(model.activeVideos.enumerated()), id: \.element.id) { index, playback in
                let column = index % columns
                let row = index / columns
                videoTile(playback)
                    .frame(
                        width: max(0, cellWidth),
                        height: max(0, cellHeight)
                    )
                    .position(
                        x: CGFloat(column) * (cellWidth + spacing) + cellWidth / 2,
                        y: CGFloat(row) * (cellHeight + spacing) + cellHeight / 2
                    )
            }
        }
        .clipped()
    }

    private func videoTile(_ playback: ActiveVideoPlayback) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            SamplerPlayerView(player: playback.player)
                .allowsHitTesting(false)
            Text(playback.padName)
                .font(.system(size: 8, weight: .black, design: .rounded))
                .tracking(0.5)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.68))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(5)
        }
        .clipped()
        .overlay {
            Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
    }

    private func videoGridColumns(for count: Int) -> Int {
        switch count {
        case 0...1: return 1
        case 2...4: return 2
        case 5...9: return 3
        default: return 4
        }
    }

    private var hardwarePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("FINGERSONIC BEATS")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .tracking(0.8)
                    Text("Click a physical pad to select and trigger; numbers are MIDI notes")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(Theme.loaded).frame(width: 6, height: 6)
                    Text("VIDEO LOADED")
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.muted)
            }

            GeometryReader { proxy in
                ZStack {
                    if let image = Self.hardwareImage {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.45))
                        Text("Fingersonic Beats image not found").foregroundStyle(Theme.muted)
                    }

                    ForEach(Array(model.pads.prefix(10).enumerated()), id: \.element.id) { index, pad in
                        let position = devicePositions[index]
                        devicePadButton(pad, position: position)
                            .frame(
                                width: proxy.size.width * position.width / 100,
                                height: proxy.size.height * position.height / 100
                            )
                            .position(
                                x: proxy.size.width * position.x / 100,
                                y: proxy.size.height * position.y / 100
                            )
                    }
                }
            }
            .aspectRatio(1285 / 586, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(10)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Theme.line) }
    }

    private func devicePadButton(_ pad: PadState, position: DevicePadPosition) -> some View {
        let selected = model.selectedPadID == pad.id
        let active =
            model.padFlash[pad.id] != nil ||
            model.activeVideos.contains(where: { $0.padID == pad.id })
        let color = Theme.colors[pad.colorIndex % Theme.colors.count]
        return Button { activate(pad) } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    switch position.shape {
                    case .round:
                        Circle()
                            .fill(active ? color.opacity(0.70) : Color.black.opacity(selected ? 0.46 : 0.22))
                            .overlay { Circle().stroke(selected ? Theme.accent : .white.opacity(0.20), lineWidth: selected ? 3 : 1) }
                    case .openHat:
                        OpenHatPadShape()
                            .fill(active ? color.opacity(0.70) : Color.black.opacity(selected ? 0.46 : 0.22))
                            .overlay {
                                OpenHatPadShape()
                                    .stroke(selected ? Theme.accent : .white.opacity(0.20), lineWidth: selected ? 3 : 1)
                            }
                    case .kick:
                        KickPadShape()
                            .fill(active ? color.opacity(0.70) : Color.black.opacity(selected ? 0.46 : 0.22))
                            .overlay {
                                KickPadShape()
                                    .stroke(selected ? Theme.accent : .white.opacity(0.20), lineWidth: selected ? 3 : 1)
                            }
                    }
                }
                .shadow(color: selected ? Theme.accent.opacity(0.40) : .clear, radius: 7)

                VStack(spacing: 0) {
                    Text(shortName(pad.name))
                        .font(.system(size: 7, weight: .black, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Text("\(pad.midiNote)")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .shadow(color: .black, radius: 2)

                if pad.bookmarkData != nil {
                    Circle().fill(Theme.loaded).frame(width: 7, height: 7)
                        .overlay { Circle().stroke(.black.opacity(0.55), lineWidth: 1) }
                        .padding(3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(pad.name) · MIDI Note \(pad.midiNote)")
    }

    private var inspectorContent: some View {
        Group {
            if let pad = model.selectedPad {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("PAD EDITOR")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.muted)
                        HStack(alignment: .firstTextBaseline) {
                            Text(pad.name)
                                .font(.system(size: 21, weight: .black, design: .rounded))
                                .lineLimit(1).minimumScaleFactor(0.65)
                            Spacer()
                            Text("NOTE \(pad.midiNote)")
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                                .foregroundStyle(Theme.accent)
                        }
                    }

                    section("VIDEO + AUDIO") {
                        Text(pad.fileName ?? "No video loaded")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(pad.fileName == nil ? Theme.muted : .white)
                            .lineLimit(2)
                        Button { model.chooseVideo(for: pad.id) } label: {
                            Label(pad.fileName == nil ? "Choose Local Video" : "Replace Video", systemImage: "folder")
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .foregroundStyle(.black)
                        if pad.fileName != nil {
                            Button(role: .destructive) { model.removeVideo(from: pad.id) } label: {
                                Label("Remove Video", systemImage: "trash").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    section("CLIP") {
                        valueRow("Start", seconds: pad.clipStart)
                        Slider(
                            value: Binding(
                                get: { pad.clipStart },
                                set: { model.setStart($0, id: pad.id, commit: false) }
                            ),
                            in: 0...max(0.05, pad.duration - 0.05),
                            onEditingChanged: { editing in
                                if !editing, let fresh = model.selectedPad {
                                    model.setStart(fresh.clipStart, id: pad.id, commit: true)
                                }
                            }
                        )
                        valueRow("End", seconds: pad.clipEnd)
                        Slider(
                            value: Binding(
                                get: { pad.clipEnd },
                                set: { model.setEnd($0, id: pad.id, commit: false) }
                            ),
                            in: 0.05...max(0.05, pad.duration),
                            onEditingChanged: { editing in
                                if !editing, let fresh = model.selectedPad {
                                    model.setEnd(fresh.clipEnd, id: pad.id, commit: true)
                                }
                            }
                        )
                        HStack {
                            Text("Length \(format(pad.clipEnd - pad.clipStart))")
                            Spacer()
                            Text("Preview controls are below the video")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Theme.muted)
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                    .disabled(pad.bookmarkData == nil)

                    section("MIDI") {
                        HStack {
                            Text("Note")
                            Spacer()
                            Text("\(pad.midiNote)")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                            Stepper(
                                "",
                                value: Binding(
                                    get: { pad.midiNote },
                                    set: { model.setNote($0, id: pad.id) }
                                ),
                                in: 0...127
                            )
                            .labelsHidden()
                        }
                        Button {
                            model.learningPadID = model.learningPadID == pad.id ? nil : pad.id
                        } label: {
                            Label(
                                model.learningPadID == pad.id ? "Play a MIDI note…" : "MIDI Learn",
                                systemImage: "scope"
                            )
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(model.learningPadID == pad.id ? .orange : Theme.accent)
                    }

                    section("OUTPUT") {
                        HStack(spacing: 7) {
                            Image(systemName: "speaker.wave.2")
                            Slider(value: gainBinding, in: 0...1.5)
                            Text(String(format: "%.0f%%", gainBinding.wrappedValue * 100))
                                .font(.system(size: 9, design: .monospaced))
                                .frame(width: 35)
                        }
                    }

                    Button("Reset All Pads", role: .destructive) { model.reset() }
                        .font(.system(size: 11))

                    Text("Logic sends track MIDI to the plug-in. All triggered clips are mixed together and returned to the same track for recording or bouncing.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var gainBinding: Binding<Float> {
        Binding(
            get: { model.audioUnit.parameterTree?.parameter(withAddress: 0)?.value ?? 1 },
            set: { model.audioUnit.parameterTree?.parameter(withAddress: 0)?.value = $0 }
        )
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.muted)
            content()
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).stroke(Theme.line) }
    }

    private func valueRow(_ label: String, seconds: Double) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.muted)
            Spacer()
            Text(format(seconds)).font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .font(.system(size: 11))
    }

    private func shortName(_ name: String) -> String {
        switch name {
        case "OPEN HAT": return "OPEN"
        case "CLOSED HAT": return "CLOSED"
        case "FLOOR TOM": return "FLOOR"
        default: return name
        }
    }

    private func activate(_ pad: PadState) {
        model.selectedPadID = pad.id
        if pad.bookmarkData == nil {
            model.chooseVideo(for: pad.id)
        } else {
            model.trigger(pad)
        }
    }

    private func format(_ seconds: Double) -> String {
        let value = max(0, seconds.isFinite ? seconds : 0)
        return String(format: "%02d:%05.2f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
    }
}
