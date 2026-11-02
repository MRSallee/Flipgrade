import Foundation
import ImageIO

enum PhotoCaptureDate {
    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    /// Prefer EXIF DateTimeOriginal; fall back to file creation / modification.
    static func date(for url: URL) -> Date? {
        if let exif = exifDate(for: url) { return exif }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }

    static func displayString(for url: URL) -> String? {
        guard let date = date(for: url) else { return nil }
        return displayFormatter.string(from: date)
    }

    private static func exifDate(for url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let raw = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
        if let raw, let parsed = exifFormatter.date(from: raw) {
            return parsed
        }

        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let raw = tiff[kCGImagePropertyTIFFDateTime] as? String,
           let parsed = exifFormatter.date(from: raw) {
            return parsed
        }
        return nil
    }
}
