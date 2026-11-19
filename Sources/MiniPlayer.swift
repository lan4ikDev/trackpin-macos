import AppKit
import Combine
import SwiftUI

/// The vertical mini player that opens when the widget (or the menu bar icon) is clicked.
///
/// The panel is placed at its final frame right away with a transparent background. The
/// SwiftUI content then grows out of the click point with a spring, which is smoother than
/// animating the window frame and re-laying out the content on every step.
@MainActor
final class MiniPlayerController: NSObject, NSWindowDelegate {
    private let player: Player
    private let preferences: Preferences
    private let publisher: WidgetPublisher
    private let model = MiniPlayerModel()
    private var panel: MiniPanel?
    private var closing: DispatchWorkItem?
    private var observations: Set<AnyCancellable> = []
    var showSettings: () -> Void = {}
    var onVisibilityChange: (Bool) -> Void = { _ in }

    /// Room around the card for its shadow.
    static let margin: CGFloat = 28

    private let sleepTimer: SleepTimer

    init(player: Player, preferences: Preferences, publisher: WidgetPublisher, sleepTimer: SleepTimer) {
        self.sleepTimer = sleepTimer
        self.player = player
        self.preferences = preferences
        self.publisher = publisher
        super.init()
        // The card's height depends on these settings: resize an open panel when they change.
        preferences.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.fitPanel() }
            .store(in: &observations)
    }

    var isVisible: Bool { panel?.isVisible == true && model.presented }

    func toggle(from point: NSPoint? = nil) {
        isVisible ? close() : show(from: point)
    }

    func show(from point: NSPoint? = nil) {
        closing?.cancel()
        closing = nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let origin = point ?? NSEvent.mouseLocation
        let size = panel.contentView?.fittingSize ?? NSSize(width: 360, height: 560)
        let frame = place(size: size, near: origin)
        panel.setFrame(frame, display: false)
        // Grow out of the click point, expressed in SwiftUI's top-left based unit space.
        model.anchor = UnitPoint(x: min(max((origin.x - frame.minX) / frame.width, 0), 1),
                                 y: min(max(1 - (origin.y - frame.minY) / frame.height, 0), 1))
        if !panel.isVisible { model.presented = false }
        panel.orderFrontRegardless()
        panel.makeKey()
        onVisibilityChange(true)
        let animation: Animation? = preferences.popupAnimated ? .spring(response: 0.42, dampingFraction: 0.78) : nil
        DispatchQueue.main.async { withAnimation(animation) { self.model.presented = true } }
    }

    func close() {
        guard let panel, panel.isVisible, closing == nil else { return }
        let animated = preferences.popupAnimated
        withAnimation(animated ? .easeIn(duration: 0.16) : nil) { model.presented = false }
        let work = DispatchWorkItem { [weak self] in
            panel.orderOut(nil)
            self?.closing = nil
            self?.onVisibilityChange(false)
        }
        closing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 0.17 : 0), execute: work)
    }

    private func makePanel() -> MiniPanel {
        let panel = MiniPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 560),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .none
        panel.delegate = self
        let view = MiniPlayerView(player: player, preferences: preferences, publisher: publisher, model: model,
                                  sleepTimer: sleepTimer,
                                  close: { [weak self] in self?.close() },
                                  showSettings: { [weak self] in self?.close(); self?.showSettings() })
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        panel.onKey = { [weak self] event in self?.handle(event) ?? false }
        return panel
    }

    private func fitPanel() {
        // objectWillChange fires before the new value is stored, so measure on the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible, let size = panel.contentView?.fittingSize else { return }
            var frame = panel.frame
            frame.origin.y += frame.height - size.height
            frame.size = size
            panel.setFrame(frame, display: true)
        }
    }

    private func place(size: NSSize, near point: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var frame = NSRect(origin: .zero, size: size)
        switch preferences.popupPlacement {
        case .cursor:
            frame.origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        case .center:
            frame.origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        // The shadow margin may hang off the screen edge; the card itself may not.
        let slack = Self.margin - 6
        frame.origin.x = min(max(frame.minX, visible.minX - slack), visible.maxX - size.width + slack)
        frame.origin.y = min(max(frame.minY, visible.minY - slack), visible.maxY - size.height + slack)
        return frame
    }

    /// Keyboard: space plays or pauses, ←/→ seek, ↑/↓ change the volume, Esc closes.
    private func handle(_ event: NSEvent) -> Bool {
        let step = preferences.style.seekStep
        switch Int(event.keyCode) {
        case 49: player.send(.toggle)
        case 123: player.send(PlayerCommand(.rewind, step: step))
        case 124: player.send(PlayerCommand(.forward, step: step))
        case 126, 125:
            guard let volume = player.playback.currentTrack?.volume else { return false }
            player.send(.volume(volume + (event.keyCode == 126 ? 10 : -10)))
        case 53: close()
        default:
            if event.charactersIgnoringModifiers == "," && event.modifierFlags.contains(.command) {
                close()
                showSettings()
            } else if event.charactersIgnoringModifiers == "w" && event.modifierFlags.contains(.command) {
                close()
            } else {
                return false
            }
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        if preferences.popupClosesOnClickOutside { close() }
    }
}

final class MiniPlayerModel: ObservableObject {
    @Published var presented = false
    @Published var anchor: UnitPoint = .center
}

final class MiniPanel: NSPanel {
    var onKey: (NSEvent) -> Bool = { _ in false }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if !onKey(event) { super.keyDown(with: event) }
    }
}

// MARK: View

struct MiniPlayerView: View {
    @ObservedObject var player: Player
    @ObservedObject var preferences: Preferences
    @ObservedObject var publisher: WidgetPublisher
    @ObservedObject var model: MiniPlayerModel
    @ObservedObject var sleepTimer: SleepTimer
    let close: () -> Void
    let showSettings: () -> Void

    @State private var hovering = false

    private var width: CGFloat { preferences.popupSize.width }
    private var padding: CGFloat { preferences.popupSize == .compact ? 12 : 14 }
    private var corner: CGFloat { preferences.popupSize == .large ? 30 : 26 }

    private var colors: ThemeColors {
        let themed = preferences.style.theme.colors(palette: publisher.snapshot.palette, scheme: .dark)
        return themed.dark ? themed : WidgetTheme.graphite.colors(palette: publisher.snapshot.palette, scheme: .dark)
    }

    var body: some View {
        card
            .frame(width: width)
            .background { background }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            .scaleEffect(model.presented ? 1 : 0.18, anchor: model.anchor)
            .opacity(model.presented ? 1 : 0)
            .blur(radius: model.presented ? 0 : 8)
            .padding(MiniPlayerController.margin)
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .buttonStyle(.plain)
            .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
    }

    @ViewBuilder private var card: some View {
        switch player.playback {
        case let .track(track):
            TrackCard(player: player, preferences: preferences, publisher: publisher, sleepTimer: sleepTimer, track: track,
                      accent: colors.accent, width: width, padding: padding, corner: corner,
                      hovering: hovering, close: close, showSettings: showSettings)
        case .closed:
            message("music.note", "Spotify закрыт", "Запусти Spotify, и здесь появится трек.", "Открыть Spotify", player.openSpotify)
        case .idle:
            message("music.note.list", "Ничего не играет", "Включи трек в Spotify.", "Открыть Spotify", player.openSpotify)
        case .denied:
            message("lock.fill", "Нужен доступ", "Разреши TrackPin управлять Spotify в разделе «Автоматизация».", "Открыть настройки") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .unavailable:
            message("exclamationmark.triangle.fill", "Spotify не ответил", "Проверь, что плеер запущен.", "Повторить", player.retry)
        }
    }

    private func message(_ icon: String, _ title: String, _ detail: String, _ action: String,
                         _ perform: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                CircleButton(icon: "xmark", label: "Закрыть", action: close)
            }
            Image(systemName: icon)
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(colors.accent)
                .frame(height: width * 0.42)
            Text(title).font(.system(size: 18, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button(action: perform) {
                Text(action).font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Capsule().fill(colors.accent))
                    .foregroundStyle(colors.onAccent)
            }
            .padding(.top, 4)
        }
        .padding(padding)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var background: some View {
        switch preferences.popupBackground {
        case .artwork:
            ZStack {
                colors.gradient
                if let blurred = publisher.blurredCover {
                    Image(nsImage: blurred).resizable().scaledToFill()
                        .transition(.opacity)
                }
                LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            }
            .animation(.easeInOut(duration: 0.4), value: publisher.blurredCover)
        case .theme:
            colors.gradient
        case .glass:
            ZStack {
                VisualEffect(material: .hudWindow)
                colors.gradient.opacity(0.25)
            }
        }
    }
}

private struct TrackCard: View {
    @ObservedObject var player: Player
    @ObservedObject var preferences: Preferences
    @ObservedObject var publisher: WidgetPublisher
    @ObservedObject var sleepTimer: SleepTimer
    let track: Track
    let accent: Color
    let width: CGFloat
    let padding: CGFloat
    let corner: CGFloat
    let hovering: Bool
    let close: () -> Void
    let showSettings: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            cover
            info
            if sleepTimer.isActive { sleepStatus }
            ScrubBar(player: player, track: track, accent: accent, showTime: preferences.style.showTime)
            controls
            if preferences.popupShowsVolume, let volume = track.volume {
                VolumeBar(player: player, volume: volume, accent: accent)
            }
        }
        .padding(padding)
        .padding(.bottom, 4)
    }

    private var coverSide: CGFloat { width - padding * 2 }

    private var coverShape: AnyShape {
        switch preferences.popupCoverShape {
        case .rounded: AnyShape(RoundedRectangle(cornerRadius: corner - padding + 2, style: .continuous))
        case .square: AnyShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        case .circle: AnyShape(Circle())
        }
    }

    private var cover: some View {
        ZStack {
            Color.white.opacity(0.08)
            if let image = publisher.coverImage {
                Image(nsImage: image).resizable().scaledToFill()
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .id(track.artwork)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: coverSide * 0.28, weight: .semibold))
                    .foregroundStyle(accent)
            }
            if preferences.popupCoverShape == .circle {
                Circle().fill(.black.opacity(0.85)).frame(width: coverSide * 0.12)
                    .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
            }
        }
        .frame(width: coverSide, height: coverSide)
        .clipShape(coverShape)
        .scaleEffect(track.playing || preferences.popupCoverShape == .circle ? 1 : 0.92)
        .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: track.playing)
        .animation(.easeInOut(duration: 0.35), value: publisher.coverImage)
        .overlay(alignment: .top) {
            HStack(spacing: 6) {
                CircleButton(icon: "gearshape.fill", label: "Настройки", action: showSettings)
                sleepMenu
                Spacer()
                CircleButton(icon: "arrow.up.forward.app.fill", label: "Открыть в Spotify", action: player.openSpotify)
                CircleButton(icon: "xmark", label: "Закрыть", action: close)
            }
            .padding(8)
            .opacity(hovering || sleepTimer.isActive ? 1 : 0)
        }
        .accessibilityHidden(true)
    }

    private var sleepMenu: some View {
        Menu {
            ForEach(SleepTimer.presets, id: \.self) { minutes in
                Button("\(minutes) минут") { sleepTimer.start(.minutes(minutes)) }
            }
            Button("В конце трека") { sleepTimer.start(.endOfTrack) }
            if sleepTimer.isActive {
                Divider()
                Button("Выключить таймер") { sleepTimer.cancel() }
            }
        } label: {
            Image(systemName: sleepTimer.isActive ? "moon.zzz.fill" : "moon.fill")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(sleepTimer.isActive ? accent.opacity(0.9) : .black.opacity(0.45)))
                .foregroundStyle(sleepTimer.isActive ? Color.black.opacity(0.85) : .white.opacity(0.9))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Таймер сна")
        .accessibilityLabel("Таймер сна")
    }

    private var sleepStatus: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                Image(systemName: "moon.zzz.fill")
                if let deadline = sleepTimer.deadline {
                    Text("Пауза через \(TrackPinCard.time(max(0, deadline.timeIntervalSince(context.date))))")
                } else {
                    Text("Пауза в конце трека")
                }
                Spacer(minLength: 0)
                Button("Отменить") { withAnimation { sleepTimer.cancel() } }
                    .foregroundStyle(accent)
            }
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(.white.opacity(0.1)))
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var info: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: width > 300 ? 18 : 16, weight: .bold))
                    .lineLimit(1)
                    .help(track.title)
                if preferences.style.showArtist {
                    Text(track.artist)
                        .font(.system(size: width > 300 ? 14 : 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .help(track.artist)
                }
            }
            .id(track.id)
            .transition(.opacity)
            Spacer(minLength: 0)
            if let link = track.webLink {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation { copied = false } }
                } label: {
                    Image(systemName: copied ? "checkmark" : "link")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(copied ? accent : .white.opacity(0.75))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .help("Скопировать ссылку на трек")
                .accessibilityLabel("Скопировать ссылку на трек")
            }
        }
        .animation(.easeInOut(duration: 0.25), value: track.id)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            if preferences.popupShowsModes {
                mode("shuffle", active: track.shuffling == true, label: "Перемешать") {
                    player.send(.shuffle(!(track.shuffling ?? false)))
                }
                Spacer(minLength: 0)
            }
            control("backward.end.fill", label: "Предыдущий трек") { player.send(.previous) }
            Spacer(minLength: 0)
            Button { player.send(.toggle) } label: {
                Image(systemName: track.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(accent))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel(track.playing ? "Пауза" : "Воспроизвести")
            Spacer(minLength: 0)
            control("forward.end.fill", label: "Следующий трек") { player.send(.next) }
            if preferences.popupShowsModes {
                Spacer(minLength: 0)
                mode("repeat", active: track.repeating == true, label: "Повтор") {
                    player.send(.repeating(!(track.repeating ?? false)))
                }
            }
        }
        .padding(.horizontal, preferences.popupShowsModes ? 2 : 24)
    }

    private func control(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
        .help(label)
    }

    private func mode(_ icon: String, active: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(active ? accent : .white.opacity(0.55))
                .frame(width: 32, height: 32)
                .overlay(alignment: .bottom) {
                    if active { Circle().fill(accent).frame(width: 4, height: 4).offset(y: 2) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
        .help(label)
    }
}

/// The seek bar. The position of a playing track is extrapolated from the last read, so the
/// bar moves smoothly while Spotify is only asked once a second (or less).
private struct ScrubBar: View {
    @ObservedObject var player: Player
    let track: Track
    let accent: Color
    let showTime: Bool

    @State private var dragging: Double?
    @State private var target: Double?
    @State private var targetSetAt = Date.distantPast
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: track.playing && dragging == nil ? 0.5 : 3600)) { context in
            let position = displayed(at: context.date)
            VStack(spacing: 5) {
                GeometryReader { geometry in
                    let fraction = track.duration > 0 ? min(max(position / track.duration, 0), 1) : 0
                    let thick: CGFloat = hovering || dragging != nil ? 7 : 4
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.22))
                        Capsule().fill(accent).frame(width: max(thick, geometry.size.width * fraction))
                    }
                    .frame(height: thick)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragging = seconds(at: value.location.x, width: geometry.size.width)
                        }
                        .onEnded { value in
                            seek(seconds(at: value.location.x, width: geometry.size.width))
                            dragging = nil
                        })
                }
                .frame(height: 14)
                .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
                if showTime {
                    HStack {
                        Text(TrackPinCard.time(position))
                        Spacer()
                        Text("−" + TrackPinCard.time(max(0, track.duration - position)))
                    }
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Позиция в треке")
        .accessibilityValue(TrackPinCard.time(displayed(at: .now)))
        .accessibilityAdjustableAction { direction in
            let now = displayed(at: .now)
            seek(direction == .increment ? min(track.duration, now + 5) : max(0, now - 5))
        }
        .onChange(of: track.id) { _, _ in target = nil }
    }

    private func displayed(at date: Date) -> Double {
        if let dragging { return dragging }
        let elapsed = track.playing ? date.timeIntervalSince(player.sampledAt) : 0
        // Until Spotify reports the new position, keep showing where the user seeked to.
        if let target, date.timeIntervalSince(targetSetAt) < 3 {
            let landed = abs(track.position - target) < 2 && player.sampledAt > targetSetAt
            if !landed { return min(track.duration, target + (track.playing ? date.timeIntervalSince(targetSetAt) : 0)) }
        }
        return min(track.duration, track.position + max(0, elapsed))
    }

    private func seconds(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1)) * track.duration
    }

    private func seek(_ seconds: Double) {
        target = seconds
        targetSetAt = Date()
        player.send(.seek(seconds, track.id))
    }
}

private struct VolumeBar: View {
    @ObservedObject var player: Player
    let volume: Int
    let accent: Color
    @State private var dragging: Double?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.system(size: 11))
                .onTapGesture { player.send(.volume(0)) }
            GeometryReader { geometry in
                let level = (dragging ?? Double(volume)) / 100
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule().fill(.white.opacity(0.85)).frame(width: max(4, geometry.size.width * level))
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let next = Double(min(max(value.location.x / max(1, geometry.size.width), 0), 1)) * 100
                        dragging = next
                        player.send(.volume(Int(next.rounded())))
                    }
                    .onEnded { _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dragging = nil }
                    })
            }
            .frame(height: 14)
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 11))
                .onTapGesture { player.send(.volume(100)) }
        }
        .foregroundStyle(.white.opacity(0.6))
        .accessibilityElement()
        .accessibilityLabel("Громкость")
        .accessibilityValue("\(volume)%")
        .accessibilityAdjustableAction { direction in
            player.send(.volume(volume + (direction == .increment ? 10 : -10)))
        }
    }
}

private struct CircleButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.black.opacity(0.45)))
                .foregroundStyle(.white.opacity(0.9))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
