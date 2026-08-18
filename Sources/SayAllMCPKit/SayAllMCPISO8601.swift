import Foundation

enum SayAllMCPISO8601 {
    static func string(from date: Date) -> String {
        fractionalFormatter.string(from: date)
    }

    static func date(from value: String) -> Date? {
        fractionalFormatter.date(from: value) ?? standardFormatter.date(from: value)
    }

    static func configureEncoder(_ encoder: JSONEncoder) {
        encoder.dateEncodingStrategy = .custom { date, target in
            var container = target.singleValueContainer()
            try container.encode(string(from: date))
        }
    }

    static func configureDecoder(_ decoder: JSONDecoder) {
        decoder.dateDecodingStrategy = .custom { source in
            let container = try source.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO-8601 date-time."
                )
            }
            return date
        }
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let standardFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
