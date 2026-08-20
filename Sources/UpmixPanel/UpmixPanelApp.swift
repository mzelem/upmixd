import AppKit
import SwiftUI
import UpmixCore

@main
struct UpmixPanelApp: App {
    @StateObject private var store: SettingsStore

    init() {
        // Single instance: the login agent may already be running when the
        // user double-clicks the app — a second menu-bar icon writing the
        // same config is pure confusion.
        let mine = Bundle.main.bundleIdentifier
        if let mine,
           NSRunningApplication.runningApplications(withBundleIdentifier: mine)
               .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            exit(0)
        }
        // Honor the same --config flag as the daemon so a relocated settings
        // file keeps both processes on one source of truth.
        var path = SettingsStore.defaultConfigPath
        var args = ArraySlice(CommandLine.arguments.dropFirst())
        while let arg = args.popFirst() {
            if arg == "--config", let value = args.popFirst() {
                path = value
            }
        }
        _store = StateObject(wrappedValue: SettingsStore(configPath: path))
    }

    var body: some Scene {
        MenuBarExtra("Upmix", systemImage: "slider.vertical.3") {
            PanelView()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Faceplate-style grouping bracket: a horizontal line with end ticks rising
/// toward the sliders it spans, ⎣______⎦ opened upward.
struct GroupBracket: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 0.5, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + 0.5, y: rect.maxY - 0.5))
        path.addLine(to: CGPoint(x: rect.maxX - 0.5, y: rect.maxY - 0.5))
        path.addLine(to: CGPoint(x: rect.maxX - 0.5, y: rect.minY))
        return path
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
        let width = CGFloat(columns) * columnWidth + CGFloat(columns - 1) * columnSpacing
        return VStack(spacing: 2) {
            GroupBracket()
                .stroke(.secondary.opacity(0.55), lineWidth: 1)
                .frame(width: width - 4, height: 5)
            Text(name)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: width)
    }

    private func outputPicker(resolved: (candidate: OutputCandidate?, surround: Bool)) -> some View {
        let isAuto = store.outputName == nil && store.outputUid == nil
        let title = isAuto
            ? "Auto\(resolved.candidate.map { " (\($0.name))" } ?? "")"
            : (store.outputName ?? store.outputUid ?? "?")
        return HStack {
            Text("Output").font(.headline)
            Spacer()
            Menu(title) {
                Button("Automatic") { store.selectOutput(nil) }
                Divider()
                ForEach(store.outputCandidates, id: \.uid) { choice in
                    // Label with what the pipeline will actually DO there,
                    // not raw capability (an 8ch sink without our format
                    // runs stereo and must say so).
                    Button("\(choice.name) (\(choice.pipelineChannels == 6 ? "5.1" : "stereo"))") {
                        store.selectOutput(choice)
                    }
                }
            }
            .controlSize(.small)
            .fixedSize()
        }
    }

    var body: some View {
        let resolved = store.resolvedOutput // cached; refreshed on device changes
        return VStack(alignment: .leading, spacing: 10) {
            outputPicker(resolved: resolved)
            Divider()
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
                 ? "Auto guarantees no clipping; boosts lower everything else."
                 : "Manual preamp keeps loudness; extreme peaks hit the limiter.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !store.graphicEQ.customBands.isEmpty {
                Text("+ \(store.graphicEQ.customBands.count) custom band(s) from the config file, preserved")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if resolved.surround {
                Divider()
                Text("Surround").font(.headline)

                surroundSlider("Rear", value: floatBinding(\.rearGain), range: 0...1,
                               display: String(format: "%.2f", store.rearGain))
                surroundSlider("Delay", value: doubleBinding(\.rearDelayMs), range: 1...100,
                               display: String(format: "%.0f ms", store.rearDelayMs))
                surroundSlider("Center", value: floatBinding(\.centerGain), range: 0...0.5,
                               display: String(format: "%.2f", store.centerGain))
                surroundSlider("Sub", value: floatBinding(\.lfeGain), range: 0...0.45,
                               display: String(format: "%.2f", store.lfeGain))
            } else {
                Text("Stereo output — EQ only; surround controls apply when a 5.1-capable device is selected.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
        .onAppear {
            store.reloadIfExternallyChanged()
            store.refreshDevices() // catch changes the listeners missed while closed
        }
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
