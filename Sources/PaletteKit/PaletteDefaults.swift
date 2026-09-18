import Foundation
import Observation

@MainActor @Observable
package final class PaletteDefaults {
    package private(set) var values: (limit: Int, mergeDistance: Double, subjectOnly: Bool)
    @ObservationIgnored private let preferences: UserDefaults

    package init(preferences: UserDefaults) {
        self.preferences = preferences
        let saved = preferences.dictionary(forKey: "analysisDefaults") ?? [:]
        let limit = saved["limit"] as? Int ?? 3
        let merge = saved["mergeDistance"] as? Double ?? 0.08
        values = ((2...6).contains(limit) ? limit : 3,
                  merge.isFinite && (0.03...0.16).contains(merge) ? merge : 0.08,
                  saved["subjectOnly"] as? Bool ?? true)
    }

    package func save(limit: Int, mergeDistance: Double, subjectOnly: Bool) {
        preferences.set(["limit": limit, "mergeDistance": mergeDistance, "subjectOnly": subjectOnly], forKey: "analysisDefaults")
        values = (limit, mergeDistance, subjectOnly)
    }
}
