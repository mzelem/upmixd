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

    private func label(for freq: Double) -> String {
        freq >= 1000 ? "\(Int(freq / 1000))k" : "\(Int(freq))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Equalizer").font(.headline)
                Spacer()
                Button("Flat") { store.flatten() }
                    .controlSize(.small)
            }

            ForEach(GraphicEQ.standardFrequencies.indices, id: \.self) { slot in
                HStack(spacing: 8) {
                    Text(label(for: GraphicEQ.standardFrequencies[slot]))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 30, alignment: .trailing)
                    Slider(
                        value: Binding(
                            get: { store.graphicEQ.gainsDb[slot] },
                            set: { store.graphicEQ.gainsDb[slot] = $0; store.scheduleWrite() }
                        ),
                        in: -GraphicEQ.maxSliderDb...GraphicEQ.maxSliderDb,
                        step: 0.5)
                    Text(String(format: "%+.1f", store.graphicEQ.gainsDb[slot]))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 38, alignment: .trailing)
                }
            }

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
                    Text("Changes apply within ~2 s")
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
        .frame(width: 300)
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
