import AppKit
import Registry
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
    @AppStorage("quitBehaviour") private var quitBehaviour: QuitBehaviour = .stopManaged
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
    var body: some View {
        Form {
            LabeledContent("Captured PATH") {
                // TODO(v0.2): show ShellEnv's captured PATH and last-loaded time.
                Text("Not captured yet")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Button("Reload Shell Environment") {}
                .disabled(true)
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
