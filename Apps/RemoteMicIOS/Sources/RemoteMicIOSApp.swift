import SwiftUI

@main
struct RemoteMicIOSApp: App {
    @StateObject private var connection = RemoteMacConnection()

    var body: some Scene {
        WindowGroup {
            RemoteControlScreen()
                .environmentObject(connection)
        }
    }
}
