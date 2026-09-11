import SwiftUI
import AppKit
import ColokCore

@main
struct ColokBarApp: App {
    @StateObject private var state = AppState()

    init() {
        // A GUI app gets 256 descriptors by default, which a polling app that
        // shells out constantly can exhaust. Ask for the hard limit.
        var limit = rlimit()
        if getrlimit(RLIMIT_NOFILE, &limit) == 0 {
            limit.rlim_cur = min(rlim_t(8192), limit.rlim_max)
            setrlimit(RLIMIT_NOFILE, &limit)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(state: state)
                .onAppear { state.begin() }
        } label: {
            Image(systemName: state.iconName)
        }
        .menuBarExtraStyle(.window)
    }
}
