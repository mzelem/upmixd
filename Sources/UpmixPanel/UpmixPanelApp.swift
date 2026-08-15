import SwiftUI
import UpmixCore

@main
struct UpmixPanelApp: App {
    @StateObject private var store = SettingsStore()

    var body: some Scene {
        MenuBarExtra("Upmix", systemImage: "slider.vertical.3") {
            PanelView()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct PanelView: View {
    @EnvironmentObject private var store: SettingsStore

    private let columnWidth: CGFloat = 26
    private let columnSpacing: CGFloat = 6
    private let sliderLength: CGFloat = 110

    private func label(for freq: Double) -> String {
        freq >= 1000 ? "\(Int(freq / 1000))k" : "\(Int(freq))"
    }

    private func bandColumn(_ slot: Int) -> some View {
        let gain = store.graphicEQ.gainsDb[slot]
        // Whole numbers read "+4"; fractional preset values keep a decimal
        // ("+2.5"), and zero (either sign) is a plain dimmed "0".
        let readout = gain == 0 ? "0"
            : String(format: gain == gain.rounded() ? "%+.0f" : "%+.1f", gain)
        return VStack(spacing: 3) {
            Text(readout)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(gain == 0 ? .secondary : .primary)
            Slider(
                value: Binding(
                    get: { store.graphicEQ.gainsDb[slot] },
                    set: { store.graphicEQ.gainsDb[slot] = $0; store.scheduleWrite() }
                ),
                in: -GraphicEQ.maxSliderDb...GraphicEQ.maxSliderDb,
                step: 1)
                .frame(width: sliderLength)
                .rotationEffect(.degrees(-90))
                .frame(width: columnWidth, height: sliderLength)
            Text(label(for: GraphicEQ.standardFrequencies[slot]))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(width: columnWidth)
    }

    private func groupLabel(_ name: String, columns: Int) -> some View {
        Text(name)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(
                width: CGFloat(columns) * columnWidth
                    + CGFloat(columns - 1) * columnSpacing)
            .overlay(alignment: .top) {
                Rectangle().fill(.secondary.opacity(0.35)).frame(height: 1)
                    .offset(y: -2)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Equalizer").font(.headline)
                Spacer()
                Menu(EQPreset.matching(store.graphicEQ.gainsDb)?.name ?? "Custom") {
                    ForEach(EQPreset.all) { preset in
                        Button(preset.name) {
                            store.graphicEQ.gainsDb = preset.gainsDb
                            store.scheduleWrite()
                        }
                    }
                }
                .controlSize(.small)
                .fixedSize()
            }

            HStack(alignment: .bottom, spacing: columnSpacing) {
                ForEach(GraphicEQ.standardFrequencies.indices, id: \.self) { slot in
                    bandColumn(slot)
                }
            }
            HStack(spacing: columnSpacing) {
                groupLabel("Bass", columns: 3)
                groupLabel("Midrange", columns: 4)
                groupLabel("Treble", columns: 3)
            }

            HStack(spacing: 8) {
                Text("Preamp")
                    .font(.caption)
                    .frame(width: 42, alignment: .trailing)
                Toggle("Auto", isOn: Binding(
                    get: { store.preampAuto },
                    set: { store.preampAuto = $0; store.scheduleWrite() }))
                    .toggleStyle(.checkbox)
                    .controlSize(.mini)
                Slider(
                    value: Binding(
                        get: { Double(store.preampDb) },
                        set: { store.preampDb = Float($0); store.scheduleWrite() }),
                    in: -24...0)
                    .disabled(store.preampAuto)
                Text(String(format: "%+.1f", store.effectivePreampDb))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 38, alignment: .trailing)
            }
            Text(store.preampAuto
                 ? "Auto guarantees no clipping; boosts lower everything else instead."
                 : "Manual preamp keeps loudness; extreme peaks hit the safety limiter.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if !store.graphicEQ.customBands.isEmpty {
                Text("+ \(store.graphicEQ.customBands.count) custom band(s) from the config file, preserved")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()
            Text("Surround").font(.headline)

            surroundSlider("Rear", value: floatBinding(\.rearGain), range: 0...1,
                           display: String(format: "%.2f", store.rearGain))
            surroundSlider("Delay", value: doubleBinding(\.rearDelayMs), range: 5...50,
                           display: String(format: "%.0f ms", store.rearDelayMs))
            surroundSlider("Center", value: floatBinding(\.centerGain), range: 0...0.5,
                           display: String(format: "%.2f", store.centerGain))
            surroundSlider("Sub", value: floatBinding(\.lfeGain), range: 0...0.45,
                           display: String(format: "%.2f", store.lfeGain))

            Divider()
            HStack {
                if let error = store.fileError ?? store.writeError {
                    Text(error).font(.caption2).foregroundStyle(.red)
                } else {
                    Text("Changes apply immediately")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Quit") {
                    store.flushPendingWrite()
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { store.reloadIfExternallyChanged() }
    }

    private func floatBinding(_ keyPath: ReferenceWritableKeyPath<SettingsStore, Float>) -> Binding<Double> {
        Binding(
            get: { Double(store[keyPath: keyPath]) },
            set: { store[keyPath: keyPath] = Float($0); store.scheduleWrite() })
    }

    private func doubleBinding(_ keyPath: ReferenceWritableKeyPath<SettingsStore, Double>) -> Binding<Double> {
        Binding(
            get: { store[keyPath: keyPath] },
            set: { store[keyPath: keyPath] = $0; store.scheduleWrite() })
    }

    private func surroundSlider(
        _ name: String, value: Binding<Double>, range: ClosedRange<Double>, display: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.caption)
                .frame(width: 42, alignment: .trailing)
            Slider(value: value, in: range)
            Text(display)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 44, alignment: .trailing)
        }
    }
}
