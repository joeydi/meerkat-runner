// swift-tools-version: 6.0
// RunnerKit: everything in Meerkat Runner that can be tested without UI.
// See AGENTS.md §2 for the module layout and §8.1 for the access-control rule
// that keeps the supervisor's spawn API reachable only from `Approval`.

import PackageDescription

let package = Package(
    name: "RunnerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Models", targets: ["Models"]),
        .library(name: "Scanner", targets: ["Scanner"]),
        .library(name: "Detection", targets: ["Detection"]),
        .library(name: "Approval", targets: ["Approval"]),
        .library(name: "Store", targets: ["Store"]),
        .library(name: "Supervisor", targets: ["Supervisor"]),
        .library(name: "Registry", targets: ["Registry"]),
    ],
    targets: [
        // Unsafe libproc / sysctl access lives only in CProcInfo, ProcInfo and Supervisor.
        .target(name: "CProcInfo"),
        .target(name: "ProcInfo", dependencies: ["CProcInfo"]),
        // Raw posix_spawn / openpty. Only Supervisor may depend on this (AGENTS.md §8.1 rule 2).
        .target(name: "CSpawn"),

        // Value types shared by every module (AGENTS.md §3).
        .target(name: "Models"),

        .target(name: "Scanner", dependencies: ["Models", "ProcInfo"]),
        .target(name: "Detection", dependencies: ["Models"]),
        .target(name: "Supervisor", dependencies: ["Models", "ProcInfo", "CSpawn"]),
        .target(name: "Approval", dependencies: ["Models", "Supervisor"]),
        .target(name: "Store", dependencies: ["Models"]),
        .target(
            name: "Registry",
            dependencies: ["Models", "Scanner", "Detection", "Approval", "Store", "Supervisor"]
        ),

        // Fixtures live in Tests/Fixtures (shared, not a target) and are located via #filePath.
        .testTarget(name: "DetectionTests", dependencies: ["Detection", "Models"]),
        .testTarget(name: "ApprovalTests", dependencies: ["Approval", "Models"]),
        .testTarget(name: "StoreTests", dependencies: ["Store", "Models"]),
        .testTarget(name: "SupervisorTests", dependencies: ["Supervisor", "Models", "ProcInfo"]),
        .testTarget(name: "ScannerTests", dependencies: ["Scanner", "Models", "ProcInfo"]),
        .testTarget(name: "RegistryTests", dependencies: ["Registry", "Models", "Store", "Approval"]),
    ],
    swiftLanguageModes: [.v6]
)
