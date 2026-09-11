import SwiftUI
import AppKit
import ColokCore

@MainActor
struct MenuView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if !state.status.privileged {
                warning("Colok needs a one-time sudoers rule before it can turn USB sharing on.",
                        action: "Copy install command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("sudo bash \(sourceRoot)/Scripts/install-sudoers.sh", forType: .string)
                }
            }

            lane("iPhone / iPad", status: state.status.ios, toggle: { state.toggleIOS() })
            lane("Android", status: state.status.android, toggle: nil)
            sharingLane

            if let err = state.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Colok").font(.headline)
            Text(state.status.uplink)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func lane(_ title: String, status: LaneStatus, toggle: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline).bold()
                Spacer()
                if let toggle, status.available {
                    Toggle("", isOn: Binding(get: { status.enabled }, set: { _ in toggle() }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(state.busy)
                }
            }
            Text(status.message)
                .font(.caption)
                .foregroundStyle(status.available ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(status.devices) { device in
                HStack(spacing: 8) {
                    Circle()
                        .fill(device.online ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name).font(.callout)
                        Text(device.detail).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if device.platform == .android {
                        if device.online {
                            Button("Stop") { state.toggle(device: device) }
                                .buttonStyle(.borderless)
                                .disabled(state.busy)
                        } else if device.detail == "connected" {
                            // Proxy first: it leaves the phone's own network alone.
                            Button("Proxy") { state.connect(device: device, mode: .proxy) }
                                .buttonStyle(.borderless)
                                .disabled(state.busy)
                            Button("Tunnel") { state.connect(device: device, mode: .tunnel) }
                                .buttonStyle(.borderless)
                                .disabled(state.busy)
                        }
                    }
                }
            }
        }
    }

    /// Internet Sharing is the only cable-free path: Ethernet in -> Wi-Fi out for a
    /// real hotspot, or Wi-Fi in -> Ethernet out to feed a travel router.
    private var sharingLane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Wireless (Internet Sharing)").font(.subheadline).bold()
                Spacer()
                if state.status.sharing.available {
                    Toggle("", isOn: Binding(get: { state.status.sharing.enabled },
                                             set: { _ in state.toggleSharing() }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(state.busy)
                }
            }
            Text(state.status.sharing.message)
                .font(.caption)
                .foregroundStyle(state.status.sharing.available ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(state.status.sharing.devices) { output in
                HStack(spacing: 8) {
                    Circle()
                        .fill(output.online ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(output.name).font(.callout)
                    Text(output.detail).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    private func warning(_ text: String, action: String, run: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Button(action, action: run).buttonStyle(.borderless)
        }
        .padding(8)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        HStack {
            Button("Connect all") { state.connectAll() }.disabled(state.busy)
            Button("Disconnect") { state.disconnectAll() }.disabled(state.busy)
            Spacer()
            Button("Quit") {
                Engine.shared.disconnectEverything()
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var sourceRoot: String {
        Bundle.main.bundlePath.replacingOccurrences(of: "/Colok.app", with: "")
    }
}
