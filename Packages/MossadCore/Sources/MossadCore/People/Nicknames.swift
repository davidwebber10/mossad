import Foundation

/// Common English short forms, so "Ben" in the voice library finds "Benjamin" in the HR file and the reverse.
enum Nicknames {
    private static let groups: [[String]] = [
        ["ben", "benjamin", "benny"], ["zach", "zack", "zachary"], ["jim", "jimmy", "james", "jamie"],
        ["bill", "billy", "will", "willy", "william"], ["bob", "bobby", "rob", "robbie", "robert"],
        ["mike", "mikey", "michael"], ["matt", "matthew"], ["chris", "christopher", "christoper"],
        ["kate", "katie", "kathy", "katherine", "catherine", "kathryn"], ["dave", "davy", "david"],
        ["dan", "danny", "daniel"], ["tom", "tommy", "thomas"], ["joe", "joey", "joseph"],
        ["tony", "anthony"], ["steve", "steven", "stephen"], ["nick", "nicholas"], ["alex", "alexander", "alexandra", "alexandria"],
        ["andy", "drew", "andrew"], ["jen", "jenny", "jennifer"], ["liz", "beth", "lizzy", "elizabeth"],
        ["sam", "samuel", "samantha"], ["ted", "teddy", "theodore", "edward", "ed", "eddie"], ["rick", "ricky", "richard", "rich", "dick"],
        ["pat", "patrick", "patricia"], ["tim", "timothy"], ["ken", "kenny", "kenneth"], ["greg", "gregory"],
        ["jeff", "jeffrey", "geoff", "geoffrey"], ["josh", "joshua"], ["jon", "jonathan", "john", "johnny"],
        ["pete", "peter"], ["phil", "philip", "phillip"], ["ron", "ronnie", "ronald"], ["larry", "lawrence"],
        ["sue", "susan", "suzanne"], ["debbie", "deb", "deborah", "debra"], ["becky", "rebecca"], ["abby", "abigail"],
        ["maggie", "meg", "margaret"], ["terry", "terrence", "terence"], ["charlie", "chuck", "charles"],
        ["fred", "freddie", "frederick"], ["gerry", "jerry", "gerald", "jerome"], ["hank", "henry"], ["jack", "jackson"],
        ["vicky", "vicki", "victoria"], ["cathy", "cat"], ["nate", "nathan", "nathaniel"], ["sandy", "sandra"],
        ["don", "donny", "donald"], ["doug", "douglas"], ["walt", "walter"], ["zoe", "zoey"], ["ally", "allie", "allison", "alison"],
    ]

    private static let index: [String: Set<Int>] = {
        var out: [String: Set<Int>] = [:]
        for (i, g) in groups.enumerated() { for n in g { out[n, default: []].insert(i) } }
        return out
    }()

    /// The other forms of a lowercase first name: "mike" gives "michael" and "mikey".
    static func variants(of name: String) -> Set<String> {
        guard let ids = index[name] else { return [] }
        return Set(ids.flatMap { groups[$0] }).subtracting([name])
    }

    /// The full names of the groups. Two of them in one group are two different names: Samuel and Samantha both
    /// shorten to Sam, and are not one person.
    private static let fullNames: Set<String> = [
        "benjamin", "zachary", "james", "william", "robert", "michael", "matthew", "christopher", "christoper", "katherine", "catherine",
        "kathryn", "david", "daniel", "thomas", "joseph", "anthony", "steven", "stephen", "nicholas", "alexander", "alexandra", "alexandria",
        "andrew", "jennifer", "elizabeth", "samuel", "samantha", "theodore", "edward", "richard", "patrick", "patricia", "timothy", "kenneth",
        "gregory", "jeffrey", "geoffrey", "joshua", "jonathan", "john", "peter", "philip", "phillip", "ronald", "lawrence", "susan", "suzanne",
        "deborah", "debra", "rebecca", "abigail", "margaret", "terrence", "terence", "charles", "frederick", "gerald", "jerome", "henry",
        "jackson", "victoria", "nathan", "nathaniel", "sandra", "donald", "douglas", "walter", "allison", "alison",
    ]

    /// Whether one lowercase first name is the short form of the other: "sam" and "samuel". Two full names of one
    /// group ("samuel", "samantha") and two short forms ("bill", "will") are not: they can be two people.
    static func shortAndFull(_ a: String, _ b: String) -> Bool {
        related(a, b) && fullNames.contains(a) != fullNames.contains(b)
    }

    /// Whether two lowercase first names are short forms of one another. Equal names are not "nicknames".
    static func related(_ a: String, _ b: String) -> Bool {
        guard a != b, let x = index[a], let y = index[b] else { return false }
        return !x.isDisjoint(with: y)
    }
}
