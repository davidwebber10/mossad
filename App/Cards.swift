import SwiftUI

/// A content card: a short title in sentence case, an optional control on the right, and the content. A hairline
/// border instead of a shadow, which reads in both light and dark mode.
struct Card<Accessory: View, Content: View>: View {
    let title: String
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ title: String, @ViewBuilder accessory: @escaping () -> Accessory, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                accessory()
            }
            content().font(.system(size: 13)).lineSpacing(3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Theme.separator.opacity(contrast == .increased ? 1 : 0.6), lineWidth: contrast == .increased ? 1 : 0.5))
    }
}

/// VoiceOver's audio graph and data table for a chart of values over dates.
struct DateSeriesDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let unit: String
    let points: [(Date, Double)]

    func makeChartDescriptor() -> AXChartDescriptor {
        let dates = points.map(\.0)
        let x = AXCategoricalDataAxisDescriptor(title: "Date", categoryOrder: dates.map { $0.formatted(date: .abbreviated, time: .omitted) })
        let values = points.map(\.1)
        let y = AXNumericDataAxisDescriptor(title: unit, range: 0...max(values.max() ?? 1, 1), gridlinePositions: []) { "\(Int($0)) \(unit)" }
        let series = AXDataSeriesDescriptor(name: title, isContinuous: false, dataPoints: points.map {
            AXDataPoint(x: $0.0.formatted(date: .abbreviated, time: .omitted), y: $0.1)
        })
        return AXChartDescriptor(title: title, summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}

extension Card where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

/// A heading over a group of cards.
struct SectionHeading: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(.top, 8)
        .id(title)
        .accessibilityAddTraits(.isHeader)
    }
}
