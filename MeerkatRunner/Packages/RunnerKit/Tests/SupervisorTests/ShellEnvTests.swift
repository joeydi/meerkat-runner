import Foundation
import Supervisor
import XCTest

final class ShellEnvTests: XCTestCase {
    func testParsesOnlyBetweenSentinels() {
        let sentinel = "__MEERKAT_7F3A__"
        var output = Data("Welcome to oh-my-zsh!\nFOO=banner\n".utf8)
        output.append(Data(sentinel.utf8))
        output.append(Data("PATH=/opt/homebrew/bin:/usr/bin\u{0}HOME=/Users/me\u{0}EMPTY=\u{0}".utf8))
        output.append(Data(sentinel.utf8))
        output.append(Data("\nbye\n".utf8))

        let env = ShellEnv.parse(output, sentinel: sentinel)
        XCTAssertEqual(env?["PATH"], "/opt/homebrew/bin:/usr/bin")
        XCTAssertEqual(env?["HOME"], "/Users/me")
        XCTAssertEqual(env?["EMPTY"], "")
        XCTAssertNil(env?["FOO"])
    }

    func testMissingSentinelFails() {
        XCTAssertNil(ShellEnv.parse(Data("PATH=/usr/bin".utf8), sentinel: "__X__"))
    }
}
