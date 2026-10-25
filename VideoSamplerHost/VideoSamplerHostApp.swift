import SwiftUI

@main
struct VideoSamplerHostApp: App {
    var body: some Scene {
        WindowGroup {
            HostContentView()
                .frame(width: 620, height: 460)
                .fixedSize()
        }
        .windowResizability(.contentSize)
    }
}
