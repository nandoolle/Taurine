// Derived from Caffeine by Dominic Rodemer. See LICENSE.
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var viewModel: TaurineViewModel
    @AppStorage(PreferenceKeys.defaultDuration) private var defaultDuration = 0
    @AppStorage(PreferenceKeys.activateAtLaunch) private var activateAtLaunch = false
    @AppStorage(PreferenceKeys.keepAppsActive) private var keepAppsActive = false
    @AppStorage(PreferenceKeys.batteryThreshold) private var batteryThreshold = BatteryPolicy.defaultThreshold

    @AppStorage(PreferenceKeys.batteryProtectionEnabled) private var batteryProtectionEnabled = true

    @AppStorage(PreferenceKeys.playActivationSound) private var playActivationSound = true

    @State private var thresholdText = ""
    // O estado real do item de login vive no sistema — o usuário pode revogá-lo
    // em Ajustes do Sistema — então é lido de lá, não de UserDefaults.
    @State private var launchAtStartup = LaunchAtStartup.isEnabled
    @State private var launchAtStartupError: String?
    @FocusState private var thresholdIsFocused: Bool

    private func setLaunchAtStartup(_ enabled: Bool) {
        do {
            try LaunchAtStartup.setEnabled(enabled)
            self.launchAtStartupError = nil
        } catch {
            self.launchAtStartupError = error.localizedDescription
        }
        // Relê do sistema: um registro recusado deixaria o toggle mentindo.
        self.launchAtStartup = LaunchAtStartup.isEnabled
    }

    private func commitThreshold() {
        if let value = Int(self.thresholdText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            self.batteryThreshold = BatteryPolicy.threshold(value)
        }
        self.thresholdText = String(BatteryPolicy.threshold(self.batteryThreshold))
    }

    /// A troca acontece no ciclo seguinte: no mesmo ciclo o AppKit ainda não
    /// terminou de eleger o novo primeiro responder e a limpeza é desfeita.
    private func clearFirstResponder() {
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private var strokeColor: Color {
        guard self.batteryProtectionEnabled else { return .secondary.opacity(0.25) }
        return self.thresholdIsFocused ? .accentColor : .secondary.opacity(0.5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable()
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Taurine").font(.title2.bold())
                    Text("The extra energy your Mac needs to never fall asleep.")
                        .foregroundStyle(.secondary)
                    Text("Right-click (or ⌃-click) the menu bar icon to show the Taurine menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    // O toggle abre a linha: antes havia um segundo controle
                    // "Battery protection" abaixo, repetindo o mesmo rótulo.
                    Toggle("", isOn: Binding(
                        get: { self.batteryProtectionEnabled },
                        set: { value in
                            self.batteryProtectionEnabled = value
                            // Religar a seção faz o AppKit eleger o slider como
                            // primeiro responder: devolvemos o foco à janela.
                            if value { self.clearFirstResponder() }
                        }
                    ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .accessibilityLabel(Text("Battery protection"))
                    Text("Battery protection")
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize()
                        .foregroundStyle(self.batteryProtectionEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    Group {
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
                            // `disabled` esmaece o label e o slider, mas não a cor de
                            // texto de um TextField: sem isto o número e o "%"
                            // continuariam em contraste cheio com o box desativado.
                            .foregroundStyle(self.batteryProtectionEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(.background.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(self.strokeColor, lineWidth: 1))
                        }
                    }
                    // Só o slider e o campo desabilitam: o toggle que os controla
                    // tem de seguir clicável.
                    .disabled(!self.batteryProtectionEnabled)
                    // O slider é o único controle focável da linha, então o AppKit
                    // o elege primeiro responder e desenha um anel permanente. O
                    // efeito é de ambiente: aplicado no controle não surte efeito,
                    // tem de envolver a hierarquia.
                    .focusEffectDisabled()
                }
                Text("Give your Mac a break at this battery level. No more Taurine until you open another can.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 22))

            // Só aparece quando há algo a fazer: aprovar o Taurine nos Ajustes do
            // Sistema. Fora disso o componente privilegiado é invisível ao usuário.
            if self.viewModel.helperRequiresApproval {
                HStack(spacing: 14) {
                    Image(systemName: "exclamationmark.shield")
                        .font(.title2)
                        .foregroundStyle(Color.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Taurine needs your approval")
                            .font(.headline)
                        Text("Enable Taurine in System Settings → General → Login Items & Extensions so it can keep your Mac awake.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button("Open System Settings…") { self.viewModel.openHelperSystemSettings() }
                        .keyboardShortcut(.defaultAction)
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
                Toggle("Launch at startup", isOn: Binding(
                    get: { self.launchAtStartup },
                    set: { self.setLaunchAtStartup($0) }
                ))
                if let launchAtStartupError = self.launchAtStartupError {
                    Text(launchAtStartupError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Activate when starting Taurine", isOn: self.$activateAtLaunch)
                Toggle("Play a quiet sound when activating Taurine", isOn: self.$playActivationSound)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Toggle("Keep apps active", isOn: Binding(
                        get: { self.keepAppsActive },
                        set: { value in
                            self.keepAppsActive = value
                            self.viewModel.updateActivitySimulation(enabled: value)
                        }
                    ))
                    .fixedSize()
                    Text("Prevents apps from becoming inactive and the screen saver from starting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        // A faixa da barra de título já ocupa ~28pt acima do conteúdo; sem
        // descontá-los, a margem superior ficaria o dobro da inferior.
        .padding(.top, -14)
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

