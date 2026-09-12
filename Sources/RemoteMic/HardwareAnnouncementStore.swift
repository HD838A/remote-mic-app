import Combine
import Foundation

struct HardwareAnnouncement: Decodable, Equatable, Identifiable {
    let id: String
    let hardware: String
    let title: [String: String]
    let message: [String: String]
    let downloadURL: URL
    let expiresAt: Date?

    func title(for locale: Locale) -> String {
        localizedValue(title, locale: locale) ?? hardware
    }

    func message(for locale: Locale) -> String {
        localizedValue(message, locale: locale) ?? hardware
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    private func localizedValue(_ values: [String: String], locale: Locale) -> String? {
        let preferred = locale.identifier.replacingOccurrences(of: "_", with: "-")
        let language = locale.language.languageCode?.identifier ?? "en"
        return values[preferred]
            ?? values[language]
            ?? values["en"]
            ?? values.values.first
    }
}

private struct HardwareAnnouncementEnvelope: Decodable {
    let announcements: [HardwareAnnouncement]
}

enum HardwareAnnouncementSource {
    static let defaultURL = URL(
        string: "https://download.sayall.app/mac/announcements/hardware.json"
    )!

    static func resolve(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if environment["REMOTE_MIC_UI_TEST_MODE"] == "1",
           let injected = environment["REMOTE_MIC_UI_TEST_HARDWARE_ANNOUNCEMENTS_URL"],
           let url = URL(string: injected),
           url.scheme == "http",
           url.host == "127.0.0.1" {
            return url
        }

        if let configured = bundle.object(forInfoDictionaryKey: "HardwareAnnouncementURL") as? String,
           let url = URL(string: configured),
           isAllowed(url) {
            return url
        }
        return defaultURL
    }

    private static func isAllowed(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if url.scheme == "https" && host == "download.sayall.app" { return true }
        if url.scheme == "https" && host == "raw.githubusercontent.com" { return true }
        return false
    }
}

final class HardwareAnnouncementStore: ObservableObject {
    @Published private(set) var announcements: [HardwareAnnouncement] = []
    @Published private(set) var isLoading = false

    private let session: URLSession
    private let sourceURL: () -> URL
    private let logger: (String) -> Void
    private var task: URLSessionDataTask?
    private var requestGeneration = 0

    init(
        session: URLSession = .shared,
        sourceURL: @escaping () -> URL = { HardwareAnnouncementSource.resolve() },
        logger: @escaping (String) -> Void = AppLogger.shared.write
    ) {
        self.session = session
        self.sourceURL = sourceURL
        self.logger = logger
    }

    deinit {
        task?.cancel()
    }

    func refresh() {
        task?.cancel()
        requestGeneration &+= 1
        let generation = requestGeneration
        isLoading = true
        logger("HARDWARE ANNOUNCEMENT request_started")
        var request = URLRequest(url: sourceURL())
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.requestGeneration == generation else { return }
                defer {
                    self.isLoading = false
                    self.task = nil
                }
                guard error == nil,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let data,
                      let envelope = try? JSONDecoder.hardwareAnnouncement.decode(
                        HardwareAnnouncementEnvelope.self,
                        from: data
                      )
                else {
                    self.announcements = []
                    self.logger("HARDWARE ANNOUNCEMENT request_failed")
                    return
                }
                self.announcements = envelope.announcements.filter {
                    !$0.isExpired && $0.downloadURL.scheme?.lowercased() == "https"
                }
                self.logger(
                    "HARDWARE ANNOUNCEMENT request_succeeded " +
                        "visible_count=\(self.announcements.count)"
                )
            }
        }
        self.task = task
        task.resume()
    }
}

private extension JSONDecoder {
    static var hardwareAnnouncement: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
