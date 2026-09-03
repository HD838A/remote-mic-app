import Combine
import Foundation

struct AvailableUpdateInformation: Equatable {
    let displayVersion: String
    let buildVersion: String
    let releaseNotes: [String]
}

enum UpdateInformationState: Equatable {
    case idle
    case checking
    case upToDate
    case unavailable
    case available(AvailableUpdateInformation)
}

enum UpdateFeedResolutionError: Error {
    case invalidResponse
}

enum UpdateFeedResolver {
    struct ResolvedFeed: Equatable {
        let url: URL
        let version: String
        let isPreRelease: Bool
    }

    static func testInjectedFeed(
        environment: [String: String],
        assetName: String,
        includePreRelease: Bool
    ) -> ResolvedFeed? {
        guard environment["REMOTE_MIC_UI_TEST_MODE"] == "1",
              includePreRelease,
              let rawURL = environment["REMOTE_MIC_UI_TEST_FEED_URL"],
              let url = URL(string: rawURL),
              url.scheme == "http",
              url.host == "127.0.0.1",
              url.port != nil,
              ["appcast.xml", "appcast-intel.xml"].contains(url.lastPathComponent),
              url.lastPathComponent == assetName,
              let rawVersion = environment["REMOTE_MIC_UI_TEST_VERSION"],
              let version = UpdateVersion.normalized(rawVersion)
        else { return nil }
        return ResolvedFeed(url: url, version: version, isPreRelease: true)
    }

}

enum UpdateVersion {
    static func normalized(_ rawValue: String) -> String? {
        let value = rawValue.hasPrefix("v") ? String(rawValue.dropFirst()) : rawValue
        guard value.range(of: #"^\d+(?:\.\d+){1,3}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidate = normalized(candidate),
              let current = normalized(current)
        else { return false }
        let candidateParts = candidate.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }
        let count = max(candidateParts.count, currentParts.count)
        for index in 0..<count {
            let candidatePart = index < candidateParts.count ? candidateParts[index] : 0
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            if candidatePart != currentPart {
                return candidatePart > currentPart
            }
        }
        return false
    }
}

enum UpdateReleaseNotes {
    private static let maximumDownloadSize = 128 * 1_024

    static func languageCode(for localeIdentifier: String) -> String {
        localeIdentifier.lowercased().hasPrefix("zh") ? "zh" : "en"
    }

    static func assetURL(
        for updateArchiveURL: URL,
        displayVersion: String,
        localeIdentifier: String
    ) -> URL? {
        guard updateArchiveURL.scheme == "https",
              updateArchiveURL.host == "github.com",
              displayVersion.range(of: #"^[0-9A-Za-z.-]+$"#, options: .regularExpression) != nil
        else { return nil }
        let languageCode = languageCode(for: localeIdentifier)
        return updateArchiveURL
            .deletingLastPathComponent()
            .appendingPathComponent("Remote-Mic-\(displayVersion).\(languageCode).txt")
    }

    static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: \Character.isNewline).compactMap { line in
            var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("- ") || value.hasPrefix("• ") {
                value.removeFirst(2)
            }
            guard !value.isEmpty, !value.hasPrefix("#") else { return nil }
            return value
        }
    }

    static func load(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("RemoteMic", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              data.count <= maximumDownloadSize,
              let text = String(data: data, encoding: .utf8)
        else {
            throw UpdateFeedResolutionError.invalidResponse
        }
        return text
    }
}

@MainActor
final class UpdateInformationStore: ObservableObject {
    typealias NotesLoader = @Sendable (URL) async throws -> String

    @Published private(set) var state: UpdateInformationState = .idle

    private struct PendingUpdate: Equatable {
        let displayVersion: String
        let buildVersion: String
        let archiveURL: URL?
        let fallbackNotes: [String]
    }

    private let notesLoader: NotesLoader
    private var pendingUpdate: PendingUpdate?
    private var notesTask: Task<Void, Never>?
    private var notesGeneration = 0

    init(
        notesLoader: @escaping NotesLoader = { url in
            try await UpdateReleaseNotes.load(from: url)
        }
    ) {
        self.notesLoader = notesLoader
    }

    deinit {
        notesTask?.cancel()
    }

    func beginChecking() {
        state = .checking
    }

    func reset() {
        notesTask?.cancel()
        pendingUpdate = nil
        state = .idle
    }

    func setUpToDate() {
        notesTask?.cancel()
        pendingUpdate = nil
        state = .upToDate
    }

    func setUnavailable() {
        notesTask?.cancel()
        pendingUpdate = nil
        state = .unavailable
    }

    func setAvailable(
        displayVersion: String,
        buildVersion: String,
        archiveURL: URL?,
        fallbackDescription: String?,
        localeIdentifier: String
    ) {
        let pending = PendingUpdate(
            displayVersion: displayVersion,
            buildVersion: buildVersion,
            archiveURL: archiveURL,
            fallbackNotes: fallbackDescription.map(UpdateReleaseNotes.parse) ?? []
        )
        pendingUpdate = pending
        state = .available(information(for: pending, notes: pending.fallbackNotes))
        loadReleaseNotes(for: pending, localeIdentifier: localeIdentifier)
    }

    func reloadReleaseNotes(localeIdentifier: String) {
        guard let pendingUpdate else { return }
        loadReleaseNotes(for: pendingUpdate, localeIdentifier: localeIdentifier)
    }

    private func information(
        for pending: PendingUpdate,
        notes: [String]
    ) -> AvailableUpdateInformation {
        AvailableUpdateInformation(
            displayVersion: pending.displayVersion,
            buildVersion: pending.buildVersion,
            releaseNotes: notes
        )
    }

    private func loadReleaseNotes(
        for pending: PendingUpdate,
        localeIdentifier: String
    ) {
        notesTask?.cancel()
        guard let archiveURL = pending.archiveURL,
              let notesURL = UpdateReleaseNotes.assetURL(
                for: archiveURL,
                displayVersion: pending.displayVersion,
                localeIdentifier: localeIdentifier
              )
        else { return }

        notesGeneration += 1
        let generation = notesGeneration
        let notesLoader = notesLoader
        notesTask = Task { [weak self] in
            do {
                let text = try await notesLoader(notesURL)
                guard !Task.isCancelled, let self,
                      generation == self.notesGeneration,
                      self.pendingUpdate == pending
                else { return }
                let notes = UpdateReleaseNotes.parse(text)
                guard !notes.isEmpty else { return }
                self.state = .available(self.information(for: pending, notes: notes))
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
    }
}
