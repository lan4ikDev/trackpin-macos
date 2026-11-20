import Charts
import SwiftUI

/// Settings → Statistics: listening time this week, by day, top artists and tracks.
struct StatsView: View {
    @ObservedObject var stats: ListeningStats
    let enabled: Bool

    var body: some View {
        let week = stats.week()
        let total = week.reduce(0) { $0 + $1.day.total }
        Form {
            Section {
                LabeledContent("За 7 дней") {
                    Text(Self.duration(total)).font(.title2.weight(.semibold)).monospacedDigit()
                }
                Chart(week, id: \.date) { entry in
                    BarMark(x: .value("День", entry.date, unit: .day),
                            y: .value("Минуты", entry.day.total / 60))
                        .foregroundStyle(Color.accentColor.gradient)
                        .cornerRadius(4)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                    }
                }
                .chartYAxisLabel("мин")
                .frame(height: 160)
                .padding(.vertical, 4)
            } header: {
                Text("Время прослушивания")
            } footer: {
                Text(enabled
                     ? "TrackPin считает сам, пока он запущен, и хранит статистику только на этом Mac, 60 дней."
                     : "Статистика выключена вместе с историей: включи «Запоминать прослушанные треки» на вкладке «Мини-плеер».")
            }
            Section("Топ исполнителей") {
                let artists = stats.topArtists(in: week)
                if artists.isEmpty { Text("Пока пусто").foregroundStyle(.secondary) }
                ForEach(Array(artists.enumerated()), id: \.offset) { index, artist in
                    LabeledContent {
                        Text(Self.duration(artist.seconds)).monospacedDigit()
                    } label: {
                        Text("\(index + 1). \(artist.name)").lineLimit(1)
                    }
                }
            }
            Section("Чаще всего играли") {
                let tracks = stats.topTracks(in: week)
                if tracks.isEmpty { Text("Пока пусто").foregroundStyle(.secondary) }
                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                    LabeledContent {
                        Text("\(track.plays)×").monospacedDigit()
                    } label: {
                        Text("\(index + 1). \(track.name)").lineLimit(1)
                    }
                }
            }
            Section {
                Button("Очистить статистику", role: .destructive) { stats.clear() }
            }
        }
        .formStyle(.grouped)
    }

    /// "1 ч 25 мин", "12 мин", "0 мин".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 60 {
            return String(localized: "\(minutes / 60) ч \(minutes % 60) мин")
        }
        return String(localized: "\(minutes) мин")
    }
}
