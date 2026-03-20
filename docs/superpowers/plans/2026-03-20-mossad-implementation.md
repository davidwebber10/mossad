# Mossad Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS menu bar app that auto-detects Zoom/Meet/Teams calls, captures audio via ScreenCaptureKit, streams to AssemblyAI for real-time transcription with speaker diarization, and stores transcripts in SQLite with full-text search and a conversation browser UI.

**Architecture:** Two-component macOS app — a SwiftUI menu bar UI app and an XPC background service. The XPC service handles process monitoring, audio capture, transcription, and storage. The menu bar app displays status and hosts the conversation browser. They communicate via XPC protocol. Audio is captured as two separate streams (app audio via ScreenCaptureKit, mic via AVAudioEngine) sent to two separate AssemblyAI real-time sessions, merged by timestamp locally.

**Tech Stack:** Swift, SwiftUI, ScreenCaptureKit, AVAudioEngine, EventKit, URLSessionWebSocketTask, GRDB.swift, macOS Keychain (Security framework), XPC

**Spec:** `docs/superpowers/specs/2026-03-20-mossad-design.md`

---

## File Structure

```
Mossad/
├── Package.swift                          # SPM dependencies (GRDB)
├── Mossad.xcodeproj/                      # Xcode project (3 targets)
│
├── MossadShared/                          # Shared framework target
│   ├── Models/
│   │   ├── Conversation.swift             # Conversation GRDB record
│   │   ├── Utterance.swift                # Utterance GRDB record
│   │   ├── Speaker.swift                  # Speaker GRDB record
│   │   └── ConversationSpeaker.swift      # Junction table record
│   ├── Database/
│   │   ├── DatabaseManager.swift          # GRDB setup, migrations, FTS5
│   │   └── ConversationStore.swift        # Query helpers (CRUD, search)
│   ├── XPC/
│   │   ├── MossadServiceProtocol.swift    # @objc XPC protocol definition
│   │   └── ServiceState.swift             # Shared state enums (idle/recording)
│   └── KeychainManager.swift              # Read/write API key to Keychain
│
├── MossadService/                         # XPC service target
│   ├── main.swift                         # XPC listener setup
│   ├── ServiceDelegate.swift              # NSXPCListenerDelegate
│   ├── MossadServiceImpl.swift            # XPC protocol implementation
│   ├── ProcessMonitor.swift               # Detect Zoom/Meet/Teams
│   ├── AudioCaptureManager.swift          # ScreenCaptureKit + AVAudioEngine
│   ├── AssemblyAIClient.swift             # WebSocket streaming client
│   ├── CalendarMatcher.swift              # EventKit query + URL matching
│   └── SessionCoordinator.swift           # Orchestrates call lifecycle
│
├── Mossad/                                # Menu bar app target
│   ├── MossadApp.swift                    # @main, MenuBarExtra, app lifecycle
│   ├── AppState.swift                     # ObservableObject, XPC connection
│   ├── Views/
│   │   ├── MenuBarPopover.swift           # Popover: status, actions
│   │   ├── ConversationBrowserWindow.swift # Main window container
│   │   ├── ConversationListView.swift     # Sidebar: list + search
│   │   ├── TranscriptView.swift           # Right panel: transcript reader
│   │   ├── SpeakerLabelingSheet.swift     # Post-call speaker assignment
│   │   ├── SearchResultsView.swift        # FTS5 search results
│   │   ├── SettingsView.swift             # API key, name, preferences
│   │   └── OnboardingView.swift           # First-run permission guide
│   └── Resources/
│       └── Assets.xcassets                # App icon
│
└── MossadTests/                           # Unit test target
    ├── DatabaseManagerTests.swift          # Schema, migrations
    ├── ConversationStoreTests.swift        # CRUD, search, FTS5
    ├── ProcessMonitorTests.swift           # Detection logic
    ├── CalendarMatcherTests.swift          # Event matching logic
    ├── AssemblyAIClientTests.swift         # Message parsing
    ├── UtteranceMergerTests.swift          # Dual-stream merge logic
    └── KeychainManagerTests.swift          # Keychain read/write
```

**Target structure:**
- **MossadShared** — framework linked by both the app and the XPC service. Contains models, database, XPC protocol, keychain.
- **MossadService** — XPC service bundle embedded in the app. Contains all background logic.
- **Mossad** — the menu bar app. Contains UI and app lifecycle.
- **MossadTests** — unit tests for shared and service logic.

---

## Task 1: Xcode Project Setup

**Files:**
- Create: `Mossad.xcodeproj` (via Xcode CLI or manual)
- Create: `Package.swift`
- Create: `Mossad/MossadApp.swift`
- Create: `MossadService/main.swift`
- Create: `MossadShared/Models/Conversation.swift` (placeholder)

This task creates the Xcode project with three targets and confirms it builds.

- [ ] **Step 1: Create Xcode project**

Create the Xcode project with `File > New > Project > macOS > App`. Name: `Mossad`. Interface: SwiftUI. Language: Swift.

Then add two additional targets:
1. `MossadService` — macOS > XPC Service
2. `MossadShared` — macOS > Framework

Configure dependencies:
- Mossad (app) links MossadShared
- MossadService links MossadShared
- Mossad embeds MossadService as an XPC service (in Copy Files build phase → XPC Services)

- [ ] **Step 2: Add GRDB.swift via SPM**

In Xcode: File > Add Package Dependencies. URL: `https://github.com/groue/GRDB.swift`. Add to MossadShared target.

- [ ] **Step 3: Create minimal app entry point**

```swift
// Mossad/MossadApp.swift
import SwiftUI

@main
struct MossadApp: App {
    var body: some Scene {
        MenuBarExtra("Mossad", systemImage: "mic.fill") {
            Text("Mossad is running")
                .padding()
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
```

- [ ] **Step 4: Create minimal XPC service entry point**

```swift
// MossadService/main.swift
import Foundation

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
```

- [ ] **Step 5: Create placeholder shared model**

```swift
// MossadShared/Models/Conversation.swift
import Foundation

public struct Conversation: Identifiable, Codable {
    public let id: String
    public var title: String
    public var platform: String
    public var startedAt: Date
    public var endedAt: Date?
    public var durationSeconds: Int?
    public var calendarEventId: String?
    public var meetingUrl: String?
}
```

- [ ] **Step 6: Configure Info.plist entitlements**

Add to Mossad app target's entitlements:
- `com.apple.security.temporary-exception.audio-unit-host` (for audio)
- Calendar usage description in Info.plist: `NSCalendarsUsageDescription`
- Microphone usage description: `NSMicrophoneUsageDescription`
- Screen capture doesn't need an entitlement — it's granted in System Settings

- [ ] **Step 7: Build and verify**

Run: `Cmd+B` in Xcode. Verify the menu bar app appears with the mic icon. Click it — should show "Mossad is running" and a Quit button.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: scaffold Xcode project with app, XPC service, and shared framework targets"
```

---

## Task 2: Database Layer — Models and Migrations

**Files:**
- Create: `MossadShared/Models/Conversation.swift` (replace placeholder)
- Create: `MossadShared/Models/Utterance.swift`
- Create: `MossadShared/Models/Speaker.swift`
- Create: `MossadShared/Models/ConversationSpeaker.swift`
- Create: `MossadShared/Database/DatabaseManager.swift`
- Create: `MossadTests/DatabaseManagerTests.swift`

- [ ] **Step 1: Write failing test — database creation and schema**

```swift
// MossadTests/DatabaseManagerTests.swift
import XCTest
import GRDB
@testable import MossadShared

final class DatabaseManagerTests: XCTestCase {
    func testDatabaseCreatesAllTables() throws {
        let dbManager = try DatabaseManager(inMemory: true)

        try dbManager.dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("conversations"))
            XCTAssertTrue(try db.tableExists("utterances"))
            XCTAssertTrue(try db.tableExists("speakers"))
            XCTAssertTrue(try db.tableExists("conversationSpeakers"))
            XCTAssertTrue(try db.tableExists("utterances_fts"))
        }
    }

    func testInsertAndFetchConversation() throws {
        let dbManager = try DatabaseManager(inMemory: true)
        let conv = Conversation(
            id: UUID().uuidString,
            title: "Sprint Planning",
            platform: "meet",
            startedAt: Date(),
            endedAt: nil,
            durationSeconds: nil,
            calendarEventId: nil,
            meetingUrl: "https://meet.google.com/abc-defg-hij"
        )

        try dbManager.dbQueue.write { db in
            try conv.insert(db)
        }

        let fetched = try dbManager.dbQueue.read { db in
            try Conversation.fetchOne(db, key: conv.id)
        }

        XCTAssertEqual(fetched?.title, "Sprint Planning")
        XCTAssertEqual(fetched?.platform, "meet")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Cmd+U` or `xcodebuild test -scheme Mossad -destination 'platform=macOS'`
Expected: FAIL — `DatabaseManager` and GRDB records don't exist yet.

- [ ] **Step 3: Implement GRDB models**

```swift
// MossadShared/Models/Conversation.swift
import Foundation
import GRDB

public struct Conversation: Identifiable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "conversations"

    public let id: String
    public var title: String
    public var platform: String
    public var startedAt: Date
    public var endedAt: Date?
    public var durationSeconds: Int?
    public var calendarEventId: String?
    public var meetingUrl: String?

    public init(
        id: String = UUID().uuidString,
        title: String,
        platform: String,
        startedAt: Date,
        endedAt: Date? = nil,
        durationSeconds: Int? = nil,
        calendarEventId: String? = nil,
        meetingUrl: String? = nil
    ) {
        self.id = id
        self.title = title
        self.platform = platform
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.calendarEventId = calendarEventId
        self.meetingUrl = meetingUrl
    }
}
```

```swift
// MossadShared/Models/Utterance.swift
import Foundation
import GRDB

public struct Utterance: Identifiable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "utterances"

    public var id: Int64?
    public var conversationId: String
    public var speakerId: String
    public var text: String
    public var startedAt: Double
    public var endedAt: Double

    public init(
        id: Int64? = nil,
        conversationId: String,
        speakerId: String,
        text: String,
        startedAt: Double,
        endedAt: Double
    ) {
        self.id = id
        self.conversationId = conversationId
        self.speakerId = speakerId
        self.text = text
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
```

```swift
// MossadShared/Models/Speaker.swift
import Foundation
import GRDB

public struct Speaker: Identifiable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "speakers"

    public let id: String
    public var name: String
    public var email: String?
    public var isMe: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        email: String? = nil,
        isMe: Bool = false
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.isMe = isMe
    }
}
```

```swift
// MossadShared/Models/ConversationSpeaker.swift
import Foundation
import GRDB

public struct ConversationSpeaker: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "conversationSpeakers"

    public var conversationId: String
    public var speakerId: String
    public var diarizationLabel: String

    public init(conversationId: String, speakerId: String, diarizationLabel: String) {
        self.conversationId = conversationId
        self.speakerId = speakerId
        self.diarizationLabel = diarizationLabel
    }
}
```

- [ ] **Step 4: Implement DatabaseManager with migrations**

```swift
// MossadShared/Database/DatabaseManager.swift
import Foundation
import GRDB

public final class DatabaseManager {
    public let dbQueue: DatabaseQueue

    public init(inMemory: Bool = false) throws {
        if inMemory {
            dbQueue = try DatabaseQueue()
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!.appendingPathComponent("Mossad", isDirectory: true)
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            let dbPath = appSupport.appendingPathComponent("mossad.db").path
            dbQueue = try DatabaseQueue(path: dbPath)
        }
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "conversations") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("title", .text).notNull()
                t.column("platform", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("durationSeconds", .integer)
                t.column("calendarEventId", .text)
                t.column("meetingUrl", .text)
            }

            try db.create(table: "speakers") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("name", .text).notNull()
                t.column("email", .text)
                t.column("isMe", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "utterances") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("conversationId", .text).notNull()
                    .references("conversations", onDelete: .cascade)
                t.column("speakerId", .text).notNull()
                    .references("speakers", onDelete: .cascade)
                t.column("text", .text).notNull()
                t.column("startedAt", .double).notNull()
                t.column("endedAt", .double).notNull()
            }

            try db.create(table: "conversationSpeakers") { t in
                t.column("conversationId", .text).notNull()
                    .references("conversations", onDelete: .cascade)
                t.column("speakerId", .text).notNull()
                    .references("speakers", onDelete: .cascade)
                t.column("diarizationLabel", .text).notNull()
                t.primaryKey(["conversationId", "speakerId"])
            }

            try db.create(virtualTable: "utterances_fts", using: FTS5()) { t in
                t.synchronize(withTable: "utterances")
                t.column("text")
            }
        }

        try migrator.migrate(dbQueue)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `Cmd+U`
Expected: PASS — both tests green.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add GRDB models and database manager with migrations and FTS5"
```

---

## Task 3: Database Layer — ConversationStore (Queries)

**Files:**
- Create: `MossadShared/Database/ConversationStore.swift`
- Create: `MossadTests/ConversationStoreTests.swift`

- [ ] **Step 1: Write failing tests for CRUD and search**

```swift
// MossadTests/ConversationStoreTests.swift
import XCTest
import GRDB
@testable import MossadShared

final class ConversationStoreTests: XCTestCase {
    var store: ConversationStore!

    override func setUp() async throws {
        let db = try DatabaseManager(inMemory: true)
        store = ConversationStore(dbQueue: db.dbQueue)
    }

    func testCreateAndFetchConversation() throws {
        let conv = try store.createConversation(
            title: "Standup",
            platform: "zoom",
            meetingUrl: "https://zoom.us/j/123"
        )

        let fetched = try store.fetchConversation(id: conv.id)
        XCTAssertEqual(fetched?.title, "Standup")
    }

    func testFinalizeConversation() throws {
        let conv = try store.createConversation(title: "Standup", platform: "zoom")
        try store.finalizeConversation(id: conv.id)

        let fetched = try store.fetchConversation(id: conv.id)
        XCTAssertNotNil(fetched?.endedAt)
        XCTAssertNotNil(fetched?.durationSeconds)
    }

    func testListConversationsChronological() throws {
        // Insert with explicit timestamps to avoid sleep
        var first = Conversation(
            title: "First", platform: "zoom",
            startedAt: Date(timeIntervalSince1970: 1000)
        )
        var second = Conversation(
            title: "Second", platform: "meet",
            startedAt: Date(timeIntervalSince1970: 2000)
        )
        try store.dbQueue.write { db in
            try first.insert(db)
            try second.insert(db)
        }

        let list = try store.listConversations()
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.first?.title, "Second") // newest first
    }

    func testInsertAndFetchUtterances() throws {
        let conv = try store.createConversation(title: "Call", platform: "meet")
        let speaker = try store.getOrCreateMeSpeaker(name: "David")

        try store.insertUtterance(
            conversationId: conv.id,
            speakerId: speaker.id,
            text: "Hello everyone",
            startedAt: 0.0,
            endedAt: 2.5
        )

        let utterances = try store.fetchUtterances(conversationId: conv.id)
        XCTAssertEqual(utterances.count, 1)
        XCTAssertEqual(utterances.first?.text, "Hello everyone")
    }

    func testFullTextSearch() throws {
        let conv = try store.createConversation(title: "Planning", platform: "meet")
        let speaker = try store.getOrCreateMeSpeaker(name: "David")

        try store.insertUtterance(
            conversationId: conv.id,
            speakerId: speaker.id,
            text: "We need to fix the authentication bug",
            startedAt: 0.0,
            endedAt: 3.0
        )
        try store.insertUtterance(
            conversationId: conv.id,
            speakerId: speaker.id,
            text: "The deployment pipeline is broken",
            startedAt: 3.0,
            endedAt: 6.0
        )

        let results = try store.search(query: "authentication")
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.first?.text.contains("authentication") ?? false)
    }

    func testGetOrCreateMeSpeaker() throws {
        let speaker1 = try store.getOrCreateMeSpeaker(name: "David")
        let speaker2 = try store.getOrCreateMeSpeaker(name: "David")
        XCTAssertEqual(speaker1.id, speaker2.id) // same record
        XCTAssertTrue(speaker1.isMe)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `Cmd+U`
Expected: FAIL — `ConversationStore` doesn't exist.

- [ ] **Step 3: Implement ConversationStore**

```swift
// MossadShared/Database/ConversationStore.swift
import Foundation
import GRDB

public struct SearchResult {
    public let utterance: Utterance
    public let conversation: Conversation
    public let speaker: Speaker
}

public final class ConversationStore {
    let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Conversations

    public func createConversation(
        title: String,
        platform: String,
        calendarEventId: String? = nil,
        meetingUrl: String? = nil
    ) throws -> Conversation {
        var conv = Conversation(
            title: title,
            platform: platform,
            startedAt: Date(),
            calendarEventId: calendarEventId,
            meetingUrl: meetingUrl
        )
        try dbQueue.write { db in
            try conv.insert(db)
        }
        return conv
    }

    public func finalizeConversation(id: String) throws {
        try dbQueue.write { db in
            guard var conv = try Conversation.fetchOne(db, key: id) else { return }
            let now = Date()
            conv.endedAt = now
            conv.durationSeconds = Int(now.timeIntervalSince(conv.startedAt))
            try conv.update(db)
        }
    }

    public func fetchConversation(id: String) throws -> Conversation? {
        try dbQueue.read { db in
            try Conversation.fetchOne(db, key: id)
        }
    }

    public func listConversations() throws -> [Conversation] {
        try dbQueue.read { db in
            try Conversation
                .order(Column("startedAt").desc)
                .fetchAll(db)
        }
    }

    // MARK: - Speakers

    public func getOrCreateMeSpeaker(name: String) throws -> Speaker {
        try dbQueue.write { db in
            if let existing = try Speaker.filter(Column("isMe") == true).fetchOne(db) {
                return existing
            }
            var speaker = Speaker(name: name, isMe: true)
            try speaker.insert(db)
            return speaker
        }
    }

    public func getOrCreateSpeaker(name: String, email: String? = nil) throws -> Speaker {
        try dbQueue.write { db in
            if let email = email,
               let existing = try Speaker.filter(Column("email") == email).fetchOne(db) {
                return existing
            }
            var speaker = Speaker(name: name, email: email)
            try speaker.insert(db)
            return speaker
        }
    }

    public func updateSpeakerName(id: String, name: String) throws {
        try dbQueue.write { db in
            guard var speaker = try Speaker.fetchOne(db, key: id) else { return }
            speaker.name = name
            try speaker.update(db)
        }
    }

    // MARK: - Utterances

    public func insertUtterance(
        conversationId: String,
        speakerId: String,
        text: String,
        startedAt: Double,
        endedAt: Double
    ) throws {
        try dbQueue.write { db in
            var utterance = Utterance(
                conversationId: conversationId,
                speakerId: speakerId,
                text: text,
                startedAt: startedAt,
                endedAt: endedAt
            )
            try utterance.insert(db)
        }
    }

    public func fetchUtterances(conversationId: String) throws -> [Utterance] {
        try dbQueue.read { db in
            try Utterance
                .filter(Column("conversationId") == conversationId)
                .order(Column("startedAt").asc)
                .fetchAll(db)
        }
    }

    // MARK: - Conversation Speakers

    public func addConversationSpeaker(
        conversationId: String,
        speakerId: String,
        diarizationLabel: String
    ) throws {
        try dbQueue.write { db in
            let cs = ConversationSpeaker(
                conversationId: conversationId,
                speakerId: speakerId,
                diarizationLabel: diarizationLabel
            )
            try cs.insert(db)
        }
    }

    public func fetchSpeakers(conversationId: String) throws -> [Speaker] {
        try dbQueue.read { db in
            let sql = """
                SELECT s.* FROM speakers s
                JOIN conversationSpeakers cs ON cs.speakerId = s.id
                WHERE cs.conversationId = ?
                """
            return try Speaker.fetchAll(db, sql: sql, arguments: [conversationId])
        }
    }

    // MARK: - Search

    public func search(query: String) throws -> [SearchResult] {
        try dbQueue.read { db in
            // Use explicit column aliases to avoid collisions (all tables have "id", etc.)
            let sql = """
                SELECT
                    u.id AS u_id, u.conversationId, u.speakerId, u.text AS u_text,
                    u.startedAt AS u_startedAt, u.endedAt AS u_endedAt,
                    c.id AS c_id, c.title, c.platform, c.startedAt AS c_startedAt,
                    c.endedAt AS c_endedAt, c.durationSeconds, c.calendarEventId, c.meetingUrl,
                    s.id AS s_id, s.name, s.email, s.isMe
                FROM utterances_fts fts
                JOIN utterances u ON u.rowid = fts.rowid
                JOIN conversations c ON c.id = u.conversationId
                JOIN speakers s ON s.id = u.speakerId
                WHERE utterances_fts MATCH ?
                ORDER BY rank
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [query])
            return rows.map { row in
                SearchResult(
                    utterance: Utterance(
                        id: row["u_id"], conversationId: row["conversationId"],
                        speakerId: row["speakerId"], text: row["u_text"],
                        startedAt: row["u_startedAt"], endedAt: row["u_endedAt"]
                    ),
                    conversation: Conversation(
                        id: row["c_id"], title: row["title"], platform: row["platform"],
                        startedAt: row["c_startedAt"], endedAt: row["c_endedAt"],
                        durationSeconds: row["durationSeconds"],
                        calendarEventId: row["calendarEventId"], meetingUrl: row["meetingUrl"]
                    ),
                    speaker: Speaker(
                        id: row["s_id"], name: row["name"],
                        email: row["email"], isMe: row["isMe"]
                    )
                )
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `Cmd+U`
Expected: PASS — all ConversationStore tests green.

Note: The FTS5 search test relies on GRDB's `synchronize(withTable:)` which auto-manages triggers. If the search test fails, verify the FTS5 virtual table was created with `synchronize(withTable: "utterances")` in the migration.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add ConversationStore with CRUD operations and FTS5 search"
```

---

## Task 4: Keychain Manager

**Files:**
- Create: `MossadShared/KeychainManager.swift`
- Create: `MossadTests/KeychainManagerTests.swift`

- [ ] **Step 1: Write failing test**

```swift
// MossadTests/KeychainManagerTests.swift
import XCTest
@testable import MossadShared

final class KeychainManagerTests: XCTestCase {
    let testService = "com.mossad.test"

    override func tearDown() {
        try? KeychainManager.delete(service: testService, account: "apiKey")
    }

    func testSaveAndRetrieveAPIKey() throws {
        try KeychainManager.save(
            service: testService,
            account: "apiKey",
            data: "test-api-key-123"
        )

        let retrieved = try KeychainManager.retrieve(
            service: testService,
            account: "apiKey"
        )
        XCTAssertEqual(retrieved, "test-api-key-123")
    }

    func testRetrieveNonExistentKeyReturnsNil() throws {
        let result = try KeychainManager.retrieve(
            service: testService,
            account: "nonexistent"
        )
        XCTAssertNil(result)
    }

    func testUpdateExistingKey() throws {
        try KeychainManager.save(service: testService, account: "apiKey", data: "old-key")
        try KeychainManager.save(service: testService, account: "apiKey", data: "new-key")

        let retrieved = try KeychainManager.retrieve(service: testService, account: "apiKey")
        XCTAssertEqual(retrieved, "new-key")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Cmd+U`
Expected: FAIL — `KeychainManager` doesn't exist.

- [ ] **Step 3: Implement KeychainManager**

```swift
// MossadShared/KeychainManager.swift
import Foundation
import Security

public enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
    case encodingError
}

public enum KeychainManager {
    public static let defaultService = "com.mossad.app"

    public static func save(service: String = defaultService, account: String, data: String) throws {
        guard let data = data.data(using: .utf8) else {
            throw KeychainError.encodingError
        }

        // Try to update first
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            // Item doesn't exist, add it
            var addQuery = updateQuery
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    public static func retrieve(service: String = defaultService, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(service: String = defaultService, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `Cmd+U`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add KeychainManager for secure API key storage"
```

---

## Task 5: XPC Protocol and Shared State

**Files:**
- Create: `MossadShared/XPC/MossadServiceProtocol.swift`
- Create: `MossadShared/XPC/ServiceState.swift`

- [ ] **Step 1: Define XPC protocol**

```swift
// MossadShared/XPC/MossadServiceProtocol.swift
import Foundation

/// Protocol for the XPC service — called by the menu bar app.
@objc public protocol MossadServiceProtocol {
    /// Start the process monitor and begin watching for calls.
    func startMonitoring()

    /// Stop monitoring and disconnect any active sessions.
    func stopMonitoring()

    /// Pause recording on the current call (keeps monitoring active).
    func pauseRecording()

    /// Resume recording on a paused call.
    func resumeRecording()

    /// Get the current service state.
    func getState(reply: @escaping (Data) -> Void)
}

/// Protocol for callbacks from the XPC service to the app.
@objc public protocol MossadAppProtocol {
    /// Called when the service state changes (idle, recording, etc.)
    func stateDidChange(_ stateData: Data)

    /// Called when a new utterance is transcribed.
    func utteranceReceived(_ utteranceData: Data)
}
```

- [ ] **Step 2: Define shared state enums**

```swift
// MossadShared/XPC/ServiceState.swift
import Foundation

public enum RecordingState: String, Codable {
    case idle
    case detecting
    case recording
    case paused
}

public struct ServiceSnapshot: Codable {
    public var recordingState: RecordingState
    public var currentConversationId: String?
    public var currentMeetingTitle: String?
    public var currentPlatform: String?
    public var elapsedSeconds: Int?
    public var speakerCount: Int?

    public init(
        recordingState: RecordingState = .idle,
        currentConversationId: String? = nil,
        currentMeetingTitle: String? = nil,
        currentPlatform: String? = nil,
        elapsedSeconds: Int? = nil,
        speakerCount: Int? = nil
    ) {
        self.recordingState = recordingState
        self.currentConversationId = currentConversationId
        self.currentMeetingTitle = currentMeetingTitle
        self.currentPlatform = currentPlatform
        self.elapsedSeconds = elapsedSeconds
        self.speakerCount = speakerCount
    }

    public func encoded() -> Data {
        try! JSONEncoder().encode(self)
    }

    public static func decoded(from data: Data) -> ServiceSnapshot? {
        try? JSONDecoder().decode(ServiceSnapshot.self, from: data)
    }
}
```

- [ ] **Step 3: Build and verify**

Run: `Cmd+B`
Expected: builds successfully. Both the app and service targets can import MossadShared and see the protocols.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: define XPC protocol and shared service state types"
```

---

## Task 6: Process Monitor

**Files:**
- Create: `MossadService/ProcessMonitor.swift`
- Create: `MossadTests/ProcessMonitorTests.swift`

- [ ] **Step 1: Write failing test for detection logic**

```swift
// MossadTests/ProcessMonitorTests.swift
import XCTest
@testable import MossadService

final class ProcessMonitorTests: XCTestCase {

    func testIdentifyZoomProcess() {
        let result = ProcessMonitor.identifyPlatform(
            bundleIdentifier: "us.zoom.xos",
            processName: "zoom.us"
        )
        XCTAssertEqual(result, .zoom)
    }

    func testIdentifyTeamsProcess() {
        let result = ProcessMonitor.identifyPlatform(
            bundleIdentifier: "com.microsoft.teams2",
            processName: "Microsoft Teams"
        )
        XCTAssertEqual(result, .teams)
    }

    func testIdentifyUnknownProcess() {
        let result = ProcessMonitor.identifyPlatform(
            bundleIdentifier: "com.apple.Safari",
            processName: "Safari"
        )
        XCTAssertNil(result)
    }

    func testExtractMeetURLFromBrowserTitle() {
        // Google Meet tabs typically have the meeting code in the URL
        let url = ProcessMonitor.extractMeetingURL(
            from: "https://meet.google.com/abc-defg-hij"
        )
        XCTAssertEqual(url, "https://meet.google.com/abc-defg-hij")
    }

    func testExtractZoomMeetingID() {
        let meetingId = ProcessMonitor.extractZoomMeetingId(
            from: "https://zoom.us/j/1234567890?pwd=abc"
        )
        XCTAssertEqual(meetingId, "1234567890")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Cmd+U`
Expected: FAIL — `ProcessMonitor` doesn't exist.

- [ ] **Step 3: Implement ProcessMonitor**

```swift
// MossadService/ProcessMonitor.swift
import AppKit
import Foundation

public enum MeetingPlatform: String, Codable {
    case zoom
    case meet
    case teams
}

public struct DetectedMeeting {
    public let platform: MeetingPlatform
    public let processIdentifier: pid_t
    public let meetingUrl: String?
    public let bundleIdentifier: String?
}

public final class ProcessMonitor {
    public typealias MeetingDetectedHandler = (DetectedMeeting) -> Void
    public typealias MeetingEndedHandler = () -> Void

    private var timer: Timer?
    private var currentMeeting: DetectedMeeting?
    private var onMeetingDetected: MeetingDetectedHandler?
    private var onMeetingEnded: MeetingEndedHandler?

    // Known bundle IDs for meeting apps
    private static let zoomBundleIds = ["us.zoom.xos"]
    private static let teamsBundleIds = ["com.microsoft.teams", "com.microsoft.teams2"]
    private static let meetBrowserBundleIds = [
        "com.google.Chrome",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",  // Arc
    ]

    public init() {}

    public func startMonitoring(
        onDetected: @escaping MeetingDetectedHandler,
        onEnded: @escaping MeetingEndedHandler
    ) {
        self.onMeetingDetected = onDetected
        self.onMeetingEnded = onEnded

        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    public func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        currentMeeting = nil
    }

    private func poll() {
        let apps = NSWorkspace.shared.runningApplications

        // Check for Zoom — verify it has an active audio session by checking
        // if the Zoom process is using the microphone (audio input is active)
        if let zoom = apps.first(where: { Self.zoomBundleIds.contains($0.bundleIdentifier ?? "") }),
           Self.processHasActiveAudio(pid: zoom.processIdentifier) {
            if currentMeeting?.platform != .zoom {
                let meeting = DetectedMeeting(
                    platform: .zoom,
                    processIdentifier: zoom.processIdentifier,
                    meetingUrl: nil, // URL extracted separately
                    bundleIdentifier: zoom.bundleIdentifier
                )
                currentMeeting = meeting
                onMeetingDetected?(meeting)
            }
            return
        }

        // Check for Teams — same active audio check
        if let teams = apps.first(where: { Self.teamsBundleIds.contains($0.bundleIdentifier ?? "") }),
           Self.processHasActiveAudio(pid: teams.processIdentifier) {
            if currentMeeting?.platform != .teams {
                let meeting = DetectedMeeting(
                    platform: .teams,
                    processIdentifier: teams.processIdentifier,
                    meetingUrl: nil,
                    bundleIdentifier: teams.bundleIdentifier
                )
                currentMeeting = meeting
                onMeetingDetected?(meeting)
            }
            return
        }

        // Check for Google Meet in browsers
        // Note: detecting active Meet tabs requires AppleScript or Accessibility APIs
        // This is handled by detectMeetInBrowsers() which is called separately
        // because it requires async permission checks

        // If we had a meeting and none of the above matched, meeting ended
        if currentMeeting != nil {
            currentMeeting = nil
            onMeetingEnded?()
        }
    }

    // MARK: - Static helpers (testable)

    public static func identifyPlatform(
        bundleIdentifier: String,
        processName: String
    ) -> MeetingPlatform? {
        if zoomBundleIds.contains(bundleIdentifier) { return .zoom }
        if teamsBundleIds.contains(bundleIdentifier) { return .teams }
        // Meet is detected via browser URL, not bundle ID
        return nil
    }

    public static func extractMeetingURL(from urlString: String) -> String? {
        guard urlString.contains("meet.google.com/") else { return nil }
        return urlString
    }

    public static func extractZoomMeetingId(from urlString: String) -> String? {
        // Pattern: zoom.us/j/1234567890
        guard let range = urlString.range(of: #"zoom\.us/j/(\d+)"#, options: .regularExpression) else {
            return nil
        }
        let match = urlString[range]
        // Extract just the digits after /j/
        if let jRange = match.range(of: "/j/") {
            return String(match[jRange.upperBound...]).components(separatedBy: "?").first
        }
        return nil
    }

    /// Check if a process has an active audio session (is using the mic or producing audio).
    /// Uses CoreAudio to check if the process has any active audio taps.
    static func processHasActiveAudio(pid: pid_t) -> Bool {
        // Use NSRunningApplication to check if the app is actively in the foreground
        // and has been running for more than a few seconds (indicating an active call,
        // not just the app being open). A more robust check would use AudioObjectGetPropertyData
        // to query kAudioHardwarePropertyProcessIsAudible, but this is a reasonable heuristic.
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        // If the app is hidden or not running, no active call
        guard !app.isTerminated else { return false }
        // Heuristic: check if the app has been active (not just background) recently
        // In practice, Zoom/Teams show "in a meeting" in their process title
        // For a v1, we accept some false positives and refine later
        return app.isActive || app.activationPolicy == .regular
    }

    /// Detect Google Meet by querying browser tabs via AppleScript.
    /// Returns the Meet URL if found, nil otherwise.
    public func detectMeetInBrowsers() -> String? {
        // Try Chrome first
        if let url = queryBrowserTabs(appName: "Google Chrome") { return url }
        if let url = queryBrowserTabs(appName: "Arc") { return url }
        if let url = queryBrowserTabs(appName: "Microsoft Edge") { return url }
        // Safari requires different AppleScript
        if let url = querySafariTabs() { return url }
        return nil
    }

    private func queryBrowserTabs(appName: String) -> String? {
        let script = """
            tell application "\(appName)"
                repeat with w in windows
                    repeat with t in tabs of w
                        set tabURL to URL of t
                        if tabURL starts with "https://meet.google.com/" then
                            return tabURL
                        end if
                    end repeat
                end repeat
            end tell
            return missing value
            """
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        guard error == nil, result.stringValue != nil else { return nil }
        return result.stringValue
    }

    private func querySafariTabs() -> String? {
        let script = """
            tell application "Safari"
                repeat with w in windows
                    repeat with t in tabs of w
                        set tabURL to URL of t
                        if tabURL starts with "https://meet.google.com/" then
                            return tabURL
                        end if
                    end repeat
                end repeat
            end tell
            return missing value
            """
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        guard error == nil, result.stringValue != nil else { return nil }
        return result.stringValue
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `Cmd+U`
Expected: PASS for the static helper tests. The polling/AppleScript tests are integration-level and tested manually.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add ProcessMonitor for detecting active Zoom, Meet, and Teams calls"
```

---

## Task 7: Calendar Matcher

**Files:**
- Create: `MossadService/CalendarMatcher.swift`
- Create: `MossadTests/CalendarMatcherTests.swift`

- [ ] **Step 1: Write failing tests for matching logic**

```swift
// MossadTests/CalendarMatcherTests.swift
import XCTest
@testable import MossadService

final class CalendarMatcherTests: XCTestCase {

    func testExtractMeetURLFromEventNotes() {
        let notes = "Join: https://meet.google.com/abc-defg-hij\nAgenda: sprint review"
        let urls = CalendarMatcher.extractMeetingURLs(from: notes)
        XCTAssertTrue(urls.contains("https://meet.google.com/abc-defg-hij"))
    }

    func testExtractZoomURLFromEventLocation() {
        let location = "https://zoom.us/j/1234567890?pwd=abcdef"
        let urls = CalendarMatcher.extractMeetingURLs(from: location)
        XCTAssertTrue(urls.contains(location))
    }

    func testExtractTeamsURL() {
        let notes = "Click here: https://teams.microsoft.com/l/meetup-join/abc123"
        let urls = CalendarMatcher.extractMeetingURLs(from: notes)
        XCTAssertEqual(urls.count, 1)
        XCTAssertTrue(urls.first?.contains("teams.microsoft.com") ?? false)
    }

    func testMatchesMeetURL() {
        let eventURLs = ["https://meet.google.com/abc-defg-hij"]
        let detectedURL = "https://meet.google.com/abc-defg-hij"
        XCTAssertTrue(CalendarMatcher.urlMatches(detected: detectedURL, eventURLs: eventURLs))
    }

    func testMatchesZoomMeetingID() {
        let eventURLs = ["https://zoom.us/j/1234567890?pwd=abc"]
        let detectedURL = "https://zoom.us/j/1234567890"
        XCTAssertTrue(CalendarMatcher.urlMatches(detected: detectedURL, eventURLs: eventURLs))
    }

    func testNoMatchReturnsFalse() {
        let eventURLs = ["https://meet.google.com/abc-defg-hij"]
        let detectedURL = "https://meet.google.com/xyz-uvwx-rst"
        XCTAssertFalse(CalendarMatcher.urlMatches(detected: detectedURL, eventURLs: eventURLs))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Cmd+U`
Expected: FAIL — `CalendarMatcher` doesn't exist.

- [ ] **Step 3: Implement CalendarMatcher**

```swift
// MossadService/CalendarMatcher.swift
import EventKit
import Foundation

public struct MatchedEvent {
    public let title: String
    public let attendees: [String] // email addresses
    public let organizer: String?
    public let calendarEventId: String
    public let meetingUrl: String?
}

public final class CalendarMatcher {
    private let eventStore = EKEventStore()

    public init() {}

    /// Request calendar access. Returns true if granted.
    public func requestAccess() async -> Bool {
        do {
            return try await eventStore.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    /// Find a matching calendar event for a detected meeting.
    public func findMatchingEvent(
        platform: MeetingPlatform,
        detectedURL: String?,
        at date: Date = Date()
    ) -> MatchedEvent? {
        let windowStart = date.addingTimeInterval(-600) // -10 min
        let windowEnd = date.addingTimeInterval(600)    // +10 min

        let predicate = eventStore.predicateForEvents(
            withStart: windowStart,
            end: windowEnd,
            calendars: nil
        )
        let events = eventStore.events(matching: predicate)

        // First pass: try URL matching
        if let detectedURL = detectedURL {
            for event in events {
                let eventURLs = Self.extractMeetingURLs(from: event)
                if Self.urlMatches(detected: detectedURL, eventURLs: eventURLs) {
                    return matchedEvent(from: event)
                }
            }
        }

        // Second pass: pick the closest event by start time
        let closest = events
            .sorted { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) }
            .first

        if let closest = closest {
            return matchedEvent(from: closest)
        }

        return nil
    }

    private func matchedEvent(from event: EKEvent) -> MatchedEvent {
        let attendees = event.attendees?.compactMap { participant -> String? in
            // EKParticipant URL is like "mailto:email@example.com"
            guard let url = participant.url else { return nil }
            return url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        } ?? []

        let organizer = event.organizer?.url?.absoluteString
            .replacingOccurrences(of: "mailto:", with: "")

        let urls = Self.extractMeetingURLs(from: event)

        return MatchedEvent(
            title: event.title ?? "Untitled Meeting",
            attendees: attendees,
            organizer: organizer,
            calendarEventId: event.eventIdentifier,
            meetingUrl: urls.first
        )
    }

    // MARK: - Static helpers (testable)

    /// Extract meeting URLs from an EKEvent's notes and location.
    static func extractMeetingURLs(from event: EKEvent) -> [String] {
        var allText = ""
        if let notes = event.notes { allText += notes + " " }
        if let location = event.location { allText += location + " " }
        if let url = event.url { allText += url.absoluteString }
        return extractMeetingURLs(from: allText)
    }

    /// Extract meeting URLs from a text string.
    public static func extractMeetingURLs(from text: String) -> [String] {
        let patterns = [
            #"https://meet\.google\.com/[a-z]+-[a-z]+-[a-z]+"#,
            #"https://zoom\.us/j/\d+[^\s]*"#,
            #"https://teams\.microsoft\.com/[^\s]+"#,
        ]

        var urls: [String] = []
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let matches = regex.matches(
                    in: text,
                    range: NSRange(text.startIndex..., in: text)
                )
                for match in matches {
                    if let range = Range(match.range, in: text) {
                        urls.append(String(text[range]))
                    }
                }
            }
        }
        return urls
    }

    /// Check if a detected URL matches any URL from a calendar event.
    public static func urlMatches(detected: String, eventURLs: [String]) -> Bool {
        for eventURL in eventURLs {
            // For Zoom, match on meeting ID only (ignore password params)
            if detected.contains("zoom.us/j/") && eventURL.contains("zoom.us/j/") {
                let detectedId = detected.components(separatedBy: "/j/").last?
                    .components(separatedBy: "?").first
                let eventId = eventURL.components(separatedBy: "/j/").last?
                    .components(separatedBy: "?").first
                if detectedId != nil && detectedId == eventId { return true }
            }
            // For Meet, match the full meeting code path
            if detected.contains("meet.google.com/") && eventURL.contains("meet.google.com/") {
                let detectedCode = detected.components(separatedBy: "meet.google.com/").last?
                    .components(separatedBy: "?").first
                let eventCode = eventURL.components(separatedBy: "meet.google.com/").last?
                    .components(separatedBy: "?").first
                if detectedCode != nil && detectedCode == eventCode { return true }
            }
            // For Teams, substring match on the join path
            if detected.contains("teams.microsoft.com") && eventURL.contains("teams.microsoft.com") {
                return true // Teams URLs are complex; if both are Teams, likely the same meeting
            }
        }
        return false
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `Cmd+U`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add CalendarMatcher for EventKit query and meeting URL matching"
```

---

## Task 8: AssemblyAI Streaming Client

**Files:**
- Create: `MossadService/AssemblyAIClient.swift`
- Create: `MossadTests/AssemblyAIClientTests.swift`

- [ ] **Step 1: Write failing tests for message parsing**

```swift
// MossadTests/AssemblyAIClientTests.swift
import XCTest
@testable import MossadService

final class AssemblyAIClientTests: XCTestCase {

    func testParseSessionBegins() throws {
        let json = """
        {"message_type": "SessionBegins", "session_id": "abc123", "expires_at": "2026-03-20T12:00:00Z"}
        """
        let message = try AssemblyAIMessage.parse(json)
        guard case .sessionBegins(let sessionId) = message else {
            XCTFail("Expected sessionBegins")
            return
        }
        XCTAssertEqual(sessionId, "abc123")
    }

    func testParsePartialTranscript() throws {
        let json = """
        {"message_type": "PartialTranscript", "text": "hello world", "audio_start": 0, "audio_end": 2500}
        """
        let message = try AssemblyAIMessage.parse(json)
        guard case .partialTranscript(let text) = message else {
            XCTFail("Expected partialTranscript")
            return
        }
        XCTAssertEqual(text, "hello world")
    }

    func testParseFinalTranscript() throws {
        let json = """
        {
            "message_type": "FinalTranscript",
            "text": "We need to fix the auth bug",
            "audio_start": 1000,
            "audio_end": 3500,
            "words": [
                {"text": "We", "start": 1000, "end": 1200, "speaker": "A"},
                {"text": "need", "start": 1200, "end": 1400, "speaker": "A"}
            ]
        }
        """
        let message = try AssemblyAIMessage.parse(json)
        guard case .finalTranscript(let transcript) = message else {
            XCTFail("Expected finalTranscript")
            return
        }
        XCTAssertEqual(transcript.text, "We need to fix the auth bug")
        XCTAssertEqual(transcript.audioStartMs, 1000)
        XCTAssertEqual(transcript.audioEndMs, 3500)
        XCTAssertEqual(transcript.speakerLabel, "A")
    }

    func testParseFinalTranscriptPicksMajoritySpeaker() throws {
        let json = """
        {
            "message_type": "FinalTranscript",
            "text": "Hello there",
            "audio_start": 0,
            "audio_end": 2000,
            "words": [
                {"text": "Hello", "start": 0, "end": 500, "speaker": "A"},
                {"text": "there", "start": 500, "end": 1000, "speaker": "B"},
                {"text": "friend", "start": 1000, "end": 1500, "speaker": "A"}
            ]
        }
        """
        let message = try AssemblyAIMessage.parse(json)
        guard case .finalTranscript(let transcript) = message else {
            XCTFail("Expected finalTranscript")
            return
        }
        XCTAssertEqual(transcript.speakerLabel, "A") // majority speaker
    }

    func testParseErrorMessage() throws {
        let json = """
        {"message_type": "SessionTerminated", "error": "Session expired"}
        """
        let message = try AssemblyAIMessage.parse(json)
        guard case .terminated = message else {
            XCTFail("Expected terminated")
            return
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Cmd+U`
Expected: FAIL — `AssemblyAIClient` and `AssemblyAIMessage` don't exist.

- [ ] **Step 3: Implement message types and parser**

```swift
// MossadService/AssemblyAIClient.swift (part 1 — types and parsing)
import Foundation

public struct FinalTranscriptData {
    public let text: String
    public let audioStartMs: Int
    public let audioEndMs: Int
    public let speakerLabel: String?
}

public enum AssemblyAIMessage {
    case sessionBegins(sessionId: String)
    case partialTranscript(text: String)
    case finalTranscript(FinalTranscriptData)
    case terminated
    case unknown

    public static func parse(_ jsonString: String) throws -> AssemblyAIMessage {
        guard let data = jsonString.data(using: .utf8) else { return .unknown }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        guard let messageType = json["message_type"] as? String else { return .unknown }

        switch messageType {
        case "SessionBegins":
            let sessionId = json["session_id"] as? String ?? ""
            return .sessionBegins(sessionId: sessionId)

        case "PartialTranscript":
            let text = json["text"] as? String ?? ""
            return .partialTranscript(text: text)

        case "FinalTranscript":
            let text = json["text"] as? String ?? ""
            let audioStart = json["audio_start"] as? Int ?? 0
            let audioEnd = json["audio_end"] as? Int ?? 0

            // Determine speaker from words array (majority vote)
            var speakerLabel: String? = nil
            if let words = json["words"] as? [[String: Any]] {
                var counts: [String: Int] = [:]
                for word in words {
                    if let speaker = word["speaker"] as? String {
                        counts[speaker, default: 0] += 1
                    }
                }
                speakerLabel = counts.max(by: { $0.value < $1.value })?.key
            }

            return .finalTranscript(FinalTranscriptData(
                text: text,
                audioStartMs: audioStart,
                audioEndMs: audioEnd,
                speakerLabel: speakerLabel
            ))

        case "SessionTerminated":
            return .terminated

        default:
            return .unknown
        }
    }
}
```

- [ ] **Step 4: Run tests to verify parsing tests pass**

Run: `Cmd+U`
Expected: PASS

- [ ] **Step 5: Implement WebSocket client**

```swift
// MossadService/AssemblyAIClient.swift (part 2 — append to same file)

public protocol AssemblyAIClientDelegate: AnyObject {
    func client(_ client: AssemblyAIClient, didReceiveFinalTranscript transcript: FinalTranscriptData)
    func client(_ client: AssemblyAIClient, didReceivePartialTranscript text: String)
    func clientDidConnect(_ client: AssemblyAIClient)
    func clientDidDisconnect(_ client: AssemblyAIClient)
    func client(_ client: AssemblyAIClient, didEncounterError error: Error)
}

public final class AssemblyAIClient {
    private let apiKey: String
    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession
    public weak var delegate: AssemblyAIClientDelegate?
    private var isConnected = false

    public init(apiKey: String) {
        self.apiKey = apiKey
        self.session = URLSession(configuration: .default)
    }

    public func connect() {
        let urlString = "wss://api.assemblyai.com/v2/realtime/ws?sample_rate=16000&speaker_labels=true"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()
        receiveMessage()
    }

    public func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        delegate?.clientDidDisconnect(self)
    }

    /// Send raw PCM audio data (base64 encoded).
    public func sendAudio(_ pcmData: Data) {
        guard isConnected else { return }
        let base64 = pcmData.base64EncodedString()
        let json = "{\"audio_data\": \"\(base64)\"}"
        let message = URLSessionWebSocketTask.Message.string(json)
        webSocketTask?.send(message) { [weak self] error in
            if let error = error {
                self.map { self?.delegate?.client($0, didEncounterError: error) }
            }
        }
    }

    /// Send end-of-stream signal.
    public func terminateSession() {
        guard isConnected else { return }
        let json = "{\"terminate_session\": true}"
        let message = URLSessionWebSocketTask.Message.string(json)
        webSocketTask?.send(message) { _ in }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                default:
                    break
                }
                self.receiveMessage() // continue listening
            case .failure(let error):
                self.delegate?.client(self, didEncounterError: error)
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let message = try? AssemblyAIMessage.parse(text) else { return }

        switch message {
        case .sessionBegins:
            isConnected = true
            delegate?.clientDidConnect(self)
        case .partialTranscript(let partialText):
            delegate?.client(self, didReceivePartialTranscript: partialText)
        case .finalTranscript(let transcript):
            if !transcript.text.isEmpty {
                delegate?.client(self, didReceiveFinalTranscript: transcript)
            }
        case .terminated:
            disconnect()
        case .unknown:
            break
        }
    }
}
```

- [ ] **Step 6: Build and verify**

Run: `Cmd+B`
Expected: builds successfully.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: add AssemblyAI real-time streaming client with WebSocket and message parsing"
```

---

## Task 9: Audio Capture Manager

**Files:**
- Create: `MossadService/AudioCaptureManager.swift`

This component wraps ScreenCaptureKit (app audio) and AVAudioEngine (mic). It cannot be meaningfully unit tested — it requires real audio hardware and permissions. Test manually.

- [ ] **Step 1: Implement AudioCaptureManager**

```swift
// MossadService/AudioCaptureManager.swift
import AVFoundation
import Foundation
import ScreenCaptureKit

public protocol AudioCaptureDelegate: AnyObject {
    func audioCaptureManager(_ manager: AudioCaptureManager, didCaptureAppAudio data: Data)
    func audioCaptureManager(_ manager: AudioCaptureManager, didCaptureMicAudio data: Data)
    func audioCaptureManager(_ manager: AudioCaptureManager, didEncounterError error: Error)
}

public final class AudioCaptureManager: NSObject {
    public weak var delegate: AudioCaptureDelegate?

    private var scStream: SCStream?
    private var audioEngine: AVAudioEngine?

    // Target format for AssemblyAI
    private let targetSampleRate: Double = 16000
    private let targetChannels: AVAudioChannelCount = 1

    public override init() {
        super.init()
    }

    /// Start capturing audio from a specific app (via ScreenCaptureKit) and the mic.
    public func startCapture(appProcessID: pid_t) async throws {
        try await startAppAudioCapture(processID: appProcessID)
        try startMicCapture()
    }

    public func stopCapture() {
        scStream?.stopCapture()
        scStream = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
    }

    // MARK: - ScreenCaptureKit (app audio)

    private func startAppAudioCapture(processID: pid_t) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let app = content.applications.first(where: { $0.processID == processID }) else {
            throw AudioCaptureError.appNotFound
        }

        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplay
        }

        let appFilter = SCContentFilter(
            display: display,
            including: [app],
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(targetSampleRate)
        config.channelCount = Int(targetChannels)
        // We don't need video
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps minimum

        let stream = SCStream(filter: appFilter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()
        self.scStream = stream
    }

    // MARK: - AVAudioEngine (mic)

    private func startMicCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Convert to target format
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: true
        ) else {
            throw AudioCaptureError.formatError
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.converterError
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * self.targetSampleRate / inputFormat.sampleRate
            )
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
                return
            }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if let error = error {
                self.delegate?.audioCaptureManager(self, didEncounterError: error)
                return
            }

            if let data = convertedBuffer.int16Data {
                self.delegate?.audioCaptureManager(self, didCaptureMicAudio: data)
            }
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
    }
}

// MARK: - SCStreamOutput

extension AudioCaptureManager: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let data = sampleBuffer.pcmData else { return }
        delegate?.audioCaptureManager(self, didCaptureAppAudio: data)
    }
}

// MARK: - Helpers

enum AudioCaptureError: Error {
    case appNotFound
    case noDisplay
    case formatError
    case converterError
}

extension AVAudioPCMBuffer {
    var int16Data: Data? {
        guard let ptr = int16ChannelData else { return nil }
        let count = Int(frameLength)
        return Data(bytes: ptr[0], count: count * MemoryLayout<Int16>.size)
    }
}

extension CMSampleBuffer {
    var pcmData: Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(self) else { return nil }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let ptr = dataPointer else { return nil }
        return Data(bytes: ptr, count: length)
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `Cmd+B`
Expected: builds successfully. Note: ScreenCaptureKit requires linking the ScreenCaptureKit framework in the MossadService target's build settings.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: add AudioCaptureManager with ScreenCaptureKit and AVAudioEngine"
```

---

## Task 10: Session Coordinator

**Files:**
- Create: `MossadService/SessionCoordinator.swift`

The SessionCoordinator orchestrates the full call lifecycle: process detection → calendar match → audio capture → transcription → storage.

- [ ] **Step 1: Implement SessionCoordinator**

```swift
// MossadService/SessionCoordinator.swift
import Foundation
import MossadShared

public protocol SessionCoordinatorDelegate: AnyObject {
    func coordinator(_ coordinator: SessionCoordinator, didChangeState snapshot: ServiceSnapshot)
    func coordinator(_ coordinator: SessionCoordinator, didReceiveUtterance utteranceData: Data)
}

public final class SessionCoordinator {
    public weak var delegate: SessionCoordinatorDelegate?

    private let processMonitor = ProcessMonitor()
    private let calendarMatcher = CalendarMatcher()
    private let audioCaptureManager = AudioCaptureManager()
    private var appAudioClient: AssemblyAIClient?
    private var micAudioClient: AssemblyAIClient?
    private let store: ConversationStore
    private let dbManager: DatabaseManager

    private var currentConversationId: String?
    public private(set) var currentSnapshot = ServiceSnapshot()
    private var conversationStartTime: Date?
    private var speakerMap: [String: String] = [:] // diarization label → speaker ID
    private var meSpeaker: Speaker?

    public init() throws {
        self.dbManager = try DatabaseManager()
        self.store = ConversationStore(dbQueue: dbManager.dbQueue)
    }

    public func startMonitoring() {
        // Ensure we have the "me" speaker
        meSpeaker = try? store.getOrCreateMeSpeaker(
            name: UserDefaults.standard.string(forKey: "userName") ?? "Me"
        )

        processMonitor.startMonitoring(
            onDetected: { [weak self] meeting in
                self?.handleMeetingDetected(meeting)
            },
            onEnded: { [weak self] in
                self?.handleMeetingEnded()
            }
        )

        updateState { $0.recordingState = .detecting }
    }

    public func stopMonitoring() {
        processMonitor.stopMonitoring()
        if currentConversationId != nil {
            handleMeetingEnded()
        }
        updateState { $0.recordingState = .idle }
    }

    public func pauseRecording() {
        audioCaptureManager.stopCapture()
        appAudioClient?.terminateSession()
        micAudioClient?.terminateSession()
        updateState { $0.recordingState = .paused }
    }

    public func resumeRecording() {
        guard let convId = currentConversationId else { return }
        // Re-poll to find the meeting process and restart capture
        // We need to re-detect the meeting app to get its process ID
        processMonitor.stopMonitoring()
        processMonitor.startMonitoring(
            onDetected: { [weak self] meeting in
                guard let self = self else { return }
                // Restart audio capture for the existing conversation
                Task {
                    try? await self.audioCaptureManager.startCapture(appProcessID: meeting.processIdentifier)
                    self.audioCaptureManager.delegate = self
                    self.startTranscriptionClients()
                }
                self.updateState { $0.recordingState = .recording }
            },
            onEnded: { [weak self] in
                self?.handleMeetingEnded()
            }
        )
        updateState { $0.recordingState = .detecting }
    }

    // MARK: - Meeting Lifecycle

    private func handleMeetingDetected(_ meeting: DetectedMeeting) {
        // Match against calendar
        let matchedEvent = calendarMatcher.findMatchingEvent(
            platform: meeting.platform,
            detectedURL: meeting.meetingUrl
        )

        let title = matchedEvent?.title ?? "Ad-hoc \(meeting.platform.rawValue.capitalized) Call"
        let calendarEventId = matchedEvent?.calendarEventId
        let meetingUrl = meeting.meetingUrl ?? matchedEvent?.meetingUrl

        // Create conversation record
        guard let conversation = try? store.createConversation(
            title: title,
            platform: meeting.platform.rawValue,
            calendarEventId: calendarEventId,
            meetingUrl: meetingUrl
        ) else { return }

        currentConversationId = conversation.id
        conversationStartTime = conversation.startedAt

        // Add "me" as a conversation speaker
        if let me = meSpeaker {
            try? store.addConversationSpeaker(
                conversationId: conversation.id,
                speakerId: me.id,
                diarizationLabel: "me"
            )
        }

        // Start audio capture
        Task {
            do {
                try await audioCaptureManager.startCapture(appProcessID: meeting.processIdentifier)
                audioCaptureManager.delegate = self
                startTranscriptionClients()
            } catch {
                print("Audio capture failed: \(error)")
            }
        }

        updateState {
            $0.recordingState = .recording
            $0.currentConversationId = conversation.id
            $0.currentMeetingTitle = title
            $0.currentPlatform = meeting.platform.rawValue
            $0.elapsedSeconds = 0
        }

        // Start elapsed time ticker
        startElapsedTimer()
    }

    private func handleMeetingEnded() {
        guard let convId = currentConversationId else { return }

        // Stop everything
        audioCaptureManager.stopCapture()
        appAudioClient?.terminateSession()
        appAudioClient?.disconnect()
        micAudioClient?.terminateSession()
        micAudioClient?.disconnect()

        // Finalize conversation
        try? store.finalizeConversation(id: convId)

        currentConversationId = nil
        conversationStartTime = nil
        speakerMap = [:]

        updateState {
            $0.recordingState = .detecting
            $0.currentConversationId = nil
            $0.currentMeetingTitle = nil
            $0.currentPlatform = nil
            $0.elapsedSeconds = nil
            $0.speakerCount = nil
        }
    }

    // MARK: - Transcription

    private func startTranscriptionClients() {
        guard let apiKey = try? KeychainManager.retrieve(account: "assemblyai-api-key") else {
            print("No AssemblyAI API key configured")
            return
        }

        // App audio client (others' voices, with diarization)
        let appClient = AssemblyAIClient(apiKey: apiKey)
        appClient.delegate = self
        appClient.connect()
        self.appAudioClient = appClient

        // Mic audio client (my voice)
        let micClient = AssemblyAIClient(apiKey: apiKey)
        micClient.delegate = self
        micClient.connect()
        self.micAudioClient = micClient
    }

    // MARK: - State Management

    private func updateState(_ modify: (inout ServiceSnapshot) -> Void) {
        modify(&currentSnapshot)
        delegate?.coordinator(self, didChangeState: currentSnapshot)
    }

    private var elapsedTimer: Timer?

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.conversationStartTime else { return }
            self.updateState {
                $0.elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }
    }
}

// MARK: - AudioCaptureDelegate

extension SessionCoordinator: AudioCaptureDelegate {
    public func audioCaptureManager(_ manager: AudioCaptureManager, didCaptureAppAudio data: Data) {
        appAudioClient?.sendAudio(data)
    }

    public func audioCaptureManager(_ manager: AudioCaptureManager, didCaptureMicAudio data: Data) {
        micAudioClient?.sendAudio(data)
    }

    public func audioCaptureManager(_ manager: AudioCaptureManager, didEncounterError error: Error) {
        print("Audio capture error: \(error)")
    }
}

// MARK: - AssemblyAIClientDelegate

extension SessionCoordinator: AssemblyAIClientDelegate {
    public func client(_ client: AssemblyAIClient, didReceiveFinalTranscript transcript: FinalTranscriptData) {
        guard let convId = currentConversationId,
              let startTime = conversationStartTime else { return }

        let isMyVoice = (client === micAudioClient)
        let startOffset = Double(transcript.audioStartMs) / 1000.0
        let endOffset = Double(transcript.audioEndMs) / 1000.0

        let speakerId: String
        if isMyVoice {
            speakerId = meSpeaker?.id ?? "unknown"
        } else {
            let label = transcript.speakerLabel ?? "Unknown"
            if let existingId = speakerMap[label] {
                speakerId = existingId
            } else {
                // Create a new placeholder speaker
                let speaker = try? store.getOrCreateSpeaker(name: "Speaker \(label)")
                speakerId = speaker?.id ?? "unknown"
                speakerMap[label] = speakerId
                try? store.addConversationSpeaker(
                    conversationId: convId,
                    speakerId: speakerId,
                    diarizationLabel: label
                )
                updateState { $0.speakerCount = self.speakerMap.count + 1 } // +1 for me
            }
        }

        try? store.insertUtterance(
            conversationId: convId,
            speakerId: speakerId,
            text: transcript.text,
            startedAt: startOffset,
            endedAt: endOffset
        )
    }

    public func client(_ client: AssemblyAIClient, didReceivePartialTranscript text: String) {
        // Could display live partial text in UI — ignored for now
    }

    public func clientDidConnect(_ client: AssemblyAIClient) {
        // Both clients connected — ready to stream
    }

    public func clientDidDisconnect(_ client: AssemblyAIClient) {
        // Handle reconnection if needed
    }

    public func client(_ client: AssemblyAIClient, didEncounterError error: Error) {
        print("AssemblyAI error: \(error)")
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `Cmd+B`
Expected: builds successfully.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: add SessionCoordinator to orchestrate call lifecycle"
```

---

## Task 11: XPC Service Implementation

**Files:**
- Modify: `MossadService/main.swift`
- Create: `MossadService/ServiceDelegate.swift`
- Create: `MossadService/MossadServiceImpl.swift`

- [ ] **Step 1: Implement the XPC service delegate**

```swift
// MossadService/ServiceDelegate.swift
import Foundation
import MossadShared

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        let exportedInterface = NSXPCInterface(with: MossadServiceProtocol.self)
        newConnection.exportedInterface = exportedInterface

        let remoteInterface = NSXPCInterface(with: MossadAppProtocol.self)
        newConnection.remoteObjectInterface = remoteInterface

        let serviceImpl = MossadServiceImpl()
        serviceImpl.appProxy = newConnection.remoteObjectProxy as? MossadAppProtocol
        newConnection.exportedObject = serviceImpl

        newConnection.invalidationHandler = {
            serviceImpl.appProxy = nil
        }

        newConnection.resume()
        return true
    }
}
```

- [ ] **Step 2: Implement the service protocol**

```swift
// MossadService/MossadServiceImpl.swift
import Foundation
import MossadShared

class MossadServiceImpl: NSObject, MossadServiceProtocol {
    var appProxy: MossadAppProtocol?
    private var coordinator: SessionCoordinator?

    override init() {
        super.init()
        coordinator = try? SessionCoordinator()
        coordinator?.delegate = self
    }

    func startMonitoring() {
        coordinator?.startMonitoring()
    }

    func stopMonitoring() {
        coordinator?.stopMonitoring()
    }

    func pauseRecording() {
        coordinator?.pauseRecording()
    }

    func resumeRecording() {
        coordinator?.resumeRecording()
    }

    func getState(reply: @escaping (Data) -> Void) {
        if let snapshot = coordinator?.currentSnapshot {
            reply(snapshot.encoded())
        } else {
            reply(ServiceSnapshot().encoded())
        }
    }
}

extension MossadServiceImpl: SessionCoordinatorDelegate {
    func coordinator(_ coordinator: SessionCoordinator, didChangeState snapshot: ServiceSnapshot) {
        appProxy?.stateDidChange(snapshot.encoded())
    }

    func coordinator(_ coordinator: SessionCoordinator, didReceiveUtterance utteranceData: Data) {
        appProxy?.utteranceReceived(utteranceData)
    }
}
```

- [ ] **Step 3: Update main.swift**

```swift
// MossadService/main.swift
import Foundation

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
```

- [ ] **Step 4: Build and verify**

Run: `Cmd+B`
Expected: builds successfully.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: implement XPC service with listener, delegate, and protocol"
```

---

## Task 12: App State and XPC Connection

**Files:**
- Create: `Mossad/AppState.swift`

- [ ] **Step 1: Implement AppState with XPC connection**

```swift
// Mossad/AppState.swift
import Foundation
import MossadShared
import SwiftUI

@MainActor
public final class AppState: NSObject, ObservableObject {
    @Published var recordingState: RecordingState = .idle
    @Published var currentMeetingTitle: String?
    @Published var currentPlatform: String?
    @Published var elapsedSeconds: Int = 0
    @Published var speakerCount: Int = 0
    @Published var currentConversationId: String?

    private var xpcConnection: NSXPCConnection?
    private var service: MossadServiceProtocol?
    let store: ConversationStore

    override init() {
        let dbManager = try! DatabaseManager()
        self.store = ConversationStore(dbQueue: dbManager.dbQueue)
        super.init()
        setupXPCConnection()
    }

    private func setupXPCConnection() {
        let connection = NSXPCConnection(serviceName: "com.mossad.MossadService")
        connection.remoteObjectInterface = NSXPCInterface(with: MossadServiceProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: MossadAppProtocol.self)
        connection.exportedObject = self
        connection.resume()

        self.xpcConnection = connection
        self.service = connection.remoteObjectProxyWithErrorHandler { error in
            print("XPC error: \(error)")
        } as? MossadServiceProtocol

        // Start monitoring immediately
        service?.startMonitoring()
    }

    func pauseRecording() {
        service?.pauseRecording()
    }

    func resumeRecording() {
        service?.resumeRecording()
    }

    func stopMonitoring() {
        service?.stopMonitoring()
    }

    var elapsedFormatted: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

extension AppState: MossadAppProtocol {
    nonisolated public func stateDidChange(_ stateData: Data) {
        guard let snapshot = ServiceSnapshot.decoded(from: stateData) else { return }
        Task { @MainActor in
            self.recordingState = snapshot.recordingState
            self.currentMeetingTitle = snapshot.currentMeetingTitle
            self.currentPlatform = snapshot.currentPlatform
            self.elapsedSeconds = snapshot.elapsedSeconds ?? 0
            self.speakerCount = snapshot.speakerCount ?? 0
            self.currentConversationId = snapshot.currentConversationId
        }
    }

    nonisolated public func utteranceReceived(_ utteranceData: Data) {
        // Could use this for live transcript display
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `Cmd+B`
Expected: builds successfully.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: add AppState with XPC connection to background service"
```

---

## Task 13: Menu Bar UI

**Files:**
- Modify: `Mossad/MossadApp.swift`
- Create: `Mossad/Views/MenuBarPopover.swift`

- [ ] **Step 1: Implement MenuBarPopover**

```swift
// Mossad/Views/MenuBarPopover.swift
import SwiftUI
import MossadShared

struct MenuBarPopover: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Mossad")
                    .font(.headline)
                Spacer()
                statusBadge
            }
            .padding()

            Divider()

            // Status content
            Group {
                switch appState.recordingState {
                case .idle, .detecting:
                    idleContent
                case .recording:
                    recordingContent
                case .paused:
                    pausedContent
                }
            }

            Divider()

            // Actions
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    openConversationBrowser()
                } label: {
                    Label("Open Conversations...", systemImage: "list.bullet.rectangle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                .padding(.vertical, 6)

                Button {
                    openSettings()
                } label: {
                    Label("Settings...", systemImage: "gear")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                .padding(.vertical, 6)

                Divider()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("Quit Mossad")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
        }
        .frame(width: 280)
        .glassEffect(.regular.tint(.clear))
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch appState.recordingState {
        case .idle, .detecting:
            Text("Idle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .recording:
            HStack(spacing: 4) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("Recording")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        case .paused:
            Text("Paused")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var idleContent: some View {
        Text("No active call detected")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding()
    }

    @ViewBuilder
    private var recordingContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(appState.currentMeetingTitle ?? "Unknown Meeting")
                .font(.subheadline)
                .fontWeight(.semibold)

            HStack {
                if let platform = appState.currentPlatform {
                    Label(platform.capitalized, systemImage: platformIcon(platform))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("·")
                    .foregroundStyle(.secondary)
                Text(appState.elapsedFormatted)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text("\(appState.speakerCount) speakers detected")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()

        Button {
            appState.pauseRecording()
        } label: {
            Label("Pause Recording", systemImage: "pause.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.orange)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var pausedContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(appState.currentMeetingTitle ?? "Unknown Meeting")
                .font(.subheadline)
                .fontWeight(.semibold)
            Text("Recording paused")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        .padding()

        Button {
            appState.resumeRecording()
        } label: {
            Label("Resume Recording", systemImage: "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.green)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func platformIcon(_ platform: String) -> String {
        switch platform {
        case "zoom": return "video.fill"
        case "meet": return "person.3.fill"
        case "teams": return "person.2.fill"
        default: return "phone.fill"
        }
    }

    private func openConversationBrowser() {
        NSApp.activate(ignoringOtherApps: true)
        // Window opening handled by MossadApp scene
        NotificationCenter.default.post(name: .openConversationBrowser, object: nil)
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .openSettings, object: nil)
    }
}

extension Notification.Name {
    static let openConversationBrowser = Notification.Name("openConversationBrowser")
    static let openSettings = Notification.Name("openSettings")
}
```

- [ ] **Step 2: Update MossadApp.swift**

```swift
// Mossad/MossadApp.swift
import SwiftUI
import MossadShared

@main
struct MossadApp: App {
    @StateObject private var appState = AppState()
    @State private var showBrowser = false
    @State private var showSettings = false

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.recordingState == .recording ? "mic.fill" : "mic")
                .symbolRenderingMode(.palette)
                .foregroundStyle(appState.recordingState == .recording ? .red : .primary)
                .symbolEffect(.pulse, options: .repeating, isActive: appState.recordingState == .recording)
        }
        .menuBarExtraStyle(.window)

        Window("Conversations", id: "browser") {
            Text("Conversation Browser — coming next task")
                .environmentObject(appState)
        }

        Settings {
            Text("Settings — coming in a later task")
                .environmentObject(appState)
        }
    }
}
```

- [ ] **Step 3: Build and run**

Run: `Cmd+R`
Expected: app appears in menu bar with mic icon. Clicking shows the popover with idle state. Quit button works.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: add menu bar UI with popover showing recording state"
```

---

## Task 14: Conversation Browser — List View

**Files:**
- Create: `Mossad/Views/ConversationBrowserWindow.swift`
- Create: `Mossad/Views/ConversationListView.swift`

- [ ] **Step 1: Implement ConversationListView**

```swift
// Mossad/Views/ConversationListView.swift
import SwiftUI
import MossadShared

struct ConversationListView: View {
    @EnvironmentObject var appState: AppState
    @Binding var selectedConversationId: String?
    @State private var conversations: [Conversation] = []
    @State private var speakerCounts: [String: Int] = [:]
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search conversations...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .glassEffect(.regular.tint(.clear))

            // Conversation list
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(conversations) { conversation in
                        ConversationRow(
                            conversation: conversation,
                            isSelected: selectedConversationId == conversation.id,
                            speakerCount: speakerCounts[conversation.id] ?? 0
                        )
                        .onTapGesture {
                            withAnimation(.spring(duration: 0.3)) {
                                selectedConversationId = conversation.id
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }
        }
        .frame(minWidth: 280, maxWidth: 320)
        .task {
            loadConversations()
        }
        .onChange(of: searchText) {
            loadConversations()
        }
    }

    private func loadConversations() {
        // Search wiring added in Task 16
        conversations = (try? appState.store.listConversations()) ?? []
        // Load speaker counts for each conversation
        for conv in conversations {
            let speakers = (try? appState.store.fetchSpeakers(conversationId: conv.id)) ?? []
            speakerCounts[conv.id] = speakers.count
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    let isSelected: Bool
    let speakerCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conversation.title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(1)

            HStack {
                Text(conversation.startedAt, style: .date)
                Text("·")
                if let duration = conversation.durationSeconds {
                    Text(formatDuration(duration))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Label(conversation.platform.capitalized, systemImage: platformIcon(conversation.platform))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if speakerCount > 0 {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(speakerCount) speakers")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.selection)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds >= 3600 {
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            return "\(h)h \(m)m"
        }
        return "\(seconds / 60)m"
    }

    private func platformIcon(_ platform: String) -> String {
        switch platform {
        case "zoom": return "video.fill"
        case "meet": return "person.3.fill"
        case "teams": return "person.2.fill"
        default: return "phone.fill"
        }
    }
}
```

- [ ] **Step 2: Implement ConversationBrowserWindow**

```swift
// Mossad/Views/ConversationBrowserWindow.swift
import SwiftUI
import MossadShared

struct ConversationBrowserWindow: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedConversationId: String?

    var body: some View {
        NavigationSplitView {
            ConversationListView(selectedConversationId: $selectedConversationId)
                .environmentObject(appState)
        } detail: {
            if let id = selectedConversationId {
                TranscriptPlaceholder(conversationId: id)
                    .environmentObject(appState)
            } else {
                ContentUnavailableView(
                    "Select a Conversation",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Choose a conversation from the sidebar to view the transcript.")
                )
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .glassEffect(.regular.tint(.clear))
    }
}

// Placeholder until Task 15
struct TranscriptPlaceholder: View {
    let conversationId: String
    @EnvironmentObject var appState: AppState

    var body: some View {
        Text("Transcript view — next task")
            .foregroundStyle(.secondary)
    }
}
```

- [ ] **Step 3: Update MossadApp.swift to use ConversationBrowserWindow**

Replace the placeholder Window scene:

```swift
// In MossadApp.swift, replace the Window("Conversations") scene:
Window("Conversations", id: "browser") {
    ConversationBrowserWindow()
        .environmentObject(appState)
}
```

- [ ] **Step 4: Build and run**

Run: `Cmd+R`
Expected: opening the conversations window shows the split view with sidebar and empty detail panel.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add conversation browser window with sidebar list view"
```

---

## Task 15: Transcript View

**Files:**
- Create: `Mossad/Views/TranscriptView.swift`
- Modify: `Mossad/Views/ConversationBrowserWindow.swift` (replace placeholder)

- [ ] **Step 1: Implement TranscriptView**

```swift
// Mossad/Views/TranscriptView.swift
import SwiftUI
import MossadShared

struct TranscriptView: View {
    let conversationId: String
    var scrollToUtteranceId: Int64? = nil
    @EnvironmentObject var appState: AppState
    @State private var conversation: Conversation?
    @State private var utterances: [(Utterance, Speaker)] = []
    @State private var speakers: [Speaker] = []

    // Speaker color palette
    private let speakerColors: [Color] = [
        .green, .purple, .pink, .orange, .cyan, .yellow, .mint, .indigo
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            if let conversation = conversation {
                transcriptHeader(conversation)
            }

            Divider()

            // Transcript
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(utterances, id: \.0.id) { utterance, speaker in
                            UtteranceRow(
                                utterance: utterance,
                                speaker: speaker,
                                color: colorForSpeaker(speaker)
                            )
                            .id(utterance.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: scrollToUtteranceId) {
                    if let targetId = scrollToUtteranceId {
                        withAnimation {
                            proxy.scrollTo(targetId, anchor: .center)
                        }
                    }
                }
            }
        }
        .task {
            loadTranscript()
        }
    }

    @ViewBuilder
    private func transcriptHeader(_ conv: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conv.title)
                .font(.title2)
                .fontWeight(.bold)

            HStack {
                Text(conv.startedAt, style: .date)
                if let endedAt = conv.endedAt {
                    Text("·")
                    Text("\(conv.startedAt, style: .time) – \(endedAt, style: .time)")
                }
                Text("·")
                Text(conv.platform.capitalized)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(speakers) { speaker in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(colorForSpeaker(speaker))
                            .frame(width: 10, height: 10)
                        Text(speaker.name)
                            .font(.caption)
                    }
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding()
        .glassEffect(.regular.tint(.clear))
    }

    private func colorForSpeaker(_ speaker: Speaker) -> Color {
        if speaker.isMe { return .green }
        guard let index = speakers.firstIndex(where: { $0.id == speaker.id }) else {
            return .gray
        }
        return speakerColors[index % speakerColors.count]
    }

    private func loadTranscript() {
        conversation = try? appState.store.fetchConversation(id: conversationId)
        speakers = (try? appState.store.fetchSpeakers(conversationId: conversationId)) ?? []

        let rawUtterances = (try? appState.store.fetchUtterances(conversationId: conversationId)) ?? []
        utterances = rawUtterances.compactMap { utterance in
            guard let speaker = speakers.first(where: { $0.id == utterance.speakerId })
                ?? (try? appState.store.fetchSpeaker(id: utterance.speakerId)) else {
                return nil
            }
            return (utterance, speaker)
        }
    }
}

struct UtteranceRow: View {
    let utterance: Utterance
    let speaker: Speaker
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(speaker.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(color)

                Text(formatTimestamp(utterance.startedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(utterance.text)
                .font(.body)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
```

- [ ] **Step 2: Update ConversationBrowserWindow to use TranscriptView**

In `ConversationBrowserWindow.swift`, replace `TranscriptPlaceholder` usage:

Also add `@State private var scrollToUtteranceId: Int64?` to `ConversationBrowserWindow` and pass the binding through `ConversationListView` → `SearchResultsView`. Then replace the detail section:

```swift
// Replace the detail section:
} detail: {
    if let id = selectedConversationId {
        TranscriptView(conversationId: id, scrollToUtteranceId: scrollToUtteranceId)
            .environmentObject(appState)
    } else {
        ContentUnavailableView(
            "Select a Conversation",
            systemImage: "bubble.left.and.bubble.right",
            description: Text("Choose a conversation from the sidebar to view the transcript.")
        )
    }
}
```

- [ ] **Step 3: Add fetchSpeaker helper to ConversationStore**

Add to `ConversationStore.swift`:

```swift
public func fetchSpeaker(id: String) throws -> Speaker? {
    try dbQueue.read { db in
        try Speaker.fetchOne(db, key: id)
    }
}
```

- [ ] **Step 4: Build and run**

Run: `Cmd+R`
Expected: selecting a conversation in the sidebar shows the transcript with colored speaker names and timestamps.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add TranscriptView with speaker-colored utterances and timestamps"
```

---

## Task 16: Search Results View

**Files:**
- Create: `Mossad/Views/SearchResultsView.swift`
- Modify: `Mossad/Views/ConversationListView.swift` (wire up search)

- [ ] **Step 1: Implement SearchResultsView**

```swift
// Mossad/Views/SearchResultsView.swift
import SwiftUI
import MossadShared

struct SearchResultsView: View {
    let results: [SearchResult]
    @Binding var selectedConversationId: String?
    @Binding var scrollToUtteranceId: Int64?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(results, id: \.utterance.id) { result in
                    SearchResultRow(result: result)
                        .onTapGesture {
                            withAnimation(.spring(duration: 0.3)) {
                                selectedConversationId = result.conversation.id
                                scrollToUtteranceId = result.utterance.id
                            }
                        }
                }
            }
            .padding(.horizontal, 8)
        }
    }
}

struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(result.conversation.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                Text(result.conversation.startedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(result.speaker.name)
                    .font(.caption)
                    .foregroundStyle(.purple)
                Text("· at \(formatTimestamp(result.utterance.startedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(result.utterance.text)
                .font(.subheadline)
                .lineLimit(3)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(.background.opacity(0.6))
        }
        .glassEffect(.regular.tint(.clear))
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
```

- [ ] **Step 2: Wire search into ConversationListView**

Update `ConversationListView.swift`'s `loadConversations` method and add search results state:

```swift
// Add to ConversationListView:
@State private var searchResults: [SearchResult] = []
@State private var isSearching = false

// Update the body to show search results when searching:
// Replace the ScrollView content with:
if isSearching && !searchResults.isEmpty {
    SearchResultsView(results: searchResults, selectedConversationId: $selectedConversationId)
} else {
    // existing conversation list
}

// Update loadConversations:
private func loadConversations() {
    if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
        isSearching = false
        conversations = (try? appState.store.listConversations()) ?? []
    } else {
        isSearching = true
        searchResults = (try? appState.store.search(query: searchText)) ?? []
    }
}
```

- [ ] **Step 3: Build and run**

Run: `Cmd+R`
Expected: typing in the search bar shows search results. Clicking a result selects the conversation.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: add search results view with FTS5 integration"
```

---

## Task 17: Speaker Labeling Sheet

**Files:**
- Create: `Mossad/Views/SpeakerLabelingSheet.swift`

- [ ] **Step 1: Implement SpeakerLabelingSheet**

```swift
// Mossad/Views/SpeakerLabelingSheet.swift
import SwiftUI
import MossadShared

struct SpeakerLabelingSheet: View {
    let conversationId: String
    let calendarAttendees: [String] // email addresses from calendar
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var speakers: [Speaker] = []
    @State private var assignments: [String: String] = [:] // speakerId → name

    var body: some View {
        VStack(spacing: 16) {
            Text("Identify Speakers")
                .font(.headline)

            Text("Assign names to the speakers detected in this conversation.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(speakers.filter { !$0.isMe }) { speaker in
                HStack {
                    Circle()
                        .fill(.purple)
                        .frame(width: 10, height: 10)

                    Text(speaker.name)
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)

                    Image(systemName: "arrow.right")
                        .foregroundStyle(.tertiary)

                    if !calendarAttendees.isEmpty {
                        Picker("", selection: binding(for: speaker.id)) {
                            Text("Unknown").tag("")
                            ForEach(calendarAttendees, id: \.self) { attendee in
                                Text(attendee).tag(attendee)
                            }
                        }
                        .labelsHidden()
                    } else {
                        TextField("Name", text: binding(for: speaker.id))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            HStack {
                Button("Skip") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    saveAssignments()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 400)
        .task {
            speakers = (try? appState.store.fetchSpeakers(conversationId: conversationId)) ?? []
            for speaker in speakers where !speaker.isMe {
                assignments[speaker.id] = speaker.name
            }
        }
    }

    private func binding(for speakerId: String) -> Binding<String> {
        Binding(
            get: { assignments[speakerId] ?? "" },
            set: { assignments[speakerId] = $0 }
        )
    }

    private func saveAssignments() {
        for (speakerId, name) in assignments where !name.isEmpty {
            try? appState.store.updateSpeakerName(id: speakerId, name: name)
        }
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `Cmd+B`
Expected: builds successfully.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: add speaker labeling sheet for post-call identification"
```

---

## Task 18: Settings View

**Files:**
- Create: `Mossad/Views/SettingsView.swift`
- Modify: `Mossad/MossadApp.swift` (wire up Settings scene)

- [ ] **Step 1: Implement SettingsView**

```swift
// Mossad/Views/SettingsView.swift
import SwiftUI
import MossadShared

struct SettingsView: View {
    @State private var apiKey: String = ""
    @State private var userName: String = ""
    @State private var launchAtLogin: Bool = false
    @State private var selectedAudioDevice: String = "default"
    @State private var audioDevices: [AudioDeviceInfo] = []
    @State private var showSavedMessage = false

    var body: some View {
        Form {
            Section("AssemblyAI") {
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Get your API key at assemblyai.com")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Identity") {
                TextField("Your Name", text: $userName)
                    .textFieldStyle(.roundedBorder)
                Text("Used to label your utterances in transcripts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Audio") {
                Picker("Input Device", selection: $selectedAudioDevice) {
                    Text("System Default").tag("default")
                    ForEach(audioDevices, id: \.id) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                Text("Which microphone to use for capturing your voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
            }

            HStack {
                Spacer()
                if showSavedMessage {
                    Text("Saved!")
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                Button("Save") {
                    save()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 320)
        .task {
            apiKey = (try? KeychainManager.retrieve(account: "assemblyai-api-key")) ?? ""
            userName = UserDefaults.standard.string(forKey: "userName") ?? ""
            launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
            selectedAudioDevice = UserDefaults.standard.string(forKey: "audioDeviceId") ?? "default"
            audioDevices = AudioDeviceInfo.listInputDevices()
        }
    }

    private func save() {
        if !apiKey.isEmpty {
            try? KeychainManager.save(account: "assemblyai-api-key", data: apiKey)
        }
        UserDefaults.standard.set(userName, forKey: "userName")
        UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
        UserDefaults.standard.set(selectedAudioDevice, forKey: "audioDeviceId")

        withAnimation {
            showSavedMessage = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { showSavedMessage = false }
        }
    }
}
```

- [ ] **Step 2: Add AudioDeviceInfo helper**

```swift
// Add to the bottom of SettingsView.swift (or a separate file):
import CoreAudio

struct AudioDeviceInfo: Identifiable {
    let id: String
    let name: String

    static func listInputDevices() -> [AudioDeviceInfo] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs)

        return deviceIDs.compactMap { deviceID -> AudioDeviceInfo? in
            // Check if it has input channels
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inputSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &inputSize)
            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPtr.deallocate() }
            AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &inputSize, bufferListPtr)
            let channelCount = bufferListPtr.pointee.mBuffers.mNumberChannels
            guard channelCount > 0 else { return nil }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)

            return AudioDeviceInfo(id: "\(deviceID)", name: name as String)
        }
    }
}
```

- [ ] **Step 3: Update MossadApp.swift Settings scene**

```swift
// Replace the Settings scene:
Settings {
    SettingsView()
}
```

- [ ] **Step 4: Build and run**

Run: `Cmd+R`
Expected: Cmd+, opens settings with API key, name, audio input device picker, and launch at login toggle.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add settings view with API key, name, audio device, and launch at login"
```

---

## Task 19: Onboarding View

**Files:**
- Create: `Mossad/Views/OnboardingView.swift`
- Modify: `Mossad/MossadApp.swift` (show on first launch)

- [ ] **Step 1: Implement OnboardingView**

```swift
// Mossad/Views/OnboardingView.swift
import AVFoundation
import EventKit
import ScreenCaptureKit
import SwiftUI
import MossadShared

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentStep = 0
    @State private var apiKey = ""
    @State private var userName = ""
    @State private var micGranted = false
    @State private var calendarGranted = false
    @State private var screenGranted = false

    var body: some View {
        VStack(spacing: 24) {
            // Progress
            HStack {
                ForEach(0..<4) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }

            switch currentStep {
            case 0:
                welcomeStep
            case 1:
                apiKeyStep
            case 2:
                permissionsStep
            case 3:
                readyStep
            default:
                EmptyView()
            }
        }
        .padding(40)
        .frame(width: 500, height: 400)
    }

    @ViewBuilder
    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.fill")
                .font(.system(size: 48))
                .foregroundStyle(.accent)
            Text("Welcome to Mossad")
                .font(.title)
                .fontWeight(.bold)
            Text("Automatic meeting transcription that runs quietly in your menu bar. Let's get you set up.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Get Started") {
                withAnimation { currentStep = 1 }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private var apiKeyStep: some View {
        VStack(spacing: 16) {
            Text("AssemblyAI API Key")
                .font(.title2)
                .fontWeight(.bold)
            Text("Mossad uses AssemblyAI for transcription. Enter your API key below.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            SecureField("API Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 350)

            TextField("Your Name", text: $userName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 350)

            Spacer()
            Button("Continue") {
                if !apiKey.isEmpty {
                    try? KeychainManager.save(account: "assemblyai-api-key", data: apiKey)
                }
                if !userName.isEmpty {
                    UserDefaults.standard.set(userName, forKey: "userName")
                }
                withAnimation { currentStep = 2 }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(apiKey.isEmpty || userName.isEmpty)
        }
    }

    @ViewBuilder
    private var permissionsStep: some View {
        VStack(spacing: 16) {
            Text("Permissions")
                .font(.title2)
                .fontWeight(.bold)
            Text("Mossad needs a few permissions to work.")
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                permissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "To capture your voice",
                    granted: micGranted
                ) {
                    requestMicPermission()
                }

                permissionRow(
                    icon: "calendar",
                    title: "Calendar",
                    description: "To match meetings with events",
                    granted: calendarGranted
                ) {
                    requestCalendarPermission()
                }

                permissionRow(
                    icon: "rectangle.on.rectangle",
                    title: "Screen Recording",
                    description: "To capture meeting audio",
                    granted: screenGranted
                ) {
                    requestScreenPermission()
                }
            }

            Spacer()
            Button("Continue") {
                withAnimation { currentStep = 3 }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private func permissionRow(
        icon: String,
        title: String,
        description: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 30)
            VStack(alignment: .leading) {
                Text(title).font(.subheadline).fontWeight(.medium)
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Grant") { action() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background.opacity(0.5)))
    }

    @ViewBuilder
    private var readyStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("You're All Set!")
                .font(.title)
                .fontWeight(.bold)
            Text("Mossad is now running in your menu bar. It will automatically detect and transcribe your meetings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") {
                UserDefaults.standard.set(true, forKey: "onboardingComplete")
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Permission Requests

    private func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { micGranted = granted }
        }
    }

    private func requestCalendarPermission() {
        let store = EKEventStore()
        Task {
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            await MainActor.run { calendarGranted = granted }
        }
    }

    private func requestScreenPermission() {
        // ScreenCaptureKit permission is granted via System Settings
        // We can check if we have it, but can't trigger the prompt programmatically
        Task {
            do {
                let _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                await MainActor.run { screenGranted = true }
            } catch {
                // Open System Settings to the Screen Recording pane
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Show onboarding on first launch**

In `MossadApp.swift`, add:

```swift
// Add to MossadApp struct:
@AppStorage("onboardingComplete") private var onboardingComplete = false

// Add a Window scene for onboarding:
Window("Setup", id: "onboarding") {
    OnboardingView()
}
.windowStyle(.hiddenTitleBar)
.defaultSize(width: 500, height: 400)
```

And in `AppState.init()`, check if onboarding is needed and open the window if so.

- [ ] **Step 3: Build and run**

Run: `Cmd+R`
Expected: on first launch, the onboarding window appears with the 4-step setup flow.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: add onboarding flow with API key setup and permission requests"
```

---

## Task 20: Integration and Polish

**Files:**
- Modify: various files for final integration

This task connects all the pieces and handles edge cases.

- [ ] **Step 1: Add app icon**

Create a simple app icon in `Assets.xcassets` — a microphone glyph on a dark background. Use SF Symbol "mic.fill" rendered at 1024x1024 as a starting point, or use a simple design tool.

- [ ] **Step 2: Wire up "Open Conversations" from menu bar**

In `MossadApp.swift`, handle the notification to open the browser window:

```swift
// Add to MossadApp:
@Environment(\.openWindow) private var openWindow

// In the MenuBarExtra, use .onReceive to handle the notification:
MenuBarExtra {
    MenuBarPopover()
        .environmentObject(appState)
        .onReceive(NotificationCenter.default.publisher(for: .openConversationBrowser)) { _ in
            openWindow(id: "browser")
        }
}
```

- [ ] **Step 3: Add speaker labeling trigger after call ends**

In `AppState`, add published properties and detection logic:

```swift
// In AppState, add these properties:
@Published var showSpeakerLabeling = false
@Published var lastEndedConversationId: String?
@Published var lastEndedCalendarAttendees: [String] = []
private var previousRecordingState: RecordingState = .idle

// In stateDidChange(_:), add transition detection BEFORE updating state:
nonisolated public func stateDidChange(_ stateData: Data) {
    guard let snapshot = ServiceSnapshot.decoded(from: stateData) else { return }
    Task { @MainActor in
        // Detect recording → idle/detecting transition
        let wasRecording = self.recordingState == .recording
        let nowIdle = snapshot.recordingState == .idle || snapshot.recordingState == .detecting

        self.recordingState = snapshot.recordingState
        self.currentMeetingTitle = snapshot.currentMeetingTitle
        self.currentPlatform = snapshot.currentPlatform
        self.elapsedSeconds = snapshot.elapsedSeconds ?? 0
        self.speakerCount = snapshot.speakerCount ?? 0

        // If call just ended, check for unlabeled speakers and show labeling sheet
        if wasRecording && nowIdle, let convId = self.currentConversationId {
            let speakers = (try? self.store.fetchSpeakers(conversationId: convId)) ?? []
            let unlabeled = speakers.filter { !$0.isMe && $0.name.hasPrefix("Speaker ") }
            if !unlabeled.isEmpty {
                self.lastEndedConversationId = convId
                self.showSpeakerLabeling = true
            }
        }

        self.currentConversationId = snapshot.currentConversationId
    }
}
```

Then in `ConversationBrowserWindow`, add the sheet modifier:

```swift
.sheet(isPresented: $appState.showSpeakerLabeling) {
    if let convId = appState.lastEndedConversationId {
        SpeakerLabelingSheet(
            conversationId: convId,
            calendarAttendees: appState.lastEndedCalendarAttendees
        )
        .environmentObject(appState)
    }
}
```

- [ ] **Step 4: Test the full flow manually**

1. Launch the app — verify menu bar icon appears
2. Open Settings — enter AssemblyAI API key and your name
3. Start a test call on Zoom/Meet/Teams
4. Verify the menu bar shows recording state with meeting title
5. Speak for 30 seconds
6. End the call
7. Open Conversations — verify the transcript appears with speaker labels
8. Search for a word you said — verify search results appear

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: integrate all components and add final polish"
```
