import Foundation
import Models

/// Known macOS system processes that listen as the user. Hidden from "Other listeners" by default
/// (toggle in Settings). Keep this a data table (AGENTS.md §4).
public enum SystemListeners {
    /// Process names (`pbi_name` / executable basename).
    public static let processNames: Set<String> = [
        "ControlCenter", // AirPlay Receiver on 5000 and 7000
        "rapportd",
        "sharingd",
        "identityservicesd",
        "remoted",
        "WiFiAgent",
        "UniversalControl",
        "AirPlayXPCHelper",
    ]

    public static func isSystemListener(_ listener: Listener) -> Bool {
        processNames.contains(listener.processName)
    }
}
