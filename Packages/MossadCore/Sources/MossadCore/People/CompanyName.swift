import Foundation

/// A quiet guess at where someone outside the company works, from their email: "Acme" for dana@mail.acme.co.uk.
/// Public mail services say nothing about an employer, so they give no company.
public enum CompanyName {
    static let publicMail: Set<String> = [
        "gmail", "googlemail", "outlook", "hotmail", "live", "msn", "icloud", "me", "mac", "yahoo", "ymail",
        "aol", "proton", "protonmail", "pm", "gmx", "mail", "zoho", "fastmail", "hey", "yandex", "comcast",
    ]

    /// Second-level labels that sit under a country code as part of the public suffix (co.uk, com.au).
    static let secondLevel: Set<String> = ["co", "com", "net", "org", "gov", "ac", "edu", "ne", "or", "go"]

    public static func from(email: String?) -> String? {
        guard let email, let at = email.lastIndex(of: "@") else { return nil }
        let labels = email[email.index(after: at)...].lowercased().split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        var suffix = 1
        if labels.count >= 3, labels.last!.count == 2, secondLevel.contains(labels[labels.count - 2]) { suffix = 2 }
        let name = labels[labels.count - suffix - 1]
        guard !name.isEmpty, !publicMail.contains(name) else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
