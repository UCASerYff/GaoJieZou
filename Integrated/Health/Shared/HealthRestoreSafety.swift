import Foundation

/// Restoring a health save may restore its island, but must not reopen already
/// consumed record/request/sleep reward identities against the newer shared journal.
enum HealthRestoreSafety {
    static func retainingReceipts(incoming: HealthState, current: HealthState) -> HealthState {
        var result = incoming
        result.requests.formUnion(current.requests)
        result.island.rewardedSleepIDs.formUnion(current.island.rewardedSleepIDs)
        for (day, used) in current.ledgers {
            var kept = result.ledgers[day] ?? DailyLedger()
            kept.water = max(kept.water, used.water)
            kept.food = max(kept.food, used.food)
            kept.activity = max(kept.activity, used.activity)
            kept.sleepEnergy = max(kept.sleepEnergy, used.sleepEnergy)
            kept.welcomed = kept.welcomed || used.welcomed
            kept.supplies = max(kept.supplies, used.supplies)
            kept.harvested = kept.harvested || used.harvested
            kept.teaUses = max(kept.teaUses, used.teaUses)
            result.ledgers[day] = kept
        }
        let ineligible = Set(current.records.filter { !$0.rewardEligible }.map(\.id))
        for index in result.records.indices where ineligible.contains(result.records[index].id) {
            result.records[index].rewardEligible = false
        }
        return result
    }
}
