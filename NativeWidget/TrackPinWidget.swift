import AppKit
import SwiftUI
import WidgetKit

private struct Entry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

private struct Provider: TimelineProvider {
    private let example = WidgetSnapshot(
        playback: .track(Track(id: "preview", title: "After Hours", artist: "Spotify",
                               artwork: nil, duration: 228, position: 74, playing: false)),
        sampledAt: .now, cover: nil, theme: .graphite, showTime: true
    )

    func placeholder(in context: Context) -> Entry { Entry(date: .now, snapshot: example) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        WidgetTransport.requestSnapshot { snapshot in
            completion(Entry(date: .now, snapshot: snapshot ?? .offline))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        WidgetTransport.requestSnapshot { snapshot in
            let now = Date()
            let entry = Entry(date: now, snapshot: snapshot ?? .offline)
            completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(900))))
        }
    }
}

private struct Card: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    private var compact: Bool { family == .systemSmall }
    private var theme: WidgetTheme { entry.snapshot.theme }

    var body: some View {
        Group {
            if case let .track(track) = entry.snapshot.playback {
                if compact { small(track) } else { medium(track) }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    Spacer(minLength: 0)
                    Text(message).font(.system(size: compact ? 14 : 17, weight: .semibold))
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(compact ? 13 : 15)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
        .containerBackground(for: .widget) {
            LinearGradient(colors: theme.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var message: String {
        switch entry.snapshot.playback {
        case .closed: entry.snapshot.sampledAt == .distantPast ? "Открой TrackPin" : "Открой Spotify"
        case .idle: "Включи трек в Spotify"
        case .denied: "Разреши доступ к Spotify"
        case .unavailable: "Spotify не ответил"
        case .track: ""
        }
    }

    private var header: some View {
        HStack {
            Label("Spotify", systemImage: "waveform")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.accent)
            Spacer()
        }
    }

    private func medium(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            Spacer(minLength: 0)
            HStack(spacing: 11) {
                cover(size: 49)
                info(track)
                Spacer(minLength: 2)
                controls(track)
            }
            Spacer(minLength: 0)
            progress(track)
        }
    }

    private func small(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            HStack(spacing: 7) {
                cover(size: 41)
                info(track)
            }
            Spacer(minLength: 0)
            progress(track)
            controls(track).frame(maxWidth: .infinity)
        }
    }

    private func cover(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.10))
            if let data = entry.snapshot.cover, let art = NSImage(data: data) {
                Image(nsImage: art).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note").foregroundStyle(theme.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 9))
        .accessibilityHidden(true)
    }

    private func info(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(track.title).font(.system(size: compact ? 11 : 14, weight: .semibold)).lineLimit(1)
            Text(track.artist).font(.system(size: compact ? 9 : 11)).foregroundStyle(.white.opacity(0.68)).lineLimit(1)
        }
    }

    private func controls(_ track: Track) -> some View {
        HStack(spacing: compact ? 4 : 6) {
            control("gobackward.15", label: "Назад на 15 секунд", action: "rewind")
            control(track.playing ? "pause.fill" : "play.fill",
                    label: track.playing ? "Пауза" : "Воспроизвести", action: "toggle", primary: true)
            control("goforward.15", label: "Вперёд на 15 секунд", action: "forward")
            if !compact { control("forward.end.fill", label: "Следующий трек", action: "next") }
        }
    }

    private func control(_ icon: String, label: String, action: String, primary: Bool = false) -> some View {
        Link(destination: url(action)) {
            Image(systemName: icon)
                .font(.system(size: primary ? 12 : 13, weight: .semibold))
                .frame(width: primary ? 30 : 23, height: primary ? 30 : 24)
                .background(primary ? theme.accent : .clear, in: Circle())
                .foregroundStyle(primary ? Color.black.opacity(0.86) : Color.white)
        }
        .accessibilityLabel(label)
    }

    private func progress(_ track: Track) -> some View {
        let start = entry.snapshot.sampledAt.addingTimeInterval(-track.position)
        let end = start.addingTimeInterval(track.duration)
        return VStack(spacing: 3) {
            Group {
                if track.playing && track.duration > 0 && end > entry.date {
                    ProgressView(timerInterval: start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                } else {
                    let value = track.playing && end <= entry.date ? track.duration : track.position
                    ProgressView(value: value, total: max(1, track.duration))
                }
            }
            .progressViewStyle(.linear)
            .tint(theme.accent)
            if entry.snapshot.showTime {
                HStack {
                    if track.playing && track.duration > 0 && end > entry.date {
                        Text(timerInterval: start...end, countsDown: false, showsHours: false)
                    } else {
                        Text(time(track.playing && end <= entry.date ? track.duration : track.position))
                    }
                    Spacer()
                    Text(time(track.duration))
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    private func time(_ seconds: Double) -> String {
        let value = Int(seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    private func url(_ action: String) -> URL { URL(string: "needle-spotify://\(action)")! }
}

@main
struct TrackPinWidgetBundle: WidgetBundle {
    var body: some Widget { TrackPinWidget() }
}

private struct TrackPinWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetTransport.kind, provider: Provider()) { entry in
            Card(entry: entry)
        }
        .configurationDisplayName("Spotify")
        .description("Обложка, время трека и управление Spotify.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}
