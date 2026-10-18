import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins
import OrderCore

/// A printer set-up: what paper or label the printer takes and how big things are printed.
/// Printers differ, so the output is a PDF/PNG at the profile's physical size, which AirPrint
/// or the printer's own app then puts on the paper.
struct PrinterProfile: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case label, receipt, sheet
        var id: String { rawValue }
        var title: String {
            switch self {
            case .label: return "Etikettendrucker"
            case .receipt: return "Bon-/Thermodrucker"
            case .sheet: return "Normaler Drucker (A4-Bogen)"
            }
        }
        var systemImage: String {
            switch self {
            case .label: return "tag"
            case .receipt: return "receipt"
            case .sheet: return "doc"
            }
        }
    }

    var id = UUID()
    var name: String
    var kind: Kind
    /// Label width (label, sheet) or paper width (receipt), in millimetres.
    var widthMM: Double
    /// Label height; 0 means "as long as needed" (receipt rolls).
    var heightMM: Double
    var fontScale: Double = 1
    var qrMM: Double
    var marginMM: Double = 2
    var landscape = false

    static let pointsPerMM = 72.0 / 25.4

    /// The label cell in points (turned when landscape). Height 0 = automatic.
    var cellSize: CGSize {
        let w = widthMM * Self.pointsPerMM, h = heightMM * Self.pointsPerMM
        return landscape && h > 0 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    static let defaults: [PrinterProfile] = [
        PrinterProfile(name: "Schmaler Etikettendrucker", kind: .label, widthMM: 50, heightMM: 25, qrMM: 20, marginMM: 1.5),
        PrinterProfile(name: "Bon-Drucker (58 mm)", kind: .receipt, widthMM: 58, heightMM: 0, qrMM: 32, marginMM: 3),
        PrinterProfile(name: "Normaler Drucker (A4)", kind: .sheet, widthMM: 70, heightMM: 36, qrMM: 24, marginMM: 3)
    ]
}

enum PrinterProfiles {
    private static let listKey = "printerProfiles"
    private static let activeKey = "activePrinterProfile"

    static func load() -> [PrinterProfile] {
        if let data = UserDefaults.standard.data(forKey: listKey),
           let list = try? JSONDecoder().decode([PrinterProfile].self, from: data), !list.isEmpty { return list }
        return PrinterProfile.defaults
    }

    static func save(_ list: [PrinterProfile]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: listKey) }
    }

    static func activeID(for kind: PrinterProfile.Kind?) -> UUID? {
        UserDefaults.standard.string(forKey: activeKey + (kind?.rawValue ?? "")).flatMap(UUID.init(uuidString:))
    }

    static func setActive(_ id: UUID, for kind: PrinterProfile.Kind?) {
        UserDefaults.standard.set(id.uuidString, forKey: activeKey + (kind?.rawValue ?? ""))
    }

    /// The profile last used for this kind of output, else the first of its kind.
    static func preferred(kind: PrinterProfile.Kind?, in list: [PrinterProfile]) -> PrinterProfile? {
        let candidates = kind == nil ? list : list.filter { $0.kind == kind }
        if let id = activeID(for: kind), let found = candidates.first(where: { $0.id == id }) { return found }
        return candidates.first ?? list.first
    }
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

/// What gets printed for one place: code, name, type, room, path and the QR code of its link.
struct LabelContent {
    let code: String
    let name: String
    let path: String
    let link: String
    var roomName = ""
    var typeName = ""
}

struct LabelView: View {
    let content: LabelContent
    let profile: PrinterProfile

    private var horizontal: Bool { profile.heightMM > 0 && profile.widthMM / max(profile.heightMM, 1) >= 1.6 && !profile.landscape }

    var body: some View {
        let s = profile.fontScale
        let qrSide = profile.qrMM * PrinterProfile.pointsPerMM
        let cell = profile.cellSize
        let qr = QRCode.image(for: content.link)
        Group {
            if horizontal {
                HStack(spacing: 5) {
                    qrImage(qr).frame(width: qrSide, height: qrSide)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(content.code).font(.system(size: 17 * s, weight: .bold, design: .monospaced))
                        Text(content.name).font(.system(size: 9.5 * s, weight: .semibold)).lineLimit(2)
                        if !content.typeName.isEmpty { Text(content.typeName).font(.system(size: 7.5 * s)) }
                        Text(content.path).font(.system(size: 6.5 * s)).lineLimit(3).foregroundStyle(Color.black.opacity(0.7))
                    }
                    Spacer(minLength: 0)
                }
            } else {
                VStack(spacing: 3 * s) {
                    if !content.roomName.isEmpty {
                        Text(content.roomName.uppercased()).font(.system(size: 8 * s, weight: .semibold)).tracking(0.5)
                    }
                    Text(content.code).font(.system(size: 20 * s, weight: .bold, design: .monospaced))
                    Text(content.name).font(.system(size: 11 * s, weight: .semibold)).multilineTextAlignment(.center)
                    if !content.typeName.isEmpty { Text(content.typeName).font(.system(size: 8 * s)) }
                    qrImage(qr).frame(width: qrSide, height: qrSide)
                    Text("Standort:").font(.system(size: 7 * s, weight: .semibold))
                    Text(content.path).font(.system(size: 8 * s)).multilineTextAlignment(.center)
                        .foregroundStyle(Color.black.opacity(0.75))
                }
            }
        }
        .foregroundStyle(Color.black)
        .padding(profile.marginMM * PrinterProfile.pointsPerMM)
        .frame(width: cell.width, height: cell.height > 0 ? cell.height : nil)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private func qrImage(_ image: UIImage?) -> some View {
        Group {
            if let image { Image(uiImage: image).interpolation(.none).resizable().scaledToFit() }
            else { Image(systemName: "qrcode").resizable().scaledToFit() }
        }
    }
}

/// The "Tagesbon": a short to-do list for today, independent of the inventory.
struct SlipView: View {
    let title: String
    let date: String
    let lines: [String]
    let profile: PrinterProfile

    var body: some View {
        let s = profile.fontScale
        VStack(alignment: .leading, spacing: 5 * s) {
            Text(title).font(.system(size: 20 * s, weight: .bold, design: .monospaced))
            Text(date).font(.system(size: 8 * s)).foregroundStyle(Color.black.opacity(0.7))
            Divider().overlay(Color.black)
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: 4) {
                    Text("\(index + 1).").font(.system(size: 11 * s, weight: .bold, design: .monospaced))
                    Text(line).font(.system(size: 11 * s))
                    Spacer(minLength: 0)
                }
            }
            if lines.isEmpty { Text("Nichts geplant.").font(.system(size: 10 * s)) }
            Divider().overlay(Color.black)
            Text("Ordnungsplaner").font(.system(size: 6.5 * s)).foregroundStyle(Color.black.opacity(0.6))
        }
        .foregroundStyle(Color.black)
        .padding(profile.marginMM * PrinterProfile.pointsPerMM)
        .frame(width: profile.widthMM * PrinterProfile.pointsPerMM, alignment: .leading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
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
                                link: PlaceLink.url(for: id).absoluteString,
                                roomName: model.state.rooms.first { $0.id == place.roomID }?.name ?? "",
                                typeName: place.displayType)
        }
    }

    /// PDF pages: one label per page (label/receipt) or a grid of labels on A4 sheets.
    static func pdf<Content: View>(_ items: [Content], profile: PrinterProfile, name: String) -> URL? {
        guard !items.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).pdf")
        guard let context = CGContext(url as CFURL, mediaBox: nil, nil) else { return nil }

        func beginPage(_ size: CGSize) {
            var box = CGRect(origin: .zero, size: size)
            let info = [kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(info)
        }

        if profile.kind == .sheet {
            let page = profile.landscape ? CGSize(width: 841.9, height: 595.3) : CGSize(width: 595.3, height: 841.9)
            let margin = 10 * PrinterProfile.pointsPerMM
            let cell = CGSize(width: profile.widthMM * PrinterProfile.pointsPerMM, height: max(profile.heightMM, 10) * PrinterProfile.pointsPerMM)
            let columns = max(1, Int((page.width - 2 * margin) / cell.width))
            let rows = max(1, Int((page.height - 2 * margin) / cell.height))
            var index = 0
            while index < items.count {
                beginPage(page)
                for slot in 0..<(columns * rows) where index < items.count {
                    let column = slot % columns, row = slot / columns
                    let renderer = ImageRenderer(content: items[index])
                    renderer.render { size, draw in
                        context.saveGState()
                        context.translateBy(x: margin + CGFloat(column) * cell.width, y: page.height - margin - CGFloat(row + 1) * cell.height)
                        draw(context)
                        context.restoreGState()
                    }
                    index += 1
                }
                context.endPDFPage()
            }
        } else {
            for item in items {
                let renderer = ImageRenderer(content: item)
                renderer.render { size, draw in
                    beginPage(size)
                    draw(context)
                    context.endPDFPage()
                }
            }
        }
        context.closePDF()
        return url
    }

    static func labelsPDF(_ labels: [LabelContent], profile: PrinterProfile, name: String) -> URL? {
        pdf(labels.map { LabelView(content: $0, profile: profile) }, profile: profile, name: name)
    }

    /// A sharp PNG (about 8x the point size) for printer apps that take images.
    static func png<Content: View>(_ content: Content, name: String) -> URL? {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 8
        guard let data = renderer.uiImage?.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }

    static func preview<Content: View>(_ content: Content) -> UIImage? {
        let renderer = ImageRenderer(content: content)
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

/// Profile choice, preview, AirPrint and sharing – for a label, several labels, or a slip.
struct PrintPanel<Content: View>: View {
    let kinds: [PrinterProfile.Kind]
    let jobName: String
    let makeItems: (PrinterProfile) -> [Content]
    @State private var profiles = PrinterProfiles.load()
    @State private var profileID: UUID?
    @State private var pdf: URL?
    @State private var png: URL?
    @State private var preview: UIImage?
    @State private var count = 0
    @State private var editing = false

    private var profile: PrinterProfile? {
        profiles.first { $0.id == profileID } ?? PrinterProfiles.preferred(kind: kinds.first, in: profiles.filter { kinds.contains($0.kind) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let usable = profiles.filter { kinds.contains($0.kind) }
            if let profile {
                Picker("Druckerprofil", selection: Binding(get: { profile.id }, set: { profileID = $0; PrinterProfiles.setActive($0, for: kinds.first); rebuild() })) {
                    ForEach(usable) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu)
                Text("\(profile.kind.title): \(Int(profile.widthMM)) mm breit\(profile.heightMM > 0 ? ", \(Int(profile.heightMM)) mm hoch" : ", Länge automatisch")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let preview {
                Image(uiImage: preview).resizable().scaledToFit().frame(maxWidth: 340)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.5)))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Druckvorschau")
                if count > 1 { Text("+ \(count - 1) weitere in der PDF").font(.caption).foregroundStyle(.secondary) }
            }
            if let pdf {
                BigButton("Drucken (AirPrint)", systemImage: "printer") { LabelRenderer.printPDF(pdf, jobName: jobName) }
                ShareLink(item: pdf) { Label("PDF teilen oder in Druck-App öffnen", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
            }
            if let png, count == 1 {
                ShareLink(item: png) { Label("Als Bild teilen (für Etiketten-Apps)", systemImage: "photo").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
            }
            Button("Druckerprofile bearbeiten", systemImage: "slider.horizontal.3") { editing = true }
                .buttonStyle(.bordered)
            Text("Der Ordnungsplaner kann Etiketten- und Bon-Drucker nicht direkt ansteuern. Teile die Datei mit der App deines Druckers (z. B. Brother, Niimbot, Phomemo) oder drucke über AirPrint.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { rebuild() }
        .sheet(isPresented: $editing, onDismiss: { profiles = PrinterProfiles.load(); rebuild() }) { NavigationStack { PrinterProfilesView(asSheet: true) } }
    }

    private func rebuild() {
        guard let profile else { return }
        let items = makeItems(profile)
        count = items.count
        pdf = LabelRenderer.pdf(items, profile: profile, name: jobName.replacingOccurrences(of: " ", with: "-"))
        preview = items.first.flatMap { LabelRenderer.preview($0) }
        png = items.count == 1 ? LabelRenderer.png(items[0], name: jobName.replacingOccurrences(of: " ", with: "-")) : nil
    }
}

/// Labels for one place, several places, or blank labels printed in advance.
struct LabelSheet: View {
    let placeIDs: [UUID]
    /// Codes of blank labels printed in advance (no place yet).
    var blankCodes: [String] = []
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var labels: [LabelContent] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                PrintPanel(kinds: [.label, .receipt, .sheet], jobName: labels.count == 1 ? "Etikett \(labels[0].code)" : "Etiketten") { profile in
                    labels.map { LabelView(content: $0, profile: profile) }
                }
                .id(labels.count)
                .padding()
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(labels.count == 1 ? "Etikett" : "Etiketten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .task {
                labels = blankCodes.isEmpty
                    ? LabelRenderer.contents(for: placeIDs, model: model)
                    : blankCodes.map { LabelContent(code: $0, name: "Noch frei", path: "Scannen und zuordnen",
                                                    link: PlaceLink.codeURL(for: $0).absoluteString, typeName: "Etikett") }
            }
        }
    }
}
