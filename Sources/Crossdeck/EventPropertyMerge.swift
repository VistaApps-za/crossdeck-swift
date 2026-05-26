// Pure event-property merge — cross-SDK precedence contract.
//
// Phase 3.2 of bank-grade reconciliation v1.4.0. Web/Node/RN all
// use the precedence device < super < caller (each layer overrides
// the prior; caller-supplied properties win). Pre-v1.4.0 Swift had
// it INVERTED (super < device < caller — device overrode super),
// so a `register("plan", "pro")` super-property got clobbered by
// the auto-attached device info on every event. Cross-SDK funnel
// queries on super-property keys returned different answers per
// platform.
//
// Lifted into a pure helper so the precedence is CI-pinned even
// if the call site evolves.

import Foundation

internal enum EventPropertyMerge {
    /// Merge three property bags with the bank-grade precedence:
    ///   caller > super > device
    ///
    /// Iteration order is device → super → caller; each later
    /// pass overwrites prior keys via Swift dictionary subscript
    /// assignment. Matches Web/Node/RN exactly.
    static func merge(
        device: [String: Any],
        superProperties: [String: Any],
        caller: [String: Any]
    ) -> [String: Any] {
        var merged: [String: Any] = [:]
        for (k, v) in device { merged[k] = v }
        for (k, v) in superProperties { merged[k] = v }
        for (k, v) in caller { merged[k] = v }
        return merged
    }
}
