import Foundation

/// Where ClickLens keeps the settings Preferences and settings sync read and write. Normally
/// UserDefaults.standard; an agent CLI test copy (a Debug build run with `APP_STORE`) gets a
/// domain of its own, since it shares the installed app's bundle ID and with it its
/// preferences. Release builds always use the standard domain.
enum AppDefaults {
    nonisolated(unsafe) static let store: UserDefaults = {
        #if DEBUG
        if AgentSocket.isTestRun, let suite = UserDefaults(suiteName: testSuite) { return suite }
        #endif
        return .standard
    }()

    static let testSuite = "com.smanke.ClickLens.agenttest"
}
