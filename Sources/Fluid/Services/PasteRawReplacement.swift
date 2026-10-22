import Foundation

/// Finds the last AI-cleaned paste in the text before the cursor, so "Paste Raw
/// Instead" can select it and type the transcript over it.
nonisolated enum PasteRawReplacement {
    /// Where `delivered` sits at the end of `textBeforeCursor`, in UTF-16 units, or nil
    /// when the text before the cursor does not end with it. Whitespace after the paste
    /// is allowed and left out of the range, since apps and the formatter add or drop a
    /// final space or newline.
    static func rangeOfDelivery(in textBeforeCursor: String, delivered: String) -> NSRange? {
        let target = delivered.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        guard target.length > 0 else { return nil }
        let before = textBeforeCursor as NSString
        var end = before.length
        while end > 0, let scalar = Unicode.Scalar(before.character(at: end - 1)),
              CharacterSet.whitespacesAndNewlines.contains(scalar)
        {
            end -= 1
        }
        guard end >= target.length else { return nil }
        let range = NSRange(location: end - target.length, length: target.length)
        guard before.substring(with: range) == target as String else { return nil }
        return range
    }
}
