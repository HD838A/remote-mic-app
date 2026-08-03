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
                            .offset(y: -proxy.safeAreaInsets.top + 9)
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
                .frame(width: 14, height: 14)

            Text("无线麦")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(RemotePalette.text)
        }
        .frame(height: 20)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
