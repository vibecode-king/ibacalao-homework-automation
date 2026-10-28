import SwiftUI
import AppKit
import CoreImage

private enum DispatchQRCode {
    static func image(for payload: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: 7, y: 7))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 210, height: 210))
    }
}

struct DispatchModePanel: View {
    @ObservedObject private var dispatch = DispatchModeService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("CONNECT YOUR PHONE")
                        .font(BrandFont.mono(11, weight: .medium))
                        .foregroundStyle(Brand.faint)
                        .tracking(1.2)

                    Text(dispatch.isActive ? "Computer is staying awake" : "Connect your phone to this computer")
                        .font(BrandFont.display(22, weight: .semibold))
                        .foregroundStyle(dispatch.isActive ? Brand.success : Brand.bright)
                        .tracking(-0.4)

                    Text(dispatch.isActive
                         ? "Your phone is connected and this computer will stay awake."
                         : "Your phone can receive updates and control this computer.")
                        .font(BrandFont.body(13))
                        .foregroundStyle(Brand.muted)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("WHAT IS DISPATCH MODE?")
                        .font(BrandFont.mono(10, weight: .medium))
                        .foregroundStyle(Brand.faint)
                        .tracking(1.1)
                    Text("Dispatch Mode links your phone to this Mac over your local network, no internet account needed. Once linked, your phone can open Marginalia on this computer and keep it from falling asleep, so it's ready when you need it.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(Brand.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.card)
                .overlay(
                    RoundedRectangle(cornerRadius: Brand.cornerLg)
                        .stroke(Brand.hairline, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: Brand.cornerLg))

                if let advertiserError = dispatch.advertiserError {
                    HStack(alignment: .top, spacing: 10) {
                        Text("!")
                            .font(BrandFont.mono(12, weight: .bold))
                            .foregroundStyle(Brand.danger)
                        Text(advertiserError)
                            .font(BrandFont.body(12))
                            .foregroundStyle(Brand.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: Brand.cornerLg)
                            .stroke(Brand.danger.opacity(0.5), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Brand.cornerLg))
                }

                HStack(alignment: .top, spacing: 18) {
                    if let qrImage = DispatchQRCode.image(for: dispatch.pairingPayload) {
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 156, height: 156)
                            .background(Color.white)
                            .accessibilityLabel("Phone connection QR code")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("SCAN OR ENTER")
                            .font(BrandFont.mono(10, weight: .medium))
                            .foregroundStyle(Brand.faint)
                            .tracking(1.1)

                        Text(dispatch.pairingCode)
                            .font(BrandFont.mono(29, weight: .semibold))
                            .foregroundStyle(Brand.accent)
                            .tracking(3.5)

                        Text("Scan this with the iBacalao phone app, or enter the six-digit code there.")
                            .font(BrandFont.body(12))
                            .foregroundStyle(Brand.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.card)
                .overlay(
                    RoundedRectangle(cornerRadius: Brand.cornerLg)
                        .stroke(Brand.hairline, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: Brand.cornerLg))

                VStack(alignment: .leading, spacing: 12) {
                    statusRow(label: "PHONE", value: dispatch.isConnected ? dispatch.phoneName : "Not connected")
                    statusRow(label: "CONNECTION", value: dispatch.isPaired ? "Connected" : "Waiting for code")
                    statusRow(label: "MARGINALIA", value: dispatch.marginaliaVisible ? "Open" : "Hidden")
                    statusRow(label: "SLEEP PREVENTION", value: dispatch.isActive ? "Active" : "Off")
                    statusRow(label: "LAST UPDATE", value: dispatch.lastEvent)
                }

                Toggle(isOn: Binding(
                    get: { dispatch.alwaysOn },
                    set: { dispatch.setAlwaysOn($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Always on")
                            .font(BrandFont.body(13, weight: .medium))
                            .foregroundStyle(Brand.bright)
                        Text("Keep this computer awake even when no phone is connected.")
                            .font(BrandFont.body(11))
                            .foregroundStyle(Brand.muted)
                    }
                }
                .toggleStyle(.switch)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.card)
                .overlay(
                    RoundedRectangle(cornerRadius: Brand.cornerLg)
                        .stroke(Brand.hairline, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: Brand.cornerLg))

                HStack(spacing: 12) {
                    Button("Generate new code") {
                        dispatch.regeneratePairingCode()
                    }
                    .buttonStyle(BrandGhostButtonStyle())

                    if dispatch.isPaired {
                        Button("Disconnect phone") {
                            dispatch.disconnectPhone()
                        }
                        .buttonStyle(BrandGhostButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(BrandFont.mono(10, weight: .medium))
                .foregroundStyle(Brand.faint)
                .tracking(0.8)
                .frame(width: 126, alignment: .leading)
            Text(value)
                .font(BrandFont.body(12))
                .foregroundStyle(Brand.bright)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}
