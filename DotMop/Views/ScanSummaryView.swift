import SwiftUI

struct ScanSummaryView: View {
    let statistics: ScanStatistics
    let selection: FileTally

    var body: some View {
        HStack(spacing: 0) {
            tally(".DS_Store", value: statistics.dsStore)
            Divider()
            tally("AppleDouble", value: statistics.appleDouble)
            Divider()
            tally("选中清理", value: selection)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 7)
    }

    private func tally(_ title: LocalizedStringKey, value: FileTally) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value.count, format: .number)
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text(value.bytes, format: .byteCount(style: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }
}
