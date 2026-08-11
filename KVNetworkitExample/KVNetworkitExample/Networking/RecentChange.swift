import Foundation

/// One event from the Wikimedia `recentchange` stream.
///
/// Only the fields the demo displays are decoded — the real payload is much larger,
/// and unknown keys are simply ignored by `Decodable`.
struct RecentChange: Decodable, Identifiable {
    struct Meta: Decodable {
        let id: String
        let domain: String
    }

    let meta: Meta
    let type: String
    let title: String
    let user: String
    let bot: Bool

    var id: String { meta.id }

    /// The stream mixes edits, new pages, log entries and bot traffic.
    var isHumanEdit: Bool {
        !bot && (type == "edit" || type == "new")
    }
}
