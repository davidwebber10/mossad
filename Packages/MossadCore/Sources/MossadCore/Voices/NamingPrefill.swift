import Foundation

/// What the naming popover's email field holds when it opens.
public enum NamingPrefill {
    /// The person's first address. A name from the invite gets none: the invite's address, and any other address of
    /// that person, is not proof of whoever the voice is.
    public static func email(fromInvite: Bool, addresses: [String]) -> String {
        fromInvite ? "" : addresses.first ?? ""
    }
}
