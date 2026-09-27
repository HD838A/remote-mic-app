import Foundation

#if SAYALL_DIAGNOSTICS_ENABLED && canImport(SayAllDiagnosticsTransport)
import SayAllDiagnosticsTransport
#endif

enum DiagnosticUploadConfigurationState: Equatable, Sendable {
    case unavailable
    case configured
    case invalid
}

enum DiagnosticUploadTransportFactory {
    static var configurationState: DiagnosticUploadConfigurationState {
        #if SAYALL_DIAGNOSTICS_ENABLED && canImport(SayAllDiagnosticsTransport)
        switch SayAllDiagnosticsHostAdapter.configurationState {
        case .configured: return .configured
        case .invalid: return .invalid
        case .unavailable: return .unavailable
        }
        #else
        return .unavailable
        #endif
    }

    static func send(entries: [DiagnosticLogEntry]) throws {
        #if SAYALL_DIAGNOSTICS_ENABLED && canImport(SayAllDiagnosticsTransport)
        try SayAllDiagnosticsHostAdapter.shared.upload(
            canonicalLines: entries.map(\.message)
        )
        #else
        throw DiagnosticLogUploadError.serviceNotConfigured
        #endif
    }
}
