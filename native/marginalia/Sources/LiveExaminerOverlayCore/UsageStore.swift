import Foundation
import Combine

/// Token counts from a completed LLM call (real API usage or local estimate).
struct LLMTokenUsage: Equatable {
    var promptTokens: Int
    var completionTokens: Int

    static func estimate(promptChars: Int, completionChars: Int) -> LLMTokenUsage {
        LLMTokenUsage(
            promptTokens: max(1, promptChars / 4),
            completionTokens: max(1, completionChars / 4)
        )
    }
}

/// Approximate hosted-model cost tracking for local usage estimates.
enum ModelPricing {
    /// (input $/MTok, output $/MTok)
    static func rates(provider: LLMProvider, model: String) -> (input: Double, output: Double) {
        let m = model.lowercased()
        switch provider {
        case .hosted:
            if m.contains("haiku") { return (0.80, 4.00) }
            if m.contains("opus") { return (15.00, 75.00) }
            // Default: Claude Sonnet-class
            return (3.00, 15.00)
        }
    }

    static func costUSD(
        promptTokens: Int,
        completionTokens: Int,
        provider: LLMProvider,
        model: String
    ) -> Double {
        let rates = rates(provider: provider, model: model)
        let input = Double(promptTokens) / 1_000_000.0 * rates.input
        let output = Double(completionTokens) / 1_000_000.0 * rates.output
        return input + output
    }

    static func defaultModel(for provider: LLMProvider) -> String {
        switch provider {
        case .hosted: return "claude-sonnet-4-6"
        }
    }
}

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    private enum Keys {
        static let requestCount = "usageRequestCount"
        static let approxTokenCount = "usageApproxTokenCount"
        static let startingBalances = "usageStartingBalanceUSDByProvider"
        static let spentBalances = "usageSpentUSDByProvider"
        static let weekKey = "usageWeekKey"
        static let thisWeekTips = "usageThisWeekTips"
        static let lastWeekTips = "usageLastWeekTips"
    }

    @Published private(set) var requestCount: Int
    @Published private(set) var approxTokenCount: Int
    @Published private(set) var thisWeekTips: Int
    @Published private(set) var lastWeekTips: Int
    /// Bumps when any provider balance changes so SwiftUI refreshes.
    @Published private(set) var balanceRevision: Int = 0

    /// Assumed wall-clock seconds of coach use per tip/chat turn.
    private static let secondsPerTip: Double = 45
    /// Assumed revision minutes saved per tip.
    private static let minutesSavedPerTip: Double = 12

    private var startingByProvider: [String: Double]
    private var spentByProvider: [String: Double]

    private init() {
        requestCount = UserDefaults.standard.integer(forKey: Keys.requestCount)
        approxTokenCount = UserDefaults.standard.integer(forKey: Keys.approxTokenCount)
        thisWeekTips = UserDefaults.standard.integer(forKey: Keys.thisWeekTips)
        lastWeekTips = UserDefaults.standard.integer(forKey: Keys.lastWeekTips)
        startingByProvider = Self.loadUSDMap(Keys.startingBalances)
        spentByProvider = Self.loadUSDMap(Keys.spentBalances)
        rollWeekIfNeeded()
    }

    /// Approximate hours spent generating tips/chat on this Mac.
    var hoursUsed: Double {
        Double(requestCount) * Self.secondsPerTip / 3600.0
    }

    /// Approximate hours of revision time saved by tips on this Mac.
    var hoursSaved: Double {
        Double(requestCount) * Self.minutesSavedPerTip / 60.0
    }

    var tipsUsed: Int { requestCount }

    /// Week-over-week tip change as a fraction (0.5 = +50%). Nil when no last-week baseline.
    var tipsWeekDeltaFraction: Double? {
        rollWeekIfNeeded()
        guard lastWeekTips > 0 else { return thisWeekTips > 0 ? 1.0 : nil }
        return Double(thisWeekTips - lastWeekTips) / Double(lastWeekTips)
    }

    func formatHours(_ hours: Double) -> String {
        if hours < 0.1 {
            let minutes = Int((hours * 60).rounded())
            return "\(minutes)m"
        }
        if hours < 10 {
            return String(format: "%.1fh", hours)
        }
        return String(format: "%.0fh", hours)
    }

    func formatDeltaPercent(_ fraction: Double?) -> String? {
        guard let fraction else { return nil }
        return String(format: "%.0f%%", abs(fraction * 100))
    }

    private func currentWeekKey() -> String {
        let cal = Calendar.current
        let now = Date()
        let year = cal.component(.yearForWeekOfYear, from: now)
        let week = cal.component(.weekOfYear, from: now)
        return String(format: "%04d-W%02d", year, week)
    }

    private func rollWeekIfNeeded() {
        let key = currentWeekKey()
        let stored = UserDefaults.standard.string(forKey: Keys.weekKey) ?? ""
        guard stored != key else { return }
        if !stored.isEmpty {
            lastWeekTips = thisWeekTips
            UserDefaults.standard.set(lastWeekTips, forKey: Keys.lastWeekTips)
        }
        thisWeekTips = 0
        UserDefaults.standard.set(0, forKey: Keys.thisWeekTips)
        UserDefaults.standard.set(key, forKey: Keys.weekKey)
    }

    // MARK: - Per-provider credit meter

    func supportsCreditMeter(for provider: LLMProvider) -> Bool {
        true
    }

    func hasBalance(for provider: LLMProvider) -> Bool {
        guard supportsCreditMeter(for: provider) else { return false }
        return startingBalance(for: provider) > 0
    }

    func startingBalance(for provider: LLMProvider) -> Double {
        startingByProvider[provider.rawValue] ?? 0
    }

    func spentUSD(for provider: LLMProvider) -> Double {
        spentByProvider[provider.rawValue] ?? 0
    }

    func remainingUSD(for provider: LLMProvider) -> Double {
        max(0, startingBalance(for: provider) - spentUSD(for: provider))
    }

    /// 1.0 = full balance left, 0.0 = depleted. 0 when no starting balance set.
    func remainingFraction(for provider: LLMProvider) -> Double {
        let start = startingBalance(for: provider)
        guard start > 0 else { return 0 }
        return min(1, max(0, remainingUSD(for: provider) / start))
    }

    func remainingPercent(for provider: LLMProvider) -> Int {
        Int((remainingFraction(for: provider) * 100).rounded())
    }

    /// Set the current console balance as the new budget (spent resets to 0).
    func setBalance(_ amount: Double, for provider: LLMProvider) {
        guard supportsCreditMeter(for: provider) else { return }
        let clamped = max(0, amount)
        startingByProvider[provider.rawValue] = clamped
        spentByProvider[provider.rawValue] = 0
        persistBalances()
        balanceRevision &+= 1
        dlog("[Usage] setBalance provider=\(provider.rawValue) usd=\(clamped)")
    }

    /// Record spend from token usage (preferred) after a successful tip/chat.
    func recordSpend(
        promptTokens: Int,
        completionTokens: Int,
        provider: LLMProvider,
        model: String
    ) {
        requestCount += 1
        approxTokenCount += max(0, promptTokens) + max(0, completionTokens)
        UserDefaults.standard.set(requestCount, forKey: Keys.requestCount)
        UserDefaults.standard.set(approxTokenCount, forKey: Keys.approxTokenCount)

        rollWeekIfNeeded()
        thisWeekTips += 1
        UserDefaults.standard.set(thisWeekTips, forKey: Keys.thisWeekTips)

        guard supportsCreditMeter(for: provider), hasBalance(for: provider) else {
            balanceRevision &+= 1
            return
        }

        let cost = ModelPricing.costUSD(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            provider: provider,
            model: model
        )
        spentByProvider[provider.rawValue] = spentUSD(for: provider) + cost
        persistBalances()
        balanceRevision &+= 1
        dlog("[Usage] spend provider=\(provider.rawValue) cost=\(String(format: "%.6f", cost)) remaining=\(String(format: "%.4f", remainingUSD(for: provider)))")
    }

    /// Convenience when only character counts are available.
    func record(
        promptChars: Int,
        completionChars: Int,
        provider: LLMProvider,
        model: String = ""
    ) {
        let tokens = LLMTokenUsage.estimate(promptChars: promptChars, completionChars: completionChars)
        let resolvedModel = model.isEmpty ? ModelPricing.defaultModel(for: provider) : model
        recordSpend(
            promptTokens: tokens.promptTokens,
            completionTokens: tokens.completionTokens,
            provider: provider,
            model: resolvedModel
        )
    }

    func reset(for provider: LLMProvider? = nil) {
        if let provider {
            startingByProvider[provider.rawValue] = 0
            spentByProvider[provider.rawValue] = 0
        } else {
            startingByProvider = [:]
            spentByProvider = [:]
            requestCount = 0
            approxTokenCount = 0
            thisWeekTips = 0
            lastWeekTips = 0
            UserDefaults.standard.set(0, forKey: Keys.requestCount)
            UserDefaults.standard.set(0, forKey: Keys.approxTokenCount)
            UserDefaults.standard.set(0, forKey: Keys.thisWeekTips)
            UserDefaults.standard.set(0, forKey: Keys.lastWeekTips)
        }
        persistBalances()
        balanceRevision &+= 1
    }

    // MARK: - Persistence

    private func persistBalances() {
        UserDefaults.standard.set(startingByProvider, forKey: Keys.startingBalances)
        UserDefaults.standard.set(spentByProvider, forKey: Keys.spentBalances)
    }

    private static func loadUSDMap(_ key: String) -> [String: Double] {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) else { return [:] }
        var out: [String: Double] = [:]
        for (k, v) in raw {
            if let d = v as? Double {
                out[k] = d
            } else if let n = v as? NSNumber {
                out[k] = n.doubleValue
            }
        }
        return out
    }
}
