import CloudKit
import CryptoKit
import Foundation

/// Tokenroom's records in the user's private CloudKit database, zone "Tokenroom".
///
/// - `Source`: one per collector (a Mac, or an iPhone with API keys). Only that collector writes it,
///   so saves never conflict. `payload` is a JSON `RelayEnvelope`.
/// - `History`: that collector's hourly usage for the last week (`hist-<source>`), sent hourly.
/// - `Event`: an alert (threshold crossed, test). The iPhone's query subscription turns each new
///   one into a visible notification, even when the app isn't running.
/// - `Prefs`: the alert preferences (`prefs-alerts`), shared by the iPhone and Macs; the newer copy wins.
///
/// Widgets and the Watch only read; their builds leave the write methods out
/// (`TOKENROOM_RELAY_READONLY`).
actor CloudRelay {
    enum RecordType {
        static let source = "Source"
        static let history = "History"
        static let event = "Event"
        static let prefs = "Prefs"
    }

    static let alertPreferencesRecord = "prefs-alerts"
    /// Alert records older than this are deleted; the notification went out long ago.
    static let eventLifetime: TimeInterval = 14 * 86_400

    enum Field {
        /// A plain field, not `encryptedValues`: it holds usage numbers, names, and reset times
        /// only, and encrypted fields are lost if the account's keys are reset.
        static let payload = "payload"
        static let kind = "kind"
        static let label = "label"
        static let checkedAt = "checkedAt"
        static let schema = "schema"
        static let appVersion = "appVersion"
        static let provider = "provider"
        static let level = "level"
        static let title = "title"
        static let body = "body"
        static let resetsAt = "resetsAt"
        static let alertKind = "alertKind"
        /// `UsageAlert.key`, e.g. `threshold-80`; the iPhone's subscription filters on it.
        static let alertKey = "alertKey"
    }

    static let zoneID = CKRecordZone.ID(zoneName: "Tokenroom", ownerName: CKCurrentUserDefaultName)

    /// Everything readers need from the zone.
    struct Contents: Sendable {
        var sources: [Source]
        /// Keyed by source ID.
        var histories: [String: RelayHistory]
        var alertPreferences: AlertPreferences? = nil
        /// Alert record names and when each was created, for pruning.
        var events: [(id: String, createdAt: Date?)] = []
    }

    struct Source: Sendable, Identifiable {
        var id: String
        var kind: String
        var label: String
        var modifiedAt: Date?
        /// Nil when the payload is damaged or from a newer format this build can't read.
        var envelope: RelayEnvelope?
        var needsNewerApp: Bool
    }

    let containerIdentifier: String
    private let container: CKContainer
    private var zoneReady = false

    private var database: CKDatabase {
        container.privateCloudDatabase
    }

    /// Only call when `RelayAvailability` reports the container; CloudKit traps without the entitlement.
    init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
        container = CKContainer(identifier: containerIdentifier)
    }

    func accountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    /// Short, one-way fingerprint of this container's anonymous user ID. Two devices on the same
    /// iCloud account show the same value; used only in diagnostics, never stored in records.
    func accountFingerprint() async throws -> String {
        let id = try await container.userRecordID().recordName
        return SHA256.hash(data: Data(id.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func historyRecordName(for sourceID: String) -> String {
        "hist-\(sourceID)"
    }

    /// The shared alert preferences, or nil before either device has saved any.
    func alertPreferences() async throws -> AlertPreferences? {
        do {
            let record = try await database.record(for: CKRecord.ID(recordName: Self.alertPreferencesRecord, zoneID: Self.zoneID))
            return (record[Field.payload] as? Data).flatMap { try? RelayEnvelope.decoder.decode(AlertPreferences.self, from: $0) }
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }

    /// Every source and history in the zone. A handful of small records, so no change tokens are kept.
    func contents() async throws -> Contents {
        var sources: [Source] = []
        var histories: [String: RelayHistory] = [:]
        var preferences: AlertPreferences?
        var events: [(id: String, createdAt: Date?)] = []
        var token: CKServerChangeToken?
        do {
            while true {
                let changes = try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: token)
                for (_, modification) in changes.modificationResultsByID {
                    guard case .success(let change) = modification else { continue }
                    let record = change.record
                    switch record.recordType {
                    case RecordType.source:
                        sources.append(Self.source(from: record))
                    case RecordType.history:
                        let name = record.recordID.recordName
                        guard name.hasPrefix("hist-"),
                              let data = record[Field.payload] as? Data,
                              let history = try? RelayHistory.decode(data)
                        else { continue }
                        histories[String(name.dropFirst("hist-".count))] = history
                    case RecordType.prefs where record.recordID.recordName == Self.alertPreferencesRecord:
                        preferences = (record[Field.payload] as? Data).flatMap { try? RelayEnvelope.decoder.decode(AlertPreferences.self, from: $0) }
                    case RecordType.event:
                        events.append((record.recordID.recordName, record.creationDate))
                    default:
                        continue
                    }
                }
                token = changes.changeToken
                if !changes.moreComing { break }
            }
        } catch let error as CKError where error.code == .zoneNotFound {
            return Contents(sources: [], histories: [:])
        }
        return Contents(sources: sources, histories: histories, alertPreferences: preferences, events: events)
    }

    func sources() async throws -> [Source] {
        try await contents().sources
    }

    private static func source(from record: CKRecord) -> Source {
        var envelope: RelayEnvelope?
        var needsNewerApp = false
        if let data = record[Field.payload] as? Data, let decoded = try? RelayEnvelope.decode(data) {
            if decoded.isReadable {
                envelope = decoded
            } else {
                needsNewerApp = true
            }
        }
        return Source(
            id: record.recordID.recordName,
            kind: record[Field.kind] as? String ?? "mac",
            label: record[Field.label] as? String ?? "Mac",
            modifiedAt: record.modificationDate,
            envelope: envelope,
            needsNewerApp: needsNewerApp
        )
    }
}

#if !TOKENROOM_RELAY_READONLY
// Writes: the Mac and the iPhone app only.
extension CloudRelay {
    func publish(sourceID: String, kind: String, label: String, envelope: RelayEnvelope) async throws {
        let record = CKRecord(
            recordType: RecordType.source,
            recordID: CKRecord.ID(recordName: sourceID, zoneID: Self.zoneID)
        )
        record[Field.payload] = try envelope.encoded()
        record[Field.kind] = kind
        record[Field.label] = label
        record[Field.checkedAt] = envelope.checkedAt
        record[Field.schema] = envelope.v
        record[Field.appVersion] = envelope.appVersion
        try await save([record])
    }

    func publishHistory(sourceID: String, history: RelayHistory) async throws {
        let record = CKRecord(
            recordType: RecordType.history,
            recordID: CKRecord.ID(recordName: Self.historyRecordName(for: sourceID), zoneID: Self.zoneID)
        )
        record[Field.payload] = try history.encoded()
        record[Field.schema] = history.v
        try await save([record])
    }

    /// Saves an alert. Saving an ID that already exists updates it without a second notification,
    /// because the iPhone's subscription fires only when a record is created.
    func saveAlert(_ alert: UsageAlert) async throws {
        try await saveEvent(id: alert.id, provider: alert.provider, level: alert.level, title: alert.title, body: alert.body, resetsAt: alert.resetsAt, kind: alert.kind.rawValue, key: alert.key)
    }

    func publishAlertPreferences(_ preferences: AlertPreferences) async throws {
        let record = CKRecord(recordType: RecordType.prefs, recordID: CKRecord.ID(recordName: Self.alertPreferencesRecord, zoneID: Self.zoneID))
        record[Field.payload] = try RelayEnvelope.encoder.encode(preferences)
        try await save([record])
    }

    func deleteRecords(named names: [String]) async throws {
        guard !names.isEmpty else { return }
        _ = try await database.modifyRecords(
            saving: [],
            deleting: names.map { CKRecord.ID(recordName: $0, zoneID: Self.zoneID) }
        )
    }

    /// Record names are deterministic, so two Macs seeing the same crossing create one alert.
    func saveEvent(
        id: String,
        provider: String,
        level: Int,
        title: String,
        body: String,
        resetsAt: Date? = nil,
        kind: String = "test",
        key: String = "test"
    ) async throws {
        try await save([Self.eventRecord(id: id, provider: provider, level: level, title: title, body: body, resetsAt: resetsAt, kind: kind, key: key)])
    }

    private static func eventRecord(
        id: String, provider: String, level: Int, title: String, body: String, resetsAt: Date?, kind: String, key: String
    ) -> CKRecord {
        let record = CKRecord(recordType: RecordType.event, recordID: CKRecord.ID(recordName: id, zoneID: zoneID))
        record[Field.provider] = provider
        record[Field.level] = level
        record[Field.title] = title
        record[Field.body] = body
        record[Field.resetsAt] = resetsAt
        record[Field.alertKind] = kind
        record[Field.alertKey] = key
        return record
    }

    func deleteAllData() async throws {
        _ = try await database.modifyRecordZones(saving: [], deleting: [Self.zoneID])
        zoneReady = false
    }

    /// `.allKeys` replaces a record with the same name; `.ifServerRecordUnchanged` only creates.
    private func save(_ records: [CKRecord], policy: CKModifyRecordsOperation.RecordSavePolicy = .allKeys) async throws {
        try await ensureZone()
        do {
            try await modify(records, policy: policy)
        } catch let error as CKError where error.code == .zoneNotFound {
            zoneReady = false
            try await ensureZone()
            try await modify(records, policy: policy)
        }
    }

    private func modify(_ records: [CKRecord], policy: CKModifyRecordsOperation.RecordSavePolicy) async throws {
        let results = try await database.modifyRecords(
            saving: records,
            deleting: [],
            savePolicy: policy,
            atomically: true
        )
        for (_, result) in results.saveResults {
            if case .failure(let error) = result {
                throw error
            }
        }
    }

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        let results = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
        for (_, result) in results.saveResults {
            if case .failure(let error) = result {
                throw error
            }
        }
        zoneReady = true
    }
}
#endif

#if os(iOS) && !TOKENROOM_RELAY_READONLY
extension CloudRelay {
    static let changesSubscriptionID = "tokenroom-sources"
    static let alertsSubscriptionID = "tokenroom-alerts"

    /// Silent pushes when any source changes; visible notifications for new alert events of the
    /// kinds in `alertKeys` (`UsageAlert.key` values). Saving the same IDs again replaces them, so
    /// this is safe on every launch and whenever the alert preferences change. Returns whether the
    /// alert subscription filters by kind (false while `alertKey` isn't queryable yet).
    @discardableResult
    func ensureSubscriptions(alertKeys: [String]) async throws -> Bool {
        try await ensureZone()

        let changes = CKRecordZoneSubscription(zoneID: Self.zoneID, subscriptionID: Self.changesSubscriptionID)
        changes.recordType = RecordType.source
        let silent = CKSubscription.NotificationInfo()
        silent.shouldSendContentAvailable = true
        changes.notificationInfo = silent
        try await saveSubscriptions([changes])

        // Filtering needs `alertKey` to be queryable in the schema. Until it is, every alert
        // comes through and the sending device filters by the same preferences.
        do {
            try await saveSubscriptions([alertSubscription(NSPredicate(format: "%K IN %@", Field.alertKey, alertKeys))])
            return true
        } catch let error as CKError where error.code == .invalidArguments || error.code == .serverRejectedRequest {
            // What CloudKit says when the schema can't query `alertKey` yet. Other errors
            // (offline, busy) are thrown, to be retried with the filter.
            try await saveSubscriptions([alertSubscription(NSPredicate(value: true))])
            return false
        }
    }

    /// Before this iPhone shows an alert itself: creates the alert's record, under `shownKey`,
    /// only if no device has yet. False when another device's record is already there, meaning
    /// its notification reached this iPhone. A Mac that sees the same crossing later saves over
    /// this record, and an update sends no notification, so the alert shows once.
    func claimAlert(_ alert: UsageAlert) async throws -> Bool {
        let record = Self.eventRecord(id: alert.id, provider: alert.provider, level: alert.level, title: alert.title, body: alert.body,
                                      resetsAt: alert.resetsAt, kind: alert.kind.rawValue, key: alert.shownKey)
        do {
            try await save([record], policy: .ifServerRecordUnchanged)
            return true
        } catch let error as CKError where error.code == .serverRecordChanged {
            return false
        }
    }

    private func alertSubscription(_ predicate: NSPredicate) -> CKQuerySubscription {
        let alerts = CKQuerySubscription(
            recordType: RecordType.event,
            predicate: predicate,
            subscriptionID: Self.alertsSubscriptionID,
            options: [.firesOnRecordCreation]
        )
        alerts.zoneID = Self.zoneID
        let visible = CKSubscription.NotificationInfo()
        // A format-only key makes iOS show the record's own title and body.
        visible.titleLocalizationKey = "%1$@"
        visible.titleLocalizationArgs = [Field.title]
        visible.alertLocalizationKey = "%1$@"
        visible.alertLocalizationArgs = [Field.body]
        visible.soundName = "default"
        visible.collapseIDKey = Field.provider
        alerts.notificationInfo = visible
        return alerts
    }

    private func saveSubscriptions(_ subscriptions: [CKSubscription]) async throws {
        let results = try await database.modifySubscriptions(saving: subscriptions, deleting: [])
        for (_, result) in results.saveResults {
            if case .failure(let error) = result {
                throw error
            }
        }
    }
}
#endif
