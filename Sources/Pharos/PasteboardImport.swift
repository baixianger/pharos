import AppKit
import Foundation

/// Turns whatever is on the pasteboard into file URLs ready to attach to an
/// issue. Real file URLs pass through; image / PDF / RTF / plain-text content is
/// written to a temp file with an appropriate extension. Callers should delete
/// any returned URL that lives under the temp directory once they've copied it.
enum PasteboardImport {
    static func fileURLs(from pb: NSPasteboard = .general) -> [URL] {
        // 1. Real files dragged/copied from Finder.
        if let objs = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let files = objs.filter { $0.isFileURL }
            if !files.isEmpty { return files }
        }

        let tmp = FileManager.default.temporaryDirectory
        func write(_ data: Data, _ ext: String) -> URL? {
            let url = tmp.appendingPathComponent("pasted-\(UUID().uuidString).\(ext)")
            return (try? data.write(to: url)) == nil ? nil : url
        }

        // 2. Image (screenshot, copied picture …) → PNG.
        if let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]),
           let url = write(png, "png") {
            return [url]
        }
        // 3. PDF.
        if let pdf = pb.data(forType: .pdf), let url = write(pdf, "pdf") { return [url] }
        // 4. Rich text.
        if let rtf = pb.data(forType: .rtf), let url = write(rtf, "rtf") { return [url] }
        // 5. Plain text (also catches a copied web URL string).
        if let text = pb.string(forType: .string), !text.isEmpty,
           let url = write(Data(text.utf8), "txt") {
            return [url]
        }
        return []
    }

    /// True if `url` is one of our temp files (safe to delete after copying).
    static func isTemp(_ url: URL) -> Bool {
        url.path.hasPrefix(FileManager.default.temporaryDirectory.path)
    }
}
