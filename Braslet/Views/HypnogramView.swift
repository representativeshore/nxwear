import SwiftUI

/// Гипнограмма: как стадии сменяли друг друга за ночь.
/// Бодрствование сверху, глубокий сон снизу.
struct HypnogramView: View {
    let night: SleepNight

    private let rows: [SleepStage] = [.awake, .rem, .core, .deep]
    private let rowHeight: CGFloat = 26
    private let rowGap: CGFloat = 6

    private var span: TimeInterval {
        max(1, night.end.timeIntervalSince(night.start))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(Array(rows.enumerated()), id: \.element) { index, stage in
                        laneBackground(index: index, width: geo.size.width)
                        ForEach(night.segments.filter { $0.stage == stage }) { segment in
                            bar(for: segment, rowIndex: index, width: geo.size.width)
                        }
                    }
                }
            }
            .frame(height: CGFloat(rows.count) * rowHeight
                       + CGFloat(rows.count - 1) * rowGap)

            HStack {
                Text(Fmt.time(night.start))
                Spacer()
                Text(Fmt.time(night.end))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func yOffset(_ index: Int) -> CGFloat {
        CGFloat(index) * (rowHeight + rowGap)
    }

    private func laneBackground(index: Int, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(.tertiarySystemFill).opacity(0.5))
            .frame(width: width, height: rowHeight)
            .offset(y: yOffset(index))
    }

    private func bar(for segment: SleepSegment, rowIndex: Int, width: CGFloat) -> some View {
        let from = segment.start.timeIntervalSince(night.start) / span
        let length = segment.duration / span
        // Совсем короткие отрезки всё равно должны быть заметны.
        let barWidth = max(3, width * length)

        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(segment.stage.color)
            .frame(width: barWidth, height: rowHeight)
            .offset(x: width * from, y: yOffset(rowIndex))
    }
}

/// Подписи к цветам под гипнограммой.
struct StageLegend: View {
    let night: SleepNight
    private let shown: [SleepStage] = [.deep, .core, .rem, .awake]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(shown, id: \.self) { stage in
                let seconds = night.duration(of: stage)
                if seconds > 0 {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(stage.color)
                            .frame(width: 10, height: 10)
                        Text(stage.title)
                            .font(.subheadline)
                        Spacer()
                        Text(Fmt.duration(seconds))
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                        Text(Fmt.percent(night.share(of: stage)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
    }
}
