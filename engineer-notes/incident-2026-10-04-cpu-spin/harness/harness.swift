import SwiftUI
import Combine

// Minimal reproduction harness for the Muesli start-screen CPU spin.
// HARNESS_STYLE = segmented | menu | radio | custom  (default segmented)
// A 15 Hz published value stands in for the gated level meter.

final class Ticker: ObservableObject {
    @Published var level: Float = 0
    private var timer: Timer?
    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            self?.level = Float.random(in: 0...1)
        }
    }
}

enum Mode: String, CaseIterable, Identifiable { case video, audio; var id: String { rawValue } }
enum AEC: String, CaseIterable, Identifiable { case auto, on, off; var id: String { rawValue } }

struct CustomSegmented<T: Hashable & Identifiable & RawRepresentable>: View where T.RawValue == String {
    let options: [T]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                Button(option.rawValue.capitalized) { selection = option }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(selection == option ? Color.accentColor.opacity(0.25) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct Root: View {
    @StateObject private var ticker = Ticker()
    @State private var mode: Mode = .video
    @State private var aec: AEC = .auto
    let style = ProcessInfo.processInfo.environment["HARNESS_STYLE"] ?? "segmented"

    @ViewBuilder
    func modePicker() -> some View {
        switch style {
        case "menu":
            Picker("Mode", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu)
        case "radio":
            Picker("Mode", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.radioGroup).horizontalRadioGroupLayout()
        case "custom":
            CustomSegmented(options: Mode.allCases, selection: $mode)
        default:
            Picker("Mode", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
        }
    }
    @ViewBuilder
    func aecPicker() -> some View {
        switch style {
        case "menu":
            Picker("Echo cancellation", selection: $aec) { ForEach(AEC.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu)
        case "radio":
            Picker("Echo cancellation", selection: $aec) { ForEach(AEC.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.radioGroup).horizontalRadioGroupLayout()
        case "custom":
            CustomSegmented(options: AEC.allCases, selection: $aec)
        default:
            Picker("Echo cancellation", selection: $aec) { ForEach(AEC.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Harness: \(style)").font(.largeTitle).bold()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 16) {
                        modePicker().frame(maxWidth: 420)
                        Spacer()
                        Button("Refresh capture sources") {}
                    }
                    GroupBox("Microphone") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Input", selection: .constant(0)) { Text("System default").tag(0) }
                            aecPicker()
                            Text("Auto turns echo cancellation on only with the built-in speakers.").font(.footnote).foregroundStyle(.secondary)
                        }.padding(8)
                    }
                    GroupBox("Live input check") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text("Microphone").frame(width: 90, alignment: .leading); Text(String(format: "%.2f", ticker.level)).font(.caption); Spacer() }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                                    RoundedRectangle(cornerRadius: 6).fill(.green).frame(width: CGFloat(ticker.level) * geo.size.width)
                                }
                            }.frame(height: 12)
                        }.padding(8)
                    }
                    GroupBox("Transcription sources") {
                        VStack(alignment: .leading) { Toggle("System audio", isOn: .constant(true)); Toggle("Microphone", isOn: .constant(true)) }.padding(8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(24)
    }
}

@main
struct HarnessApp: App {
    var body: some Scene { WindowGroup { Root().frame(minWidth: 900, minHeight: 700) } }
}
