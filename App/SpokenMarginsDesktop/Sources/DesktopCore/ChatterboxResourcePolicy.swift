import Foundation

public enum ChatterboxResourcePolicy {
    public static let swapGrowthLimit: UInt64 = 512_000_000
    public static let wallTimeLimit: TimeInterval = 90

    public static func residentLimit(for model: DesktopChatterboxModel, physicalMemory: UInt64) -> UInt64 {
        let ceiling: UInt64 = model == .nano ? 2_500_000_000 : 5_000_000_000
        return min(ceiling, physicalMemory / 3)
    }

    public static func stopReason(model: DesktopChatterboxModel, physicalMemory: UInt64,
                                  residentBytes: UInt64, swapGrowthBytes: UInt64,
                                  elapsed: TimeInterval) -> String? {
        let limit = residentLimit(for: model, physicalMemory: physicalMemory)
        if residentBytes > limit { return "memory exceeded \(limit / 1_000_000) MB" }
        if swapGrowthBytes > swapGrowthLimit { return "system swap grew by more than 512 MB" }
        if elapsed > wallTimeLimit { return "generation took over 90 seconds" }
        return nil
    }

    public static func shouldSuggestNano(model: DesktopChatterboxModel, stopReason: String,
                                         monitoringAvailable: Bool = true) -> Bool {
        guard model == .turbo, monitoringAvailable else { return false }
        let reason = stopReason.lowercased()
        return ["memory exceeded", "swap grew", "over 90 seconds"].contains(where: { reason.contains($0) })
    }
}
