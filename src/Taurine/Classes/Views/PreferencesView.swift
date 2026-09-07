// Derived from Caffeine by Dominic Rodemer. See LICENSE.
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var viewModel: TaurineViewModel
    @AppStorage(PreferenceKeys.defaultDuration) private var defaultDuration = 0
    @AppStorage(PreferenceKeys.activateAtLaunch) private var activateAtLaunch = false
    @AppStorage(PreferenceKeys.suppressLaunchMessage) private var suppressLaunchMessage = false
    @AppStorage(PreferenceKeys.keepAppsActive) private var keepAppsActive = false
    @AppStorage(PreferenceKeys.batteryThreshold) private var batteryThreshold = BatteryPolicy.defaultThreshold

    @AppStorage(PreferenceKeys.batteryProtectionEnabled) private var batteryProtectionEnabled = true

    @AppStorage(PreferenceKeys.playActivationSound) private var playActivationSound = true

    @State private var thresholdText = ""
    @FocusState private var thresholdIsFocused: Bool

    private func commitThreshold() {
        if let value = Int(self.thresholdText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            self.batteryThreshold = BatteryPolicy.threshold(value)
        }
        self.thresholdText = String(BatteryPolicy.threshold(self.batteryThreshold))
    }

    private var helperHeadline: LocalizedStringKey {
        guard self.viewModel.needsHelper else { return "Helper installed" }
        return self.viewModel.helperOutdated ? "Helper needs an update" : "Helper not installed"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable()
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Taurine").font(.title2.bold())
                    Text("Keep your Mac awake, with a little peace of mind.")
                        .foregroundStyle(.secondary)
                    Text("Right-click (or ⌃-click) the menu bar icon to show the Taurine menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text("Battery protection")
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize()
                    Slider(value: Binding(
                        get: { Double(BatteryPolicy.threshold(self.batteryThreshold)) },
                        set: { value in
                            self.batteryThreshold = BatteryPolicy.threshold(Int(value.rounded()))
                            self.thresholdText = String(self.batteryThreshold)
                        }
                    ), in: 1...100, onEditingChanged: { editing in
                        if editing {
                            self.commitThreshold()
                            self.thresholdIsFocused = false
                        }
                    })
                    .tint(.primary)
                    .accessibilityLabel(Text("Battery cutoff"))
                    .accessibilityValue(Text("\(BatteryPolicy.threshold(self.batteryThreshold))%"))
                    HStack(spacing: 5) {
                        BatteryLevelIcon(percentage: BatteryPolicy.threshold(self.batteryThreshold))
                        HStack(spacing: 3) {
                            TextField("", text: Binding(
                                get: { self.thresholdText },
                                set: { self.thresholdText = BatteryPolicy.sanitizedThresholdText($0) }
                            ))
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .multilineTextAlignment(.trailing)
                                .frame(width: 29)
                                .focused(self.$thresholdIsFocused)
                                .accessibilityLabel(Text("Battery cutoff percentage"))
                                .help(Text("Enter a number from 1 to 100. Press Return to apply."))
                                .onSubmit {
                                    self.commitThreshold()
                                    self.thresholdIsFocused = false
                                }
                                .onExitCommand {
                                    self.thresholdText = String(BatteryPolicy.threshold(self.batteryThreshold))
                                    self.thresholdIsFocused = false
                                }
                            Text("%").font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(.background.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(self.thresholdIsFocused ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 1))
                    }
                }
                .disabled(!self.batteryProtectionEnabled)
                Text("While on battery, turn off sleep protection at or below this level. Taurine stays off until you turn it on again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Toggle("Battery protection", isOn: self.$batteryProtectionEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.caption)
                    Spacer()
                    if case let .battery(status) = self.viewModel.batteryReading {
                        BatteryLevelIcon(percentage: status.percentage)
                    }
                    Text(self.viewModel.batteryStatusText)
                        .font(.caption.weight(.medium))
                }
            }
            .padding(20)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 22))

            HStack(spacing: 14) {
                Image(systemName: self.viewModel.needsHelper ? "lock.shield" : "checkmark.shield")
                    .font(.title2)
                    .foregroundStyle(self.viewModel.needsHelper ? Color.secondary : Color.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.helperHeadline)
                        .font(.headline)
                    Text(self.viewModel.needsHelper
                         ? "Taurine needs a small system helper to keep the Mac awake with the lid closed. Installing it asks for your password once. The helper restores sleep whenever Taurine quits, crashes, or the Mac restarts."
                         : "Toggles, timers and battery protection work without password prompts. Sleep is restored automatically if Taurine quits unexpectedly or the Mac restarts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if self.viewModel.installingHelper {
                    ProgressView().controlSize(.small)
                } else if self.viewModel.needsHelper {
                    Button(self.viewModel.helperOutdated ? "Update helper…" : "Install helper…") { self.viewModel.installHelper() }
                        .disabled(self.viewModel.isBusy)
                } else {
                    Button("Remove helper…") { self.viewModel.removeHelper() }
                        .disabled(self.viewModel.isBusy)
                }
            }

            Divider()
            HStack {
                Text("Default duration:")
                Picker("", selection: self.$defaultDuration) {
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("2 hours").tag(120)
                    Text("5 hours").tag(300)
                    Text("Indefinitely").tag(0)
                }
                .labelsHidden()
                .frame(width: 170)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Activate when starting Taurine", isOn: self.$activateAtLaunch)
                Toggle("Show this message when starting Taurine", isOn: Binding(
                    get: { !self.suppressLaunchMessage },
                    set: { self.suppressLaunchMessage = !$0 }
                ))
                Toggle("Play a quiet sound when activating Taurine", isOn: self.$playActivationSound)
                Toggle("Keep apps active", isOn: Binding(
                    get: { self.keepAppsActive },
                    set: { value in
                        self.keepAppsActive = value
                        self.viewModel.updateActivitySimulation(enabled: value)
                    }
                ))
                Text("Prevents apps from becoming inactive and the screen saver from starting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Quit") { NSApp.terminate(nil) }
                    .disabled(self.viewModel.isBusy)
                Text("Sleep protection runs while Taurine is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { NSApp.keyWindow?.close() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { self.thresholdText = String(BatteryPolicy.threshold(self.batteryThreshold)) }
        .onChange(of: self.thresholdIsFocused) {
            if !self.thresholdIsFocused { self.commitThreshold() }
        }
        .onChange(of: self.batteryProtectionEnabled) {
            self.viewModel.batteryThresholdChanged()
        }
        .onChange(of: self.batteryThreshold) {
            if !self.thresholdIsFocused { self.thresholdText = String(BatteryPolicy.threshold(self.batteryThreshold)) }
            self.viewModel.batteryThresholdChanged()
        }
    }
}

