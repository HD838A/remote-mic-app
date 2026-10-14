import AppKit
import SwiftUI

struct SupplementalSettingsPage: Identifiable, Equatable {
    let id: String
    let title: String
    let systemImage: String
}

/// Optional private pages use a stable metadata/view registration contract.
/// No page URLs, copy or business implementation are part of the public host.
@MainActor
final class SupplementalSettingsIntegration {
    private let provider: NSObject?

    init(provider: NSObject? = nil) {
        if let provider { self.provider = provider }
        else { self.provider = (NSClassFromString("SayAllSupplementalSettingsProvider") as? NSObject.Type)?.init() }
    }
    func pages(localeIdentifier: String) -> [SupplementalSettingsPage] {
        let selector = NSSelectorFromString("pagesForLocaleIdentifier:")
        guard let provider, provider.responds(to: selector),
              let values = provider.perform(selector, with: localeIdentifier)?.takeUnretainedValue() as? [[String: String]] else { return [] }
        return Self.validPages(values)
    }
    static func validPages(_ values: [[String: String]]) -> [SupplementalSettingsPage] {
        var seen = Set<String>()
        return values.compactMap {
            guard let id = $0["id"], !id.isEmpty, id.count <= 80,
                  id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
                  let title = $0["title"], !title.isEmpty,
                  let image = $0["systemImage"], !image.isEmpty, seen.insert(id).inserted else { return nil }
            return SupplementalSettingsPage(id: id, title: title, systemImage: image)
        }
    }
    func view(pageID: String, localeIdentifier: String) -> AnyView? {
        let selector = NSSelectorFromString("viewForPageID:localeIdentifier:")
        guard let provider, provider.responds(to: selector) else { return nil }
        return AnyView(SupplementalSettingsHostView(provider: provider, pageID: pageID, localeIdentifier: localeIdentifier)
            .id(pageID + ":" + localeIdentifier)
            .ignoresSafeArea(.container, edges: .top))
    }
}

private struct SupplementalSettingsHostView: NSViewRepresentable {
    let provider: NSObject
    let pageID: String
    let localeIdentifier: String
    func makeNSView(context: Context) -> NSView {
        provider.perform(NSSelectorFromString("viewForPageID:localeIdentifier:"), with: pageID, with: localeIdentifier)?.takeUnretainedValue() as? NSView ?? NSView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
