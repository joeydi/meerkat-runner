import Scanner
import XCTest

final class AppListenersTests: XCTestCase {
    func testDesktopAppsAreAppListeners() {
        for path in [
            "/Applications/Dropbox.app/Contents/MacOS/Dropbox",
            "/Applications/Raycast.app/Contents/MacOS/Raycast",
            "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)",
            "/Library/Application Support/Adobe/Adobe Desktop Common/ADS/Adobe Desktop Service.app/Contents/MacOS/Adobe Desktop Service",
            "/Users/me/Library/Application Support/Figma/FigmaAgent.app/Contents/MacOS/figma_agent",
            "/Applications/Setapp/Bartender.app/Contents/MacOS/Bartender",
        ] {
            XCTAssertTrue(AppListeners.isAppExecutable(path), path)
        }
    }

    func testDevServersStayVisible() {
        for path in [
            "/opt/homebrew/bin/node",
            "/opt/homebrew/opt/httpd/bin/httpd",
            "/opt/homebrew/Cellar/python@3.12/3.12.7/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python",
            "/Library/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python",
            "/Applications/Postgres.app/Contents/Versions/16/bin/postgres",
            "/Applications/Docker.app/Contents/MacOS/com.docker.backend",
            "/Applications/OrbStack.app/Contents/MacOS/OrbStack Helper",
            "/Applications/MAMP/Library/bin/mysql80/bin/mysqld",
            "/Users/me/.nvm/versions/node/v22.11.0/bin/node",
            "node", // executable path unknown; falls back to the process name
        ] {
            XCTAssertFalse(AppListeners.isAppExecutable(path), path)
        }
    }
}
