import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SayAllMacRemoteCore
import SwiftUI

enum PhoneRemoteInvitationQRCode {
    static func image(
        for invitation: PhoneRemoteInvitation,
        scale: CGFloat = 8
    ) -> NSImage? {
        guard let url = invitation.url else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let transformed = output.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let representation = NSCIImageRep(ciImage: transformed)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

struct PhoneRemoteInvitationCard: View {
    let invitation: PhoneRemoteInvitation

    var body: some View {
        HStack(spacing: 16) {
            if let image = PhoneRemoteInvitationQRCode.image(for: invitation) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 132, height: 132)
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel(Text("connection.phone.qr_accessibility"))
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("connection.phone.qr_title", systemImage: "qrcode.viewfinder")
                    .font(.system(size: 15, weight: .semibold))
                Text("connection.phone.qr_help")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("connection.phone.qr_refresh")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
