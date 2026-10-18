import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins
import OrderCore

/// Label sizes. Printers differ, so the label is delivered as PDF/PNG at a fixed
/// physical size (the printer app or AirPrint scales it onto the label roll).
enum LabelStyle: String, CaseIterable, Identifiable {
    case narrow, wide
    var id: String { rawValue }
    var title: String { self == .narrow ? "Schmal" : "Breit" }
    var detail: String { self == .narrow ? "50 × 25 mm, für Etikettendrucker" : "58 × 45 mm, für Bon- und Thermodrucker" }
    /// Page size in points (1 mm = 2.8346 pt).
    var size: CGSize { self == .narrow ? CGSize(width: 141.7, height: 70.9) : CGSize(width: 164.4, height: 127.6) }
}

enum QRCode {
    /// A sharp, black-on-white QR code for the text (error correction M).
    static func image(for text: String, points: CGFloat = 400) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, (points / output.extent.width).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// What gets printed for one place: code, name, path and the QR code of its link.
struct LabelContent {
    let code: String
    let name: String
    let path: String
    let link: String
}

struct LabelView: View {
    let content: LabelContent
    let style: LabelStyle

    var body: some View {
        let qr = QRCode.image(for: content.link)
        Group {
            if style == .narrow {
                HStack(spacing: 6) {
                    qrImage(qr).frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(content.code).font(.system(size: 17, weight: .bold, design: .monospaced))
                        Text(content.name).font(.system(size: 9, weight: .semibold)).lineLimit(2)
                        Text(content.path).font(.system(size: 6.5)).lineLimit(3).foregroundStyle(Color.black.opacity(0.7))
                    }
                    Spacer(minLength: 0)
                }
            } else {
                VStack(spacing: 3) {
                    qrImage(qr).frame(width: 80, height: 80)
                    Text(content.code).font(.system(size: 18, weight: .bold, design: .monospaced))
                    Text(content.name).font(.system(size: 10, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                    Text(content.path).font(.system(size: 7)).lineLimit(3).multilineTextAlignment(.center)
                        .foregroundStyle(Color.black.opacity(0.7))
                }
            }
        }
        .foregroundStyle(Color.black)
        .padding(5)
        .frame(width: style.size.width, height: style.size.height)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private func qrImage(_ image: UIImage?) -> some View {
        Group {
            if let image { Image(uiImage: image).interpolation(.none).resizable().scaledToFit() }
            else { Image(systemName: "qrcode") .resizable().scaledToFit() }
        }
    }
}

@MainActor
enum LabelRenderer {
    /// Label texts for the given places; assigns missing codes first.
    static func contents(for ids: [UUID], model: AppModel) -> [LabelContent] {
        ids.compactMap { id in
            guard model.perform({ try $0.ensureLabelCode(placeID: id) }),
                  let place = model.state.places.first(where: { $0.id == id }), let code = place.code else { return nil }
            return LabelContent(code: code, name: place.name, path: model.state.path(for: id),
                                link: PlaceLink.url(for: id).absoluteString)
        }
    }

    /// One PDF page per label, at the label's physical size.
    static func pdf(_ labels: [LabelContent], style: LabelStyle, name: String) -> URL? {
        guard !labels.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).pdf")
        var box = CGRect(origin: .zero, size: style.size)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return nil }
        for label in labels {
            let renderer = ImageRenderer(content: LabelView(content: label, style: style))
            renderer.render { _, draw in
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
            }
        }
        context.closePDF()
        return url
    }

    /// A sharp PNG (about 8× the point size) for printer apps that take images.
    static func png(_ label: LabelContent, style: LabelStyle, name: String) -> URL? {
        let renderer = ImageRenderer(content: LabelView(content: label, style: style))
        renderer.scale = 8
        guard let data = renderer.uiImage?.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }

    static func preview(_ label: LabelContent, style: LabelStyle) -> UIImage? {
        let renderer = ImageRenderer(content: LabelView(content: label, style: style))
        renderer.scale = 4
        return renderer.uiImage
    }

    static func printPDF(_ url: URL, jobName: String) {
        guard UIPrintInteractionController.canPrint(url) else { return }
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = jobName
        info.outputType = .general
        controller.printInfo = info
        controller.printingItem = url
        controller.present(animated: true)
    }
}

/// Preview, size choice, AirPrint and sharing for one place's label – or for several at once.
struct LabelSheet: View {
    let placeIDs: [UUID]
    /// Codes of blank labels printed in advance (no place yet).
    var blankCodes: [String] = []
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var style: LabelStyle = .narrow
    @State private var labels: [LabelContent] = []
    @State private var pdf: URL?
    @State private var png: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Größe", selection: $style) {
                        ForEach(LabelStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(style.detail).font(.caption).foregroundStyle(.secondary)

                    if let first = labels.first, let image = LabelRenderer.preview(first, style: style) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxWidth: 360)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.5)))
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Vorschau des Etiketts \(first.code) \(first.name)")
                        if labels.count > 1 { Text("+ \(labels.count - 1) weitere Etiketten in der PDF").font(.caption).foregroundStyle(.secondary) }
                    }

                    if let pdf {
                        BigButton("Drucken (AirPrint)", systemImage: "printer") {
                            LabelRenderer.printPDF(pdf, jobName: "Ordnungsplaner-Etiketten")
                        }
                        ShareLink(item: pdf) { Label("PDF teilen oder in Druck-App öffnen", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered).controlSize(.large)
                    }
                    if let png, labels.count == 1 {
                        ShareLink(item: png) { Label("Als Bild teilen (für Etiketten-Apps)", systemImage: "photo").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered).controlSize(.large)
                    }
                    Text("Der Ordnungsplaner kann keine Etikettendrucker direkt ansteuern. Teile die Datei mit der App deines Druckers (z. B. Brother, Niimbot, Phomemo) oder drucke über AirPrint. Den QR-Code kannst du auch mit der normalen iPhone-Kamera scannen, er öffnet dann den Ort in der App.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle(labels.count == 1 ? "Etikett" : "Etiketten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .task {
                labels = blankCodes.isEmpty
                    ? LabelRenderer.contents(for: placeIDs, model: model)
                    : blankCodes.map { LabelContent(code: $0, name: "Noch frei", path: "Scannen und zuordnen",
                                                    link: PlaceLink.codeURL(for: $0).absoluteString) }
                rebuild()
            }
            .onChange(of: style) { _, _ in rebuild() }
        }
    }

    private func rebuild() {
        pdf = LabelRenderer.pdf(labels, style: style, name: labels.count == 1 ? "Etikett-\(labels[0].code)" : "Etiketten")
        png = labels.count == 1 ? LabelRenderer.png(labels[0], style: style, name: "Etikett-\(labels[0].code)") : nil
    }
}
