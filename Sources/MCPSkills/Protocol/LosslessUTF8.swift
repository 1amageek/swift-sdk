import Foundation

/// Lossless UTF-8 decoding for skill files.
///
/// A file is text only when decoding and re-encoding reproduces every byte,
/// including a byte order mark and CRLF line endings, so the digest computed
/// from the text equals the digest of the original bytes.
enum LosslessUTF8 {
    static func decode(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        return text.utf8.elementsEqual(data) ? text : nil
    }
}
