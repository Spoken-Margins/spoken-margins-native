import Foundation

/// Which fields of a sync record are encrypted when they leave the device (#1769 decision 2, 2026-11-12): everything
/// the listener wrote or that quotes the source, private curation fields included. The CloudKit mapping (slice 2) reads
/// this list; nothing here encrypts.
public enum SyncFieldSchema {
    /// Fields that stay readable to the server: the delete state and the times that order records.
    public static let plaintextFields: Set<String> = [SyncRecord.statusField, "createdAt"]

    public static func isEncrypted(field: String) -> Bool { !plaintextFields.contains(field) }
}

/// A Margin as a sync record (`margin/<Margin id>`). The Margin belongs to an item key, not to a local item id.
///
/// Fixed at birth: item key, created time, anchor, capture kind. Edited, one register each, merged field by field:
/// `transcript`, `cleanedTranscript`, `displayText`, `privateSharingNote` (text, so a lost race keeps the other
/// version), `status` and `isStarredForSharing`. The recording's path and bytes are not here (slice 5).
public enum MarginSync {
    public static let schemaVersion = 1
    public static let textFields = ["transcript", "cleanedTranscript", "displayText", "privateSharingNote"]
    static let birthFields = ["itemKey", "createdAt", "anchor", "captureKind"]

    public static func record(
        for margin: Interjection, itemKey: String, clock: inout SyncClock, wallMillis: Int64
    ) throws -> SyncRecord {
        var record = SyncRecord(id: .margin(margin.id), schemaVersion: schemaVersion)
        record.set("itemKey", .string(itemKey), clock: &clock, wallMillis: wallMillis)
        record.set("createdAt", .number((margin.createdAt.timeIntervalSince1970 * 1000).rounded()), clock: &clock, wallMillis: wallMillis)
        record.set("anchor", try SyncValue(encoding: margin.anchor), clock: &clock, wallMillis: wallMillis)
        record.set("captureKind", .string((margin.captureKind ?? .audio).rawValue), clock: &clock, wallMillis: wallMillis)
        record.set("status", .string(margin.status), clock: &clock, wallMillis: wallMillis)
        for (name, text) in [
            ("transcript", margin.transcript), ("cleanedTranscript", margin.cleanedTranscript),
            ("displayText", margin.displayText), ("privateSharingNote", margin.privateSharingNote)
        ] {
            if let text { record.set(name, .string(text), clock: &clock, wallMillis: wallMillis) }
        }
        if let starred = margin.isStarredForSharing {
            record.set("isStarredForSharing", .bool(starred), clock: &clock, wallMillis: wallMillis)
        }
        return record
    }

    /// Writes what the listener changed: each editable field of `edited` that differs from `before`, the Margin as it was
    /// when this device last took the record. A field the listener did not touch is not written, so a version waiting
    /// beside it, or a remote edit or delete not yet applied here, is never replaced by a stale copy.
    public static func write(
        _ edited: Interjection, changedFrom before: Interjection, into record: inout SyncRecord, clock: inout SyncClock, wallMillis: Int64
    ) {
        let texts: [(String, String?, String?)] = [
            ("transcript", edited.transcript, before.transcript), ("cleanedTranscript", edited.cleanedTranscript, before.cleanedTranscript),
            ("displayText", edited.displayText, before.displayText), ("privateSharingNote", edited.privateSharingNote, before.privateSharingNote)
        ]
        for (name, text, old) in texts where text != old {
            if let text { record.set(name, .string(text), clock: &clock, wallMillis: wallMillis) }
        }
        if edited.isStarredForSharing != before.isStarredForSharing, let starred = edited.isStarredForSharing {
            record.set("isStarredForSharing", .bool(starred), clock: &clock, wallMillis: wallMillis)
        }
        if edited.status != before.status {
            record.set("status", .string(edited.status), clock: &clock, wallMillis: wallMillis)
        }
    }

    /// Whether the record has what a device needs to show the Margin. A change that arrived before the Margin's own
    /// record (a delete first) holds only some fields and waits.
    public static func isMaterializable(_ record: SyncRecord) -> Bool {
        record.id.kind == "margin" && birthFields.allSatisfy { record[$0] != nil }
    }

    public static func itemKey(of record: SyncRecord) -> String? { record["itemKey"]?.stringValue }

    /// `margin` with the record's editable fields applied. Ids, anchor, recording and everything else stay the device's own.
    public static func apply(_ record: SyncRecord, to margin: Interjection) -> Interjection {
        var margin = margin
        if let value = record["transcript"]?.stringValue { margin.transcript = value }
        if let value = record["cleanedTranscript"]?.stringValue { margin.cleanedTranscript = value }
        if let value = record["displayText"]?.stringValue { margin.displayText = value }
        if let value = record["privateSharingNote"]?.stringValue { margin.privateSharingNote = value }
        if let value = record["isStarredForSharing"]?.boolValue { margin.isStarredForSharing = value }
        if let value = record["status"]?.stringValue { margin.status = value }
        return margin
    }
}

/// A Spoken Note as an item record (`item/spoken-note-<noteId>`, 2026-11-12). Title and text are text fields merged by
/// the Margin rule; the note's takes' audio follows with recordings.
public enum SpokenNoteSync {
    public static let schemaVersion = 1
    public static let textFields = ["title", "text"]

    public static func record(noteId: String, title: String, text: String, createdAt: Date, clock: inout SyncClock, wallMillis: Int64) -> SyncRecord {
        var record = SyncRecord(id: .item(SpokenNoteItem.itemId(forNoteId: noteId)), schemaVersion: schemaVersion)
        record.set("createdAt", .number((createdAt.timeIntervalSince1970 * 1000).rounded()), clock: &clock, wallMillis: wallMillis)
        record.set("title", .string(title), clock: &clock, wallMillis: wallMillis)
        record.set("text", .string(text), clock: &clock, wallMillis: wallMillis)
        record.set(SyncRecord.statusField, .string(SyncRecord.activeStatus), clock: &clock, wallMillis: wallMillis)
        return record
    }

    /// The row to save for a record from another device: `stored` with the record's text, or nil when nothing should be
    /// written. A row the listener moved to the trash stays there (`SpokenNoteItemMerge`): a remote edit never brings it back.
    public static func rowToSave(stored: Item?, record: SyncRecord, noteId: String) -> Item? {
        guard let text = record["text"]?.stringValue, !record.isDeleted else { return nil }
        var incoming = stored ?? Item(
            id: SpokenNoteItem.itemId(forNoteId: noteId), title: record["title"]?.stringValue ?? SpokenNoteItem.defaultTitle,
            mediaType: SpokenNoteItem.mediaType, text: text, externalReference: SpokenNoteItem.reference(forNoteId: noteId),
            status: "ready", externalReferenceType: SpokenNoteItem.referenceType
        )
        incoming.text = text
        return SpokenNoteItemMerge.rowToSave(stored: stored, incoming: incoming, isFirstSave: stored == nil)
    }
}
