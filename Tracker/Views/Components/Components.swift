import SwiftUI
import TrackerKit

/// A picker over preset values that still shows a custom value (e.g. one set by remote config or an import).
struct OptionPicker<Value: Hashable>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    init(_ title: LocalizedStringKey, selection: Binding<Value>, options: [Value], label: @escaping (Value) -> String) {
        self.title = title
        self._selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(allOptions, id: \.self) { value in
                Text(label(value)).tag(value)
            }
        }
    }

    private var allOptions: [Value] {
        options.contains(selection) ? options : options + [selection]
    }
}

/// A row label with the JSON key it controls, so technical users know exactly what's sent.
struct FieldLabel: View {
    let title: LocalizedStringKey
    let key: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(key)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

/// Monospaced, selectable text block for JSON and HTTP payloads.
struct CodeBlock: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal) {
            Text(text.isEmpty ? "(empty)" : text)
                .font(.footnote.monospaced())
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }
}

enum Format {
    static func distance(_ meters: Double) -> String {
        if meters <= 0 { return "Off" }
        if meters >= 1000 {
            let km = meters / 1000
            return km == km.rounded() ? "\(Int(km)) km" : String(format: "%.1f km", km)
        }
        return "\(Int(meters)) m"
    }

    static func optionalDistance(_ meters: Double?) -> String {
        meters.map(distance) ?? "Off"
    }

    static func duration(seconds: Double) -> String {
        if seconds <= 0 { return "Off" }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }

    static func sendInterval(_ seconds: Int?) -> String {
        guard let seconds else { return "Manual only" }
        return "Every \(duration(seconds: Double(seconds)))"
    }

    static func records(_ count: Int) -> String {
        count == 1 ? "1 record" : "\(count.formatted()) records"
    }

    static func bytes(_ count: Int) -> String {
        count.formatted(.byteCount(style: .file))
    }

    static func coordinate(_ sample: LocationSample) -> String {
        String(format: "%.5f, %.5f", sample.latitude, sample.longitude)
    }
}

/// Curated SF Symbols for profiles.
enum ProfileSymbols {
    static let all = [
        "location", "gauge.with.dots.needle.50percent", "scope", "leaf", "bolt", "figure.walk",
        "figure.run", "bicycle", "car", "tram", "airplane", "ferry", "house", "building.2",
        "briefcase", "moon", "mountain.2", "globe", "antenna.radiowaves.left.and.right", "flask",
    ]
}

extension Color {
    /// The app's accent color, from the asset catalog.
    static let brand = Color("AccentColor")
}
