# Meerkat Runner

A native macOS menu bar app that lists every local dev server, registers projects from a folder with
auto-detected start commands, and starts/stops them from one dropdown. A companion to **Meerkat**.

- Behaviour and architecture: [`AGENTS.md`](AGENTS.md) (read it first)
- Visual spec: [`design-handoff/DESIGN.md`](design-handoff/DESIGN.md)

## Layout

```
MeerkatRunner/
├── project.yml              # XcodeGen spec (the .xcodeproj is generated, not committed)
├── App/                     # SwiftUI menu bar app
├── Packages/RunnerKit/      # testable core: scanner, detectors, approval, store, supervisor, registry
└── Scripts/                 # release.sh, test servers
```

## Build

Requires macOS 14+, Xcode 16+.

```sh
brew install xcodegen
cd MeerkatRunner
xcodegen
open MeerkatRunner.xcodeproj
```

Run the core tests:

```sh
cd MeerkatRunner/Packages/RunnerKit
swift test
```

Always test a build launched from Finder, not just from Xcode: GUI apps don't inherit your shell's
`PATH` (AGENTS.md §14).
