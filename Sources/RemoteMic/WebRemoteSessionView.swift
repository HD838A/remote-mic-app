import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct WebRemoteSessionView: View {
    @ObservedObject var model: BridgeAppModel
    @EnvironmentObject private var localization: LocalizationStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("connection.web.title")
                    .font(.title2.bold())
                Text("connection.web.sheet_help")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 12) {
                if model.webRemoteState.isEnabled {
                    Button("connection.web.disconnect", role: .destructive) {
                        model.disableWebRemoteConnection()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("connection.web.retry") {
                        model.enableWebRemoteConnection()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("common.action.close") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(28)
        .frame(width: 440, height: 550)
    }

    @ViewBuilder
    private var content: some View {
        switch model.webRemoteState {
        case .disabled:
            statusContent(
                systemImage: "iphone.slash",
                title: localization.text("connection.web.disabled"),
                detail: localization.text("connection.web.disabled_help"),
                tint: .secondary
            )
        case .unavailable:
            statusContent(
                systemImage: "exclamationmark.triangle",
                title: localization.text("connection.web.unavailable"),
                detail: localization.text("connection.web.unavailable_help"),
                tint: .orange
            )
        case .connecting:
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("connection.web.connecting")
                    .font(.headline)
                Text("connection.web.connecting_help")
                    .foregroundStyle(.secondary)
            }
        case let .waitingForPhone(joinURL, pairingCode, expiresAt):
            qrContent(
                joinURL: joinURL,
                pairingCode: pairingCode,
                detail: expirationText(expiresAt)
            )
        case let .awaitingApproval(joinURL, pairingCode, deviceName):
            qrContent(
                joinURL: joinURL,
                pairingCode: pairingCode,
                detail: String(
                    format: localization.text("connection.web.awaiting_approval"),
                    locale: localization.locale,
                    arguments: [deviceName]
                )
            )
        case let .connected(deviceName):
            statusContent(
                systemImage: "checkmark.circle.fill",
                title: localization.text("connection.web.connected"),
                detail: String(
                    format: localization.text("connection.web.connected_device"),
                    locale: localization.locale,
                    arguments: [deviceName]
                ),
                tint: .green
            )
        case let .failed(detail):
            statusContent(
                systemImage: "wifi.exclamationmark",
                title: localization.text("connection.web.failed"),
                detail: detail,
                tint: .orange
            )
        }
    }

    private func qrContent(joinURL: URL, pairingCode: String, detail: String) -> some View {
        VStack(spacing: 14) {
            if let image = QRCodeRenderer.image(for: joinURL.absoluteString) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 250, height: 250)
                    .accessibilityLabel("connection.web.qr_accessibility")
            }
            Text("connection.web.scan")
                .font(.headline)
            VStack(spacing: 4) {
                Text("connection.web.pairing_code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(pairingCode.map(String.init).joined(separator: " "))
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundStyle(.orange)
                    .accessibilityLabel(
                        String(
                            format: localization.text("connection.web.pairing_code_accessibility"),
                            locale: localization.locale,
                            arguments: [pairingCode]
                        )
                    )
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func statusContent(
        systemImage: String,
        title: String,
        detail: String,
        tint: Color
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 54, weight: .medium))
                .foregroundStyle(tint)
            Text(title)
                .font(.headline)
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
        }
    }

    private func expirationText(_ date: Date?) -> String {
        guard let date else { return localization.text("connection.web.scan_help") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = localization.locale
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: date, relativeTo: Date())
        return String(
            format: localization.text("connection.web.expires"),
            locale: localization.locale,
            arguments: [relative]
        )
    }
}

private enum QRCodeRenderer {
    static func image(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(
                  output,
                  from: output.extent
              )
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
