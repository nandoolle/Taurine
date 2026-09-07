import Foundation
import IOKit.ps

struct BatteryStatus: Equatable {
    let percentage: Int
    let isOnBattery: Bool
}

enum BatteryReading: Equatable {
    case battery(BatteryStatus)
    case noBattery
    case unavailable
}

@MainActor
protocol BatteryReadingProvider {
    func read() -> BatteryReading
}

@MainActor
final class SystemBattery: BatteryReadingProvider {
    func read() -> BatteryReading {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return .unavailable }
        var descriptions: [[String: Any]] = []
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            else { return .unavailable }
            descriptions.append(description)
        }
        return Self.parse(descriptions)
    }

    static func parse(_ descriptions: [[String: Any]]) -> BatteryReading {
        let batteries = descriptions.filter { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType }
        guard !batteries.isEmpty else { return .noBattery }
        var readings: [BatteryStatus] = []
        for battery in batteries {
            guard let current = battery[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = battery[kIOPSMaxCapacityKey] as? Int,
                  let state = battery[kIOPSPowerSourceStateKey] as? String,
                  maximum > 0, current >= 0, current <= maximum,
                  state == kIOPSBatteryPowerValue || state == kIOPSACPowerValue
            else { return .unavailable }
            readings.append(BatteryStatus(
                percentage: Int(floor(Double(current) * 100 / Double(maximum))),
                isOnBattery: state == kIOPSBatteryPowerValue
            ))
        }
        return .battery(BatteryStatus(
            percentage: readings.map(\.percentage).min()!,
            isOnBattery: readings.contains { $0.isOnBattery }
        ))
    }
}

enum BatteryPolicy {
    nonisolated static let defaultThreshold = 60
    nonisolated static let range = 1...100

    static func sanitizedThresholdText(_ text: String) -> String {
        let digits = text.filter { $0 >= "0" && $0 <= "9" }
        guard !digits.isEmpty else { return "" }
        return String(Self.threshold(Int(digits) ?? 100))
    }

    static func threshold(_ value: Int) -> Int {
        min(Self.range.upperBound, max(Self.range.lowerBound, value))
    }

    static func stopReason(for reading: BatteryReading, threshold: Int) -> String? {
        switch reading {
        case let .battery(status) where status.isOnBattery && status.percentage <= Self.threshold(threshold):
            return String.localizedStringWithFormat(
                String(localized: "Sleep protection stopped at %d%% battery."), status.percentage
            )
        case .unavailable:
            return String(localized: "Sleep protection stopped because the battery level could not be read.")
        default:
            return nil
        }
    }
}
