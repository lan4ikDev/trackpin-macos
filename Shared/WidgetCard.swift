import AppIntents
import AppKit
import SwiftUI
import WidgetKit

enum CardSize: CaseIterable {
    case small, medium, large

    init(_ family: WidgetFamily) {
        switch family {
        case .systemSmall: self = .small
        case .systemLarge, .systemExtraLarge: self = .large
        default: self = .medium
        }
    }

    /// Approximate point size of the desktop widget, used by the preview in the settings window.
    var previewSize: CGSize {
        switch self {
        case .small: CGSize(width: 170, height: 170)
        case .medium: CGSize(width: 364, height: 170)
        case .large: CGSize(width: 364, height: 382)
        }
    }

    var title: String {
        switch self {
        case .small: "Маленький"
        case .medium: "Средний"
        case .large: "Большой"
        }
    }
}

/// The widget face. It is shared between the widget extension and the settings
/// window of the app, which shows it as a live preview.
struct TrackPinCard: View {
    let snapshot: WidgetSnapshot
    /// The effective style, after per-widget overrides were applied.
    let style: WidgetStyle
    let size: CardSize
    var date: Date = .now
    /// The widget extension draws its background through `containerBackground`.
    /// The preview in the app has no widget container and draws it itself.
    var inWidget = true

    @Environment(\.colorScheme) private var scheme

    private var colors: ThemeColors { style.theme.colors(palette: snapshot.palette, scheme: scheme) }
    private var coverImage: NSImage? { snapshot.cover.flatMap(NSImage.init(data:)) }

    var body: some View {
        let card = content
            .padding(size == .large ? 16 : 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(colors.primary)
            .widgetURL(URL(string: snapshot.playback == .denied ? "needle-spotify://settings" : "needle-spotify://open"))
        if inWidget {
            card.containerBackground(for: .widget) { background }
        } else {
            card
                .frame(width: size.previewSize.width, height: size.previewSize.height)
                .background { background }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    // MARK: Layout

    @ViewBuilder private var content: some View {
        if let track = snapshot.playback.currentTrack {
            switch size {
            case .small: small(track)
            case .medium: medium(track)
            case .large: large(track)
            }
        } else {
            placeholder
        }
    }

    private func small(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                cover(54)
                Spacer(minLength: 0)
                if style.showHeader { logo }
            }
            Spacer(minLength: 0)
            info(track, titleSize: 12, artistSize: 10)
            if style.showProgress { progress(track, showTime: false) }
            controls(track, scale: 0.9).frame(maxWidth: .infinity)
        }
    }

    private func medium(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if style.showHeader { header }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                cover(style.showHeader ? 60 : 72)
                info(track, titleSize: 14, artistSize: 11)
                Spacer(minLength: 2)
                controls(track, scale: 1)
            }
            Spacer(minLength: 0)
            if style.showProgress { progress(track, showTime: style.showTime) }
        }
    }

    private func large(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if style.showHeader { header }
            Spacer(minLength: 0)
            cover(style.showHeader ? 168 : 186).frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            info(track, titleSize: 17, artistSize: 13)
            if style.showProgress { progress(track, showTime: style.showTime) }
            controls(track, scale: 1.25).frame(maxWidth: .infinity)
        }
    }

    private var placeholder: some View {
        let message = self.message
        return VStack(alignment: .leading, spacing: 6) {
            if style.showHeader { header }
            Spacer(minLength: 0)
            Image(systemName: message.icon)
                .font(.system(size: size == .small ? 20 : 24, weight: .semibold))
                .foregroundStyle(colors.accent)
                .widgetAccentable()
            Text(message.title)
                .font(.system(size: size == .small ? 14 : 17, weight: .semibold))
                .lineLimit(2)
            Text(message.detail)
                .font(.system(size: size == .small ? 10 : 12))
                .foregroundStyle(colors.secondary)
                .lineLimit(size == .small ? 2 : 3)
            Spacer(minLength: 0)
        }
    }

    private var message: (icon: String, title: String, detail: String) {
        if !snapshot.hostReachable {
            return ("pin.fill", "Открой TrackPin", "Приложение передаёт виджету трек и выполняет команды")
        }
        switch snapshot.playback {
        case .closed: return ("music.note", "Плеер закрыт", "Нажми, чтобы открыть \(snapshot.sourceTitle)")
        case .idle: return ("music.note.list", "Ничего не играет", "Включи трек в плеере «\(snapshot.sourceTitle)»")
        case .denied: return ("lock.fill", "Нужен доступ", "Нажми и разреши TrackPin читать \(snapshot.sourceTitle)")
        case .unavailable: return ("exclamationmark.triangle.fill", "Плеер не ответил", "Попробуем ещё раз через пару секунд")
        case .track: return ("music.note", "", "")
        }
    }

    // MARK: Pieces

    private var logo: some View {
        Image(systemName: "waveform")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(colors.accent)
            .widgetAccentable()
    }

    private var header: some View {
        HStack(spacing: 6) {
            logo
            Text(snapshot.sourceTitle).font(.system(size: 11, weight: .semibold)).foregroundStyle(colors.accent)
                .widgetAccentable()
            Spacer(minLength: 0)
            if let track = snapshot.playback.currentTrack, track.playing {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(colors.secondary)
            }
        }
    }

    @ViewBuilder private var background: some View {
        if colors.artworkBackground, let image = coverImage {
            ZStack {
                colors.gradient
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 26)
                    .saturation(1.25)
                Color.black.opacity(0.34)
            }
        } else {
            colors.gradient
        }
    }

    private func artworkClip(_ side: CGFloat) -> AnyShape {
        switch style.artwork {
        case .rounded: AnyShape(RoundedRectangle(cornerRadius: side * 0.16, style: .continuous))
        case .square: AnyShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        case .circle: AnyShape(Circle())
        }
    }

    private func cover(_ side: CGFloat) -> some View {
        ZStack {
            colors.primary.opacity(0.10)
            if let image = coverImage {
                artwork(image)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.36, weight: .semibold))
                    .foregroundStyle(colors.accent)
            }
            if style.artwork == .circle {
                // The spindle hole of a record.
                Circle()
                    .fill(colors.background.last ?? .black)
                    .frame(width: side * 0.15, height: side * 0.15)
                    .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
            }
        }
        .frame(width: side, height: side)
        .clipShape(artworkClip(side))
        .shadow(color: .black.opacity(colors.dark ? 0.25 : 0.12), radius: side * 0.06, y: side * 0.02)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func artwork(_ image: NSImage) -> some View {
        if #available(macOS 15.0, *) {
            Image(nsImage: image).resizable().widgetAccentedRenderingMode(.fullColor).scaledToFill()
        } else {
            Image(nsImage: image).resizable().scaledToFill()
        }
    }

    private func info(_ track: Track, titleSize: CGFloat, artistSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.title).font(.system(size: titleSize, weight: .semibold)).lineLimit(1)
            if style.showArtist {
                Text(track.artist).font(.system(size: artistSize)).foregroundStyle(colors.secondary).lineLimit(1)
            }
        }
    }

    private func controls(_ track: Track, scale: CGFloat) -> some View {
        let set: ControlSet = size == .small && style.controls == .full ? .tracks : style.controls
        return HStack(spacing: 4 * scale) {
            switch set {
            case .tracks:
                button(.previous, track, scale)
                button(.toggle, track, scale)
                button(.next, track, scale)
            case .seek:
                button(.rewind, track, scale)
                button(.toggle, track, scale)
                button(.forward, track, scale)
            case .full:
                button(.previous, track, scale)
                button(.rewind, track, scale)
                button(.toggle, track, scale)
                button(.forward, track, scale)
                button(.next, track, scale)
            }
        }
    }

    private func button(_ action: PlayerAction, _ track: Track, _ scale: CGFloat) -> some View {
        let primary = action == .toggle
        let side = (primary ? 32 : 26) * scale
        return Button(intent: PlayerControlIntent(action: action, step: style.seekStep)) {
            Image(systemName: symbol(action, playing: track.playing))
                .font(.system(size: (primary ? 13 : 12) * scale, weight: .bold))
                .frame(width: side, height: side)
                .foregroundStyle(primary ? colors.onAccent : colors.primary.opacity(0.9))
                .background {
                    if primary { Circle().fill(colors.accent).widgetAccentable() }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label(action, playing: track.playing))
    }

    private func symbol(_ action: PlayerAction, playing: Bool) -> String {
        switch action {
        case .toggle: playing ? "pause.fill" : "play.fill"
        case .previous: "backward.end.fill"
        case .next: "forward.end.fill"
        case .rewind: "gobackward.\(style.seekStep)"
        case .forward: "goforward.\(style.seekStep)"
        }
    }

    private func label(_ action: PlayerAction, playing: Bool) -> String {
        switch action {
        case .toggle: playing ? "Пауза" : "Воспроизвести"
        case .previous: "Предыдущий трек"
        case .next: "Следующий трек"
        case .rewind: "Назад на \(style.seekStep) секунд"
        case .forward: "Вперёд на \(style.seekStep) секунд"
        }
    }

    private func progress(_ track: Track, showTime: Bool) -> some View {
        let start = snapshot.sampledAt.addingTimeInterval(-track.position)
        let end = start.addingTimeInterval(track.duration)
        let live = track.playing && track.duration > 0 && end > date
        let frozen = track.playing && end <= date ? track.duration : track.position
        return VStack(spacing: 3) {
            Group {
                if live {
                    ProgressView(timerInterval: start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                } else {
                    ProgressView(value: frozen, total: max(1, track.duration))
                }
            }
            .progressViewStyle(.linear)
            .tint(colors.accent)
            if showTime {
                HStack {
                    Group {
                        if live { Text(timerInterval: start...end, countsDown: false, showsHours: false) }
                        else { Text(Self.time(frozen)) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Self.time(track.duration))
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(colors.secondary)
            }
        }
    }

    static func time(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.rounded(.down)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
