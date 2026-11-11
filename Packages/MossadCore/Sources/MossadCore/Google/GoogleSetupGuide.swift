import Foundation

/// The steps in Google Cloud that make the owner's own Google app, as setup and Settings both show them: each with
/// its direct console link and the values to copy. Pure words, so both places say the same.
public enum GoogleSetupGuide {
    /// Who can use the app: a Workspace account makes it Internal; a Gmail account makes it External.
    public enum Audience: String, CaseIterable, Sendable {
        case `internal`, external

        public var title: String { self == .internal ? "Google Workspace (Internal)" : "Gmail (External)" }

        public var detail: String {
            switch self {
            case .internal:
                "Choose Internal. Only accounts of your organization can sign in, and Google asks for no review."
            case .external:
                "Choose External, then press Publish app so that the status is \"In production\". In Testing, Google ends the sign-in after 7 days. Google then shows \"Google hasn't verified this app\": choose Advanced, then Go to Mossad. Only you use this app."
            }
        }
    }

    public struct Link: Equatable, Sendable {
        public var title: String
        public var url: URL
    }

    public struct Copy: Equatable, Sendable {
        public var label: String
        public var value: String
    }

    public struct Step: Equatable, Sendable, Identifiable {
        public var id: Int { number }
        public var number: Int
        public var title: String
        public var detail: String
        public var links: [Link]
        public var copies: [Copy]
    }

    static func url(_ path: String) -> URL { URL(string: "https://console.cloud.google.com/\(path)")! }

    public static func steps(audience: Audience, scopes: Set<GoogleScope> = Set(GoogleScope.allCases)) -> [Step] {
        let apis = GoogleAPI.allCases.filter { api in scopes.contains { $0.api == api } }
        return [
            Step(number: 1, title: "Make a project",
                 detail: "Sign in to Google Cloud with the account that has your calendar. Make a new project named Mossad, or pick one you have.",
                 links: [Link(title: "New project", url: url("projectcreate"))], copies: [Copy(label: "Project name", value: "Mossad")]),
            Step(number: 2, title: "Turn on the APIs",
                 detail: "Open each page and press Enable. Check that the project at the top is the one from step 1.",
                 links: apis.map { Link(title: $0.name, url: $0.library) }, copies: []),
            Step(number: 3, title: "Set up the sign-in screen",
                 detail: "On Branding, press Get started. Type the app name and your email. On Audience: \(audience.detail)",
                 links: [Link(title: "Branding", url: url("auth/branding")), Link(title: "Audience", url: url("auth/audience"))],
                 copies: [Copy(label: "App name", value: "Mossad")]),
            Step(number: 4, title: "Add the permissions",
                 detail: "On Data access, press Add or remove scopes. Paste these lines in \"Manually add scopes\", press Add to table, then Update and Save. Each one only reads.",
                 links: [Link(title: "Data access", url: url("auth/scopes"))],
                 copies: GoogleScope.allCases.filter(scopes.contains).map { Copy(label: $0.title, value: $0.url) }),
            Step(number: 5, title: "Make the client",
                 detail: "On Clients, press Create client. For Application type, choose Desktop app. Name it Mossad and press Create. Copy the client ID and the client secret into the fields below.",
                 links: [Link(title: "Create client", url: url("auth/clients/create"))],
                 copies: [Copy(label: "Application type", value: "Desktop app"), Copy(label: "Name", value: "Mossad")]),
        ]
    }
}
