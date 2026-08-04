import SwiftUI

@main
struct RemoteMicIOSApp: App {
    @StateObject private var connection = RemoteMacConnection()
    @AppStorage(AppLanguage.storageKey) private var storedLanguage = ""

    private var appLanguage: AppLanguage {
        AppLanguage.resolve(
            storedValue: storedLanguage,
            preferredLanguages: Locale.preferredLanguages
        )
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                RemoteControlScreen()
            }
            .environmentObject(connection)
            .environment(\.appLanguage, appLanguage)
            .environment(\.locale, appLanguage.locale)
        }
    }
}

struct CutoutEasterEgg: View {
    @Environment(\.appLanguage) private var language

    var body: some View {
        HStack(spacing: 3) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .clipShape(AppIconRoundedRectangle())
                .frame(width: 20, height: 20)

            Text(language.text("无线麦"))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(RemotePalette.text)
        }
        .frame(height: 24)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
