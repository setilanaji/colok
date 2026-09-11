import Foundation
import Combine
import ColokCore

@MainActor
final class AppState: ObservableObject {
    @Published var status = ColokStatus()
    @Published var busy = false
    @Published var lastError: String?

    private var timer: Timer?
    /// A snapshot spawns a good number of subprocesses. Without this, a slow
    /// refresh lets the timer stack another on top and descriptors run out.
    private var refreshing = false

    func begin() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !busy, !refreshing else { return }
        refreshing = true
        Task.detached(priority: .utility) {
            let snap = Engine.shared.snapshot()
            await MainActor.run {
                self.status = snap
                self.refreshing = false
            }
        }
    }

    private func perform(_ work: @escaping () throws -> Void) {
        busy = true
        lastError = nil
        Task.detached(priority: .userInitiated) {
            let failure: String?
            do { try work(); failure = nil } catch { failure = error.localizedDescription }
            let snap = Engine.shared.snapshot()
            await MainActor.run {
                self.refreshing = false
                self.lastError = failure
                self.status = snap
                self.busy = false
            }
        }
    }

    func toggleIOS() {
        let target = !status.ios.enabled
        perform { try Engine.shared.setIOS(enabled: target) }
    }

    func toggle(device: TetheredDevice) {
        switch device.platform {
        case .ios:
            toggleIOS()
        case .android:
            perform { try Engine.shared.setAndroid(serial: device.id, enabled: false) }
        }
    }

    func connect(device: TetheredDevice, mode: AndroidMode) {
        perform { try Engine.shared.setAndroid(serial: device.id, enabled: true, mode: mode) }
    }

    func toggleSharing(output: NetworkService? = nil) {
        let target = !status.sharing.enabled
        perform { try Engine.shared.setSharing(enabled: target, output: output) }
    }

    var sharingOutputs: [NetworkService] { SharingLane.outputCandidates() }

    func connectAll() {
        perform {
            let problems = Engine.shared.connectEverything()
            if !problems.isEmpty {
                throw NSError(domain: "Colok", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: problems.joined(separator: "\n")])
            }
        }
    }

    func disconnectAll() {
        perform { Engine.shared.disconnectEverything() }
    }

    var iconName: String {
        if status.onlineCount > 0 { return "cable.connector" }
        if status.deviceCount > 0 { return "cable.connector.horizontal" }
        return "bolt.horizontal.circle"
    }
}
