import AppIntents
import AppKit
import SwiftUI
import WidgetKit

// MARK: Per-widget configuration (right click on the widget → "Edit TrackPin")

enum ThemeChoice: String, AppEnum {
    case app, artwork, blur, system, graphite, plum, forest, ocean, sunset, paper

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Тема"
    static var caseDisplayRepresentations: [ThemeChoice: DisplayRepresentation] = [
        .app: "Как в приложении",
        .artwork: "По обложке",
        .blur: "Размытая обложка",
        .system: "Системная",
        .graphite: "Графит",
        .plum: "Слива",
        .forest: "Хвоя",
        .ocean: "Океан",
        .sunset: "Закат",
        .paper: "Бумага"
    ]
}

enum ControlsChoice: String, AppEnum {
    case app, tracks, seek, full

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Кнопки"
    static var caseDisplayRepresentations: [ControlsChoice: DisplayRepresentation] = [
        .app: "Как в приложении",
        .tracks: "Предыдущий, пауза, следующий",
        .seek: "Перемотка и пауза",
        .full: "Все кнопки"
    ]
}

struct TrackPinWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Виджет TrackPin"
    static var description = IntentDescription("Тема и кнопки этого виджета. Остальное настраивается в приложении TrackPin.")

    @Parameter(title: "Тема", default: .app)
    var theme: ThemeChoice

    @Parameter(title: "Кнопки", default: .app)
    var controls: ControlsChoice

    func apply(to style: WidgetStyle) -> WidgetStyle {
        var style = style
        if let chosen = WidgetTheme(rawValue: theme.rawValue) { style.theme = chosen }
        if let chosen = ControlSet(rawValue: controls.rawValue) { style.controls = chosen }
        return style
    }
}

// MARK: Timeline

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let style: WidgetStyle
}

/// The last snapshot received from the app, kept in the extension's own sandbox
/// container. It keeps the chosen theme while the app is not running.
enum SnapshotCache {
    private static var url: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("last-snapshot.json")
    }

    static func load() -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard let url, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// What to show when the app does not answer: its last style, but no track.
    static func offline() -> WidgetSnapshot {
        var snapshot = WidgetSnapshot.offline
        if let cached = load() {
            snapshot.style = cached.style
            snapshot.palette = cached.palette
        }
        return snapshot
    }
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: .preview, style: WidgetSnapshot.preview.style)
    }

    func snapshot(for configuration: TrackPinWidgetIntent, in context: Context) async -> Entry {
        if context.isPreview {
            // The widget gallery: show a playing track even if nothing plays right now.
            var preview = WidgetSnapshot.preview
            if let live = await WidgetTransport.send(.snapshot) {
                preview.style = live.style
                if live.playback.currentTrack != nil { preview = live }
            }
            return Entry(date: .now, snapshot: preview, style: configuration.apply(to: preview.style))
        }
        return await entry(for: configuration)
    }

    func timeline(for configuration: TrackPinWidgetIntent, in context: Context) async -> Timeline<Entry> {
        let entry = await entry(for: configuration)
        let now = Date()
        var next = now.addingTimeInterval(15 * 60)
        if !entry.snapshot.hostReachable {
            next = now.addingTimeInterval(5 * 60)
        } else if let track = entry.snapshot.playback.currentTrack, track.playing, track.duration > 0 {
            // Ask again right after the track ends, in case the app's reload request is throttled.
            let end = entry.snapshot.sampledAt.addingTimeInterval(track.duration - track.position + 1)
            next = min(next, max(end, now.addingTimeInterval(5)))
        }
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func entry(for configuration: TrackPinWidgetIntent) async -> Entry {
        let snapshot: WidgetSnapshot
        if let live = await WidgetTransport.send(.snapshot) {
            SnapshotCache.save(live)
            snapshot = live
        } else {
            snapshot = SnapshotCache.offline()
        }
        return Entry(date: .now, snapshot: snapshot, style: configuration.apply(to: snapshot.style))
    }
}

// MARK: Widgets

private struct PlayerEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        TrackPinCard(snapshot: entry.snapshot, style: entry.style, size: CardSize(family), date: entry.date)
    }
}

struct TrackPinWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetTransport.kind, intent: TrackPinWidgetIntent.self, provider: Provider()) { entry in
            PlayerEntryView(entry: entry)
        }
        .configurationDisplayName("Spotify")
        .description("Обложка, прогресс и кнопки управления треком.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

/// A second, minimal widget: the album cover edge to edge with a single play button.
private struct CoverEntryView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    let entry: Entry

    var body: some View {
        let colors = entry.style.theme.colors(palette: entry.snapshot.palette, scheme: scheme)
        let large = family != .systemSmall
        if let track = entry.snapshot.playback.currentTrack {
            VStack(alignment: .leading, spacing: 2) {
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.system(size: large ? 17 : 12, weight: .semibold)).lineLimit(large ? 2 : 1)
                        if entry.style.showArtist {
                            Text(track.artist).font(.system(size: large ? 13 : 10)).opacity(0.75).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Button(intent: PlayerControlIntent(action: .toggle)) {
                        Image(systemName: track.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: large ? 16 : 12, weight: .bold))
                            .frame(width: large ? 42 : 30, height: large ? 42 : 30)
                            .foregroundStyle(Color.black.opacity(0.85))
                            .background(Circle().fill(.white.opacity(0.92)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(track.playing ? "Пауза" : "Воспроизвести")
                }
            }
            .padding(large ? 16 : 12)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .widgetURL(URL(string: "needle-spotify://open"))
            .containerBackground(for: .widget) {
                ZStack {
                    colors.gradient
                    if let data = entry.snapshot.cover, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "music.note").font(.system(size: 44, weight: .semibold)).foregroundStyle(colors.accent)
                    }
                    LinearGradient(colors: [.clear, .clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                }
            }
        } else {
            // Without a track the cover widget looks like the regular one.
            TrackPinCard(snapshot: entry.snapshot, style: entry.style, size: CardSize(family), date: entry.date)
        }
    }
}

struct TrackPinCoverWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetTransport.coverKind, intent: TrackPinWidgetIntent.self, provider: Provider()) { entry in
            CoverEntryView(entry: entry)
        }
        .configurationDisplayName("Обложка")
        .description("Обложка текущего трека во весь виджет и кнопка паузы.")
        .supportedFamilies([.systemSmall, .systemLarge])
        .contentMarginsDisabled()
    }
}

@main
struct TrackPinWidgetBundle: WidgetBundle {
    var body: some Widget {
        TrackPinWidget()
        TrackPinCoverWidget()
    }
}
