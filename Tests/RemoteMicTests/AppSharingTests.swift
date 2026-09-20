import Foundation
import Testing
@testable import RemoteMic

struct AppSharingTests {
    @Test func localizedForkShareLinksIncludeTheMacShareSource() throws {
        let chinese = try components(AppShareLink.url(for: Locale(identifier: "zh-Hans")))
        let english = try components(AppShareLink.url(for: Locale(identifier: "en")))

        #expect(chinese.scheme == "https")
        #expect(chinese.host == "github.com")
        #expect(chinese.path == "/unfla-sh/MiRemote2Pro-Whisper")
        #expect(chinese.queryItems == [URLQueryItem(name: "from", value: "mac_share")])

        #expect(english.scheme == "https")
        #expect(english.host == "github.com")
        #expect(english.path == "/unfla-sh/MiRemote2Pro-Whisper")
        #expect(english.queryItems == [URLQueryItem(name: "from", value: "mac_share")])
    }

    @Test func shareSourcePreservesOtherQueryItemsAndOverwritesExistingFrom() throws {
        let baseURL = try #require(URL(
            string: "https://sayall.app/en/?campaign=friend&from=old#download"
        ))
        let result = AppShareLink.url(byAddingSourceTo: baseURL)
        let resultComponents = try components(result)

        #expect(resultComponents.path == "/en/")
        #expect(resultComponents.fragment == "download")
        #expect(resultComponents.queryItems == [
            URLQueryItem(name: "campaign", value: "friend"),
            URLQueryItem(name: "from", value: "mac_share"),
        ])
    }

    @Test func qrCodeAndClipboardUseTheSameCanonicalString() throws {
        let url = AppShareLink.url(for: Locale(identifier: "zh-Hans"))
        var copiedString: String?
        let copied = AppShareClipboard.copy(url) {
            copiedString = $0
            return true
        }

        #expect(copied)
        #expect(copiedString == url.absoluteString)
        #expect(AppShareQRCode.payload(for: url) == Data(url.absoluteString.utf8))
        #expect(AppShareQRCode.image(for: url) != nil)
    }

    @Test func clipboardReportsWriterFailure() {
        let url = AppShareLink.url(for: Locale(identifier: "en"))
        #expect(!AppShareClipboard.copy(url) { _ in false })
    }

    private func components(_ url: URL) throws -> URLComponents {
        try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    }
}
