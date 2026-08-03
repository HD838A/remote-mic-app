import SwiftUI

@main
struct RemoteMicIOSApp: App {
    @StateObject private var connection = RemoteMacConnection()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                RemoteControlScreen()
            }
            .environmentObject(connection)
        }
    }
}
