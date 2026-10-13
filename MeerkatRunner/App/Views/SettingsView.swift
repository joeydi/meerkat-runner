import AppKit
import Registry
import Supervisor
import ServiceManagement
import SwiftUI

/// Settings window (AGENTS.md §7, DESIGN.md §4.4).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            EnvironmentSettings()
                .tabItem { Label("Environment", systemImage: "terminal") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460)
        .padding(20)
    }
}

enum QuitBehaviour: String, CaseIterable, Identifiable {
    case stopManaged, leaveRunning, ask

    static let defaultsKey = "quitBehaviour"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stopManaged: "Stop managed servers"
        case .leaveRunning: "Leave running"
        case .ask: "Ask"
        }
    }
}

private struct GeneralSettings: View {
    @Environment(ServerRegistry.self) private var registry
    @AppStorage(QuitBehaviour.defaultsKey) private var quitBehaviour: QuitBehaviour = .stopManaged
    @AppStorage("showPortCount") private var showPortCount = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        @Bindable var registry = registry
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            if let launchError {
                Text(launchError).font(.caption).foregroundStyle(Tokens.Colors.errorText)
            }
            Picker("On quit", selection: $quitBehaviour) {
                ForEach(QuitBehaviour.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Hide system listeners", isOn: $registry.hideSystemListeners)
            Toggle("Hide app listeners", isOn: $registry.hideAppListeners)
                .help("Hides ports opened by desktop apps such as Dropbox or your editor. Database and container apps stay visible.")
            Toggle("Show running count in menu bar", isOn: $showPortCount)
            // TODO(v0.1): poll interval settings (§7).
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = "Couldn't update the login item."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct EnvironmentSettings: View {
    @Environment(ServerRegistry.self) private var registry
    @State private var capture: ShellEnv.Capture?
    @State private var isLoading = false

    var body: some View {
        Form {
            LabeledContent("Captured PATH") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(capture?.environment["PATH"].map { $0.replacingOccurrences(of: ":", with: "\n") } ?? "Not captured yet")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(capture == nil ? Color.secondary : Color.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let capture {
                        Text(capture.isComplete
                             ? "From your login shell, \(capture.capturedAt.formatted(date: .omitted, time: .shortened))"
                             : "Your shell didn't answer within 5 seconds, so a minimal PATH is in use.")
                            .font(Tokens.Font.meta)
                            .foregroundStyle(capture.isComplete ? Color.secondary : Tokens.Colors.warningText)
                    }
                }
            }
            Button(isLoading ? "Reloading…" : "Reload Shell Environment") {
                isLoading = true
                Task {
                    capture = await registry.reloadShellEnvironment()
                    isLoading = false
                }
            }
            .disabled(isLoading)
        }
        .task {
            if capture == nil { capture = await registry.shellEnvironment() }
        }
    }
}

private struct AboutSettings: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("Meerkat Runner").font(Tokens.Font.title)
            Text(version).font(Tokens.Font.meta).foregroundStyle(.secondary)
            if let url = MeerkatLinks.waitlist {
                Link("Made by Meerkat", destination: url)
            } else {
                Text("Made by Meerkat").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
