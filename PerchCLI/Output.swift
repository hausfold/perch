import Foundation

/// The two things every verb in this tool does with a result: say something on
/// stderr that isn't the answer, and turn a payload into the one JSON object
/// stdout carries.
///
/// Free functions rather than methods on `PerchTool` because `doctor` and
/// `skill` never open a transaction and never construct one — they are verbs of
/// the tool, not of the shelf, and the family standard's "data on stdout,
/// diagnostics on stderr, always" applies to them the same way.

/// Diagnostics. Never stdout: a `--json` caller pipes stdout into a parser, and
/// a warning printed there is a parse error.
func complain(_ message: String) {
    FileHandle.standardError.write(Data("perch: \(message)\n".utf8))
}

/// Sorted keys and pretty-printed, so two runs of the same verb diff cleanly.
func object(_ payload: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(
        withJSONObject: payload,
        options: [.prettyPrinted, .sortedKeys]
    ) else {
        return "{}"
    }
    return String(decoding: data, as: UTF8.self)
}
