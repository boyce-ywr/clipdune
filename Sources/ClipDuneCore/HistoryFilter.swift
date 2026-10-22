import Foundation

public struct HistoryFilter: Equatable, Sendable {
    public enum Period: String, CaseIterable, Sendable {
        case all, today, yesterday, lastSevenDays, lastThirtyDays

        public var title: String {
            switch self {
            case .all: return "全部时间"
            case .today: return "今天"
            case .yesterday: return "昨天"
            case .lastSevenDays: return "最近 7 天"
            case .lastThirtyDays: return "最近 30 天"
            }
        }
    }

    public var kind: ClipKind?
    public var period: Period

    public init(kind: ClipKind? = nil, period: Period = .all) {
        self.kind = kind
        self.period = period
    }

    public func dateRange(now: Date, calendar: Calendar = .current) -> DateInterval? {
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
        switch period {
        case .all: return nil
        case .today: return DateInterval(start: today, end: tomorrow)
        case .yesterday:
            return calendar.date(byAdding: .day, value: -1, to: today).map { DateInterval(start: $0, end: today) }
        case .lastSevenDays, .lastThirtyDays:
            let days = period == .lastSevenDays ? 6 : 29
            return calendar.date(byAdding: .day, value: -days, to: today).map { DateInterval(start: $0, end: tomorrow) }
        }
    }
}
