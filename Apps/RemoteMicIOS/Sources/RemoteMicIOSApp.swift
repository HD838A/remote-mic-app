import SwiftUI

@main
struct RemoteMicIOSApp: App {
    @StateObject private var connection = RemoteMacConnection()

    var body: some Scene {
        WindowGroup {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    NavigationStack {
                        RemoteControlScreen()
                    }

                    if proxy.safeAreaInsets.top >= 44 {
                        CutoutEasterEgg()
                            .padding(.top, 2)
                            .zIndex(1)
                    }
                }
            }
            .environmentObject(connection)
        }
    }
}

private struct CutoutEasterEgg: View {
    var body: some View {
        HStack(spacing: 3) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .clipShape(AppIconRoundedRectangle())
                .frame(width: 20, height: 20)

            Text("无线麦")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(RemotePalette.text)
        }
        .frame(height: 24)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
