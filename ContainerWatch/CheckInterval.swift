import Foundation

enum IntervalPreset: String, CaseIterable, Identifiable {
    case min5, min15, min30, hour1, day1, week1, month1, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .min5: "5 minutes"
        case .min15: "15 minutes"
        case .min30: "30 minutes"
        case .hour1: "1 hour"
        case .day1: "1 day"
        case .week1: "1 week"
        case .month1: "1 month"
        case .custom: "Custom…"
        }
    }

    /// `nil` for `.custom`, whose length comes from the user's value and unit.
    var seconds: TimeInterval? {
        switch self {
        case .min5: 5 * 60
        case .min15: 15 * 60
        case .min30: 30 * 60
        case .hour1: 3_600
        case .day1: 86_400
        case .week1: 7 * 86_400
        case .month1: 30 * 86_400
        case .custom: nil
        }
    }
}

enum IntervalUnit: String, CaseIterable, Identifiable {
    case minutes, hours, days, weeks

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var seconds: TimeInterval {
        switch self {
        case .minutes: 60
        case .hours: 3_600
        case .days: 86_400
        case .weeks: 7 * 86_400
        }
    }
}
