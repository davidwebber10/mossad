import Foundation

/// The one check of each id and token of a move that goes into a path. The ledger is this profile's own file, and the
/// marker is a file that another process wrote: a value of either is used in a path only when it is one plain
/// component that a call id, a profile id, a chat id, or a token can be.
public enum MovePaths {
    public static let maxLength = 128
    /// The name a value that fails the check maps to: hidden, so no listing takes it, and never made.
    static let notAnID = ".not-an-id"

    public struct Invalid: Error {}
    private static let idCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    private static let tokenCharacters = CharacterSet(charactersIn: "0123456789abcdef")

    /// A call id ("20261101-100000", "20261101-100000-moved"), a final id, a profile id, or a chat id: not empty, at most
    /// 128 characters, letters, digits, "-" and "_" only, so never "/", ".", "..", or a hidden name.
    public static func isID(_ s: String) -> Bool {
        !s.isEmpty && s.count <= maxLength && s.unicodeScalars.allSatisfy(idCharacters.contains)
    }

    /// A move's token: lowercase hex, at most 128 characters.
    public static func isToken(_ s: String) -> Bool {
        !s.isEmpty && s.count <= maxLength && s.unicodeScalars.allSatisfy(tokenCharacters.contains)
    }
}
