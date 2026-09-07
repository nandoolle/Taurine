import SwiftUI

/// SF Symbols supplies five battery fill levels. Show the nearest one while
/// keeping the exact percentage in the adjacent text.
struct BatteryLevelIcon: View {
    let percentage: Int

    var body: some View {
        let level = Int((Double(min(100, max(0, self.percentage))) / 25).rounded()) * 25
        Image(systemName: "battery.\(level)percent")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(width: 23)
            .accessibilityHidden(true)
    }
}
