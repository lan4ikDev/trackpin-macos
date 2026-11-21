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
    private let history: PlayHistory
    private let model = MiniPlayerModel()
    private let lyrics = LyricsStore()
    private var panel: MiniPanel?
    private var closing: DispatchWorkItem?
    private var observations: Set<AnyCancellable> = []
    var showSettings: () -> Void = {}
    var onVisibilityChange: (Bool) -> Void = { _ in }

    /// Room around the card for its shadow.
    static let margin: CGFloat = 28

    private let sleepTimer: SleepTimer

    init(player: Player, preferences: Preferences, publisher: WidgetPublisher, history: PlayHistory, sleepTimer: SleepTimer) {
        self.sleepTimer = sleepTimer
        self.player = player
        self.preferences = preferences
        self.publisher = publisher
        self.history = history
        super.init()
        // The card's height depends on these settings and on the history list: resize an open
        // panel when they change.
        preferences.objectWillChange
            .merge(with: model.$showsHistory.removeDuplicates().map { _ in () }.eraseToAnyPublisher())
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.fitPanel() }
            .store(in: &observations)
        // The list grows up to five rows, then scrolls.
        history.$entries
            .map { min($0.count, 5) }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.fitPanel() }
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
        if !panel.isVisible { model.presented = false }
        panel.orderFrontRegardless()
        panel.makeKey()
        startGestures()
        onVisibilityChange(true)
        // A calm, fully damped spring: no overshoot, no bounce.
        let animation: Animation? = preferences.popupAnimated ? .spring(response: 0.5, dampingFraction: 1) : nil
        DispatchQueue.main.async { withAnimation(animation) { self.model.presented = true } }
    }

    /// When the mini player last started closing.
    private var closedAt = Date.distantPast

    /// A click on the widget: opens the mini player, or closes it when it is open. A click
    /// on the widget first takes the focus from the open mini player, which then closes on its
    /// own just before the widget's request arrives; that request must not reopen it.
    func toggleFromWidget(at point: NSPoint) {
        if isVisible && closing == nil {
            close()
        } else if Date().timeIntervalSince(closedAt) > 0.8 {
            show(from: point)
        }
    }

    func close() {
        guard let panel, panel.isVisible, closing == nil else { return }
        closedAt = Date()
        let animated = preferences.popupAnimated
        withAnimation(animated ? .easeInOut(duration: 0.22) : nil) { model.presented = false }
        stopGestures()
        let work = DispatchWorkItem { [weak self] in
            panel.orderOut(nil)
            self?.closing = nil
            self?.onVisibilityChange(false)
        }
        closing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 0.23 : 0), execute: work)
    }

    // MARK: Gestures
    //
    // Two fingers sideways switch the track, up and down change the volume. Each trackpad
    // gesture keeps the direction it started with, so a slightly diagonal scroll does not jump
    // between the two. Over the lyrics and the history list the scroll belongs to the list
    // (only a sideways swipe still switches the track there).

    private enum Axis { case horizontal, vertical }

    private var scrollMonitor: Any?
    /// The direction of the current trackpad gesture, decided by its first movement.
    private var gestureAxis: Axis?
    /// Whether the current trackpad gesture started over the lyrics or the history.
    private var gestureOverList = false
    /// Horizontal distance of the current trackpad gesture, and whether it already switched.
    private var swipeDistance: CGFloat = 0
    private var swipeDone = false
    /// The volume being set by scrolling, with its fraction; the player's reported value lags behind.
    private var scrollVolume: Double?
    private var scrollVolumeAt = Date.distantPast

    private func startGestures() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.preferences.popupGestures, event.window === self.panel else { return event }
            return self.handleScroll(event) ? nil : event
        }
    }

    private func stopGestures() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        gestureAxis = nil
    }

    /// True over the lyrics or the history list. Their frames come from the SwiftUI views
    /// (`scrollArea()`), in the hosting view's coordinates with the origin at the top left.
    private func isOverList(_ event: NSEvent) -> Bool {
        guard let content = panel?.contentView else { return false }
        let local = content.convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: local.x, y: content.isFlipped ? local.y : content.bounds.height - local.y)
        return model.scrollAreas.contains { $0.contains(point) }
    }

    /// Returns true when the event was used, false to pass it on to the view under the pointer.
    private func handleScroll(_ event: NSEvent) -> Bool {
        // The direction the fingers (or the wheel) actually moved, whatever "natural scrolling" is.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        let dx = event.scrollingDeltaX * sign
        let dy = event.scrollingDeltaY * sign

        // A mouse wheel: no gesture phases, every click stands alone.
        if event.phase.isEmpty && event.momentumPhase.isEmpty {
            guard dy != 0, abs(dy) >= abs(dx), !isOverList(event) else { return false }
            changeVolume(by: Double(dy) * (event.hasPreciseScrollingDeltas ? 0.2 : 3))
            return true
        }

        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            gestureAxis = nil
            gestureOverList = isOverList(event)
            swipeDistance = 0
            swipeDone = false
            scrollVolume = nil
        }
        // The inertia after the fingers lift: a list keeps scrolling, nothing else reacts to it.
        if !event.momentumPhase.isEmpty { return !gestureOverList }
        if gestureAxis == nil, dx != 0 || dy != 0 {
            gestureAxis = abs(dx) > abs(dy) ? .horizontal : .vertical
        }
        defer {
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { swipeDistance = 0; swipeDone = false }
        }

        switch gestureAxis {
        case .horizontal:
            swipeDistance += dx
            if !swipeDone, abs(swipeDistance) > 70 {
                swipeDone = true
                // Fingers to the left: next track, like pushing the card away.
                player.send(swipeDistance < 0 ? .next : .previous)
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            // A vertical list ignores sideways movement anyway; let it see the whole gesture.
            return !gestureOverList
        case .vertical:
            if gestureOverList { return false }
            changeVolume(by: Double(dy) * 0.2)
            return true
        case nil:
            return !gestureOverList
        }
    }

    /// Fingers up raise the volume. Sends a command only when the whole percent changes.
    private func changeVolume(by delta: Double) {
        guard let current = player.playback.currentTrack?.volume else { return }
        if scrollVolume == nil || Date().timeIntervalSince(scrollVolumeAt) > 1.5 { scrollVolume = Double(current) }
        let volume = min(100, max(0, (scrollVolume ?? Double(current)) - delta))
        scrollVolume = volume
        scrollVolumeAt = Date()
        let level = Int(volume.rounded())
        if level != current { player.send(.volume(level)) }
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
        let view = MiniPlayerView(player: player, preferences: preferences, publisher: publisher, history: history, model: model,
                                  sleepTimer: sleepTimer,
                                  lyrics: lyrics,
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

    /// Keyboard: space plays or pauses, ←/→ seek, ↑/↓ change the volume, H shows the history,
    /// Esc closes.
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
        case 4 where preferences.keepHistory && event.modifierFlags.intersection([.command, .control, .option]).isEmpty:
            withAnimation(.easeInOut(duration: 0.2)) { model.showsHistory.toggle() }
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

    /// Stops the cover animations while the panel is covered, on another Space or the display sleeps.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let panel else { return }
        model.onScreen = panel.occlusionState.contains(.visible)
    }
}

final class MiniPlayerModel: ObservableObject {
    @Published var presented = false
    @Published var anchor: UnitPoint = .center
    @Published var onScreen = true
    /// The recently played list under the controls.
    @Published var showsHistory = false
    /// Frames of the lyrics and the history list, where scrolling belongs to the list. Not
    /// published: only the scroll gestures read it.
    var scrollAreas: [CGRect] = []
}

/// Collects the frames of the scrolling lists in the mini player.
private struct ScrollAreasKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

private extension View {
    /// Marks a scrolling list: the mini player's scroll gestures leave it to the list.
    func scrollArea() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: ScrollAreasKey.self,
                                       value: [proxy.frame(in: .named(MiniPlayerView.coordinateSpace))])
            }
        }
    }
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
    @ObservedObject var history: PlayHistory
    @ObservedObject var model: MiniPlayerModel
    @ObservedObject var sleepTimer: SleepTimer
    let lyrics: LyricsStore
    let close: () -> Void
    let showSettings: () -> Void

    @State private var hovering = false

    private var width: CGFloat { preferences.popupSize.width }
    private var padding: CGFloat { preferences.popupSize == .compact ? 12 : 14 }
    private var corner: CGFloat { preferences.popupSize == .large ? 30 : 26 }

    private var colors: ThemeColors {
        let themed = preferences.style.colors(palette: publisher.displayPalette, scheme: .dark)
        return themed.dark ? themed : WidgetTheme.graphite.colors(palette: publisher.displayPalette, scheme: .dark)
    }

    var body: some View {
        card
            .frame(width: width)
            .background { background.opacity(preferences.popupOpacity) }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            // The card fades in from slightly smaller and lower, centered on itself rather than
            // shooting out of the click point.
            .scaleEffect(model.presented ? 1 : 0.94, anchor: .center)
            .offset(y: model.presented ? 0 : 14)
            .opacity(model.presented ? 1 : 0)
            .padding(MiniPlayerController.margin)
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .buttonStyle(.plain)
            .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
            .coordinateSpace(name: Self.coordinateSpace)
            .onPreferenceChange(ScrollAreasKey.self) { [model] areas in model.scrollAreas = areas }
    }

    /// The whole hosting view, for the frames of the scrolling lists.
    static let coordinateSpace = "TrackPinMiniPlayer"

    private var name: String { player.source.title }

    @ViewBuilder private var card: some View {
        switch player.playback {
        case let .track(track):
            TrackCard(player: player, preferences: preferences, publisher: publisher, sleepTimer: sleepTimer,
                      lyrics: lyrics, history: history, model: model,
                      track: track, accent: colors.accent, width: width, padding: padding, corner: corner,
                      hovering: hovering, animating: model.presented && model.onScreen && track.playing,
                      close: close, showSettings: showSettings)
        case .closed:
            message("music.note", String(localized: "Плеер закрыт"), String(localized: "Запусти \(name), и здесь появится трек."), String(localized: "Открыть \(name)"), player.openPlayer)
        case .idle:
            message("music.note.list", String(localized: "Ничего не играет"), String(localized: "Включи трек в плеере «\(name)»."), String(localized: "Открыть \(name)"), player.openPlayer)
        case .denied:
            message("lock.fill", String(localized: "Нужен доступ"), player.source.accessHint, String(localized: "Открыть настройки"), player.source.requestAccess)
        case .unavailable:
            message("exclamationmark.triangle.fill", String(localized: "Плеер не ответил"), String(localized: "Проверь, что плеер запущен."), String(localized: "Повторить"), player.retry)
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
    let lyrics: LyricsStore
    @ObservedObject var history: PlayHistory
    @ObservedObject var model: MiniPlayerModel
    let track: Track
    let accent: Color
    let width: CGFloat
    let padding: CGFloat
    let corner: CGFloat
    let hovering: Bool
    /// The panel is open, on screen and the track plays: the record spins and the bars move.
    let animating: Bool
    let close: () -> Void
    let showSettings: () -> Void

    @State private var copied = false

    private var spins: Bool { preferences.popupCoverShape == .circle && preferences.popupSpinsRecord }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            cover
            if preferences.popupVisualizer == .wide {
                Equalizer(bars: 28, active: animating, color: accent)
                    .frame(height: 22)
                    .accessibilityHidden(true)
            }
            info
            if sleepTimer.isActive { sleepStatus }
            ScrubBar(player: player, track: track, accent: accent, showTime: preferences.style.showTime)
            controls
            if preferences.popupShowsLyrics {
                LyricsPanel(player: player, lyrics: lyrics, track: track, accent: accent, compact: width < 280)
            }
            if preferences.popupShowsVolume, let volume = track.volume {
                VolumeBar(player: player, volume: volume, accent: accent)
            }
            if model.showsHistory && preferences.keepHistory {
                HistoryList(history: history, current: track, accent: accent, width: width - padding * 2)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
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
                // Cross-fade from the old cover to the new one with a little zoom and blur.
                Image(nsImage: image).resizable().scaledToFill()
                    .id(ObjectIdentifier(image))
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 1.08)),
                        removal: .opacity.combined(with: .scale(scale: 0.94))))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: coverSide * 0.28, weight: .semibold))
                    .foregroundStyle(accent)
            }
            if preferences.popupCoverShape == .circle {
                // Vinyl grooves and the spindle hole.
                ForEach([0.94, 0.82, 0.7, 0.58], id: \.self) { ratio in
                    Circle().strokeBorder(.black.opacity(0.16), lineWidth: 1).frame(width: coverSide * ratio)
                }
                Circle().fill(.black.opacity(0.85)).frame(width: coverSide * 0.12)
                    .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
            }
        }
        .frame(width: coverSide, height: coverSide)
        .clipShape(coverShape)
        .modifier(Spin(active: spins && animating))
        .scaleEffect(track.playing || preferences.popupCoverShape == .circle ? 1 : 0.92)
        .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: track.playing)
        .animation(.easeInOut(duration: 0.45), value: publisher.coverImage)
        .overlay(alignment: .top) {
            HStack(spacing: 6) {
                CircleButton(icon: "gearshape.fill", label: "Настройки", action: showSettings)
                sleepMenu
                Spacer()
                CircleButton(icon: "arrow.up.forward.app.fill", label: "Открыть \(player.source.title)", action: player.openPlayer)
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
            // The new title slides in from the right while the old one leaves to the left.
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)))
            Spacer(minLength: 0)
            if preferences.popupVisualizer == .compact {
                Equalizer(bars: 4, active: animating, color: accent)
                    .frame(width: 18, height: 16)
                    .accessibilityHidden(true)
            }
            Button {
                preferences.popupShowsLyrics.toggle()
            } label: {
                Image(systemName: preferences.popupShowsLyrics ? "quote.bubble.fill" : "quote.bubble")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(preferences.popupShowsLyrics ? accent : .white.opacity(0.75))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .help(preferences.popupShowsLyrics ? "Скрыть текст песни" : "Показать текст песни")
            .accessibilityLabel("Текст песни")
            .accessibilityAddTraits(preferences.popupShowsLyrics ? .isSelected : [])
            if preferences.keepHistory {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { model.showsHistory.toggle() }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.showsHistory ? accent : .white.opacity(0.75))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .help("Недавно играли (H)")
                .accessibilityLabel("Недавно играли")
                .accessibilityAddTraits(model.showsHistory ? .isSelected : [])
            }
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
        .clipped()
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: track.id)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            if preferences.popupShowsModes {
                mode("shuffle", active: track.shuffling == true, label: String(localized: "Перемешать")) {
                    player.send(.shuffle(!(track.shuffling ?? false)))
                }
                Spacer(minLength: 0)
            }
            control("backward.end.fill", label: String(localized: "Предыдущий трек")) { player.send(.previous) }
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
            control("forward.end.fill", label: String(localized: "Следующий трек")) { player.send(.next) }
            if preferences.popupShowsModes {
                Spacer(minLength: 0)
                mode("repeat", active: track.repeating == true, label: String(localized: "Повтор")) {
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

/// Tracks TrackPin saw playing, newest first. A click plays a track again.
private struct HistoryList: View {
    @ObservedObject var history: PlayHistory
    let current: Track
    let accent: Color
    let width: CGFloat

    private static let rowHeight: CGFloat = 44
    private static let visibleRows = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Недавно играли")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                if !history.entries.isEmpty {
                    Button("Очистить") { withAnimation { history.clear() } }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .help("Очистить историю")
                }
            }
            if history.entries.isEmpty {
                Text("Здесь появятся треки, которые ты слушаешь, пока TrackPin запущен.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(history.entries.enumerated()), id: \.element.id) { index, entry in
                            HistoryRow(history: history, entry: entry,
                                       nowPlaying: index == 0 && entry.trackID == current.id && current.playing,
                                       accent: accent)
                                .frame(height: Self.rowHeight)
                        }
                    }
                }
                .frame(width: width, height: Self.rowHeight * CGFloat(min(history.entries.count, Self.visibleRows)))
                .scrollArea()
            }
        }
        .padding(.top, 2)
    }
}

private struct HistoryRow: View {
    @ObservedObject var history: PlayHistory
    let entry: HistoryEntry
    let nowPlaying: Bool
    let accent: Color

    @State private var hovering = false

    var body: some View {
        Button { history.play(entry) } label: {
            HStack(spacing: 10) {
                AsyncImage(url: entry.artwork) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                }
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(entry.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 4)
                if nowPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(accent)
                } else if hovering && entry.playable {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.8))
                } else {
                    Text(Self.age(of: entry.playedAt))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .disabled(!entry.playable)
        .onHover { hovering = $0 }
        .help(entry.playable ? "Включить «\(entry.title)»" : entry.title)
        .accessibilityLabel("\(entry.title), \(entry.artist)")
        .contextMenu {
            if entry.playable {
                Button("Включить") { history.play(entry) }
            }
            if let link = entry.webLink {
                Button("Скопировать ссылку") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                }
            }
            Divider()
            Button("Удалить из истории") { withAnimation { history.remove(entry) } }
        }
    }

    /// String(localized: "сейчас"), String(localized: "5 мин"), String(localized: "3 ч"), String(localized: "2 дн").
    static func age(of date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        switch seconds {
        case ..<60: return String(localized: "сейчас")
        case ..<3600: return String(localized: "\(Int(seconds / 60)) мин")
        case ..<86400: return String(localized: "\(Int(seconds / 3600)) ч")
        default: return String(localized: "\(Int(seconds / 86400)) дн")
        }
    }
}

/// The seek bar. The position of a playing track is extrapolated from the last read, so the
/// bar moves smoothly while the player is only asked once a second (or less).
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
        // Until the player reports the new position, keep showing where the user seeked to.
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

/// Lyrics under the controls. The panel has a fixed height whatever it shows, so the card
/// does not change size while lyrics load or when the track changes.
private struct LyricsPanel: View {
    @ObservedObject var player: Player
    @ObservedObject var lyrics: LyricsStore
    let track: Track
    let accent: Color
    let compact: Bool

    private var height: CGFloat { compact ? 104 : 124 }

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.2)))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .task(id: LyricsStore.key(for: track)) { lyrics.load(track) }
            .animation(.easeInOut(duration: 0.25), value: lyrics.phase(for: track))
    }

    @ViewBuilder private var content: some View {
        switch lyrics.phase(for: track) {
        case .loading:
            ProgressView().controlSize(.small)
        case .failed:
            VStack(spacing: 6) {
                note(String(localized: "Не удалось загрузить текст"))
                Button("Повторить") { lyrics.load(track, force: true) }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
            }
        case .loaded(.notFound):
            note(String(localized: "Текст не найден"))
        case .loaded(.instrumental):
            note(String(localized: "♪ Инструментал"))
        case let .loaded(.plain(text)):
            ScrollView(.vertical, showsIndicators: false) {
                Text(text)
                    .font(.system(size: compact ? 12 : 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .scrollArea()
            .id(LyricsStore.key(for: track))
        case let .loaded(.synced(lines)):
            TimelineView(.periodic(from: .now, by: track.playing ? 0.25 : 3600)) { context in
                SyncedLyrics(lines: lines, current: Lyrics.currentLine(in: lines, at: position(at: context.date)),
                             compact: compact, seek: { player.send(.seek($0, track.id)) })
            }
            .id(LyricsStore.key(for: track))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
    }

    /// The same extrapolation as the seek bar: Spotify is only read once a second or less.
    private func position(at date: Date) -> Double {
        let elapsed = track.playing ? max(0, date.timeIntervalSince(player.sampledAt)) : 0
        return min(track.duration, track.position + elapsed)
    }
}

private struct SyncedLyrics: View {
    let lines: [LyricLine]
    let current: Int?
    let compact: Bool
    let seek: (Double) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                    ForEach(lines) { line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: compact ? 13 : 15, weight: .bold))
                            .foregroundStyle(.white.opacity(opacity(of: line)))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentShape(Rectangle())
                            .onTapGesture { seek(line.time) }
                            .help("Перемотать сюда")
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 12)
                // Room so the first and last lines can sit in the middle.
                .padding(.vertical, compact ? 40 : 48)
                .animation(.easeInOut(duration: 0.25), value: current)
            }
            .scrollArea()
            .onAppear { proxy.scrollTo(current ?? 0, anchor: .center) }
            .onChange(of: current) { _, line in
                withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(line ?? 0, anchor: .center) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Текст песни")
        .accessibilityValue(current.map { lines[$0].text } ?? "")
    }

    /// The current line is bright, the ones already sung are dimmer than the ones ahead.
    private func opacity(of line: LyricLine) -> Double {
        guard let current else { return 0.45 }
        if line.id == current { return 1 }
        return line.id < current ? 0.3 : 0.45
    }
}

/// Turns the record cover at a calm, constant speed. It keeps its angle on pause, and the
/// timeline stops completely while `active` is false, so a paused or hidden player costs nothing.
private struct Spin: ViewModifier {
    let active: Bool
    /// Degrees per second: one turn in 8 seconds.
    private let speed = 45.0

    @State private var base = 0.0
    @State private var since: Date?

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { context in
            content.rotationEffect(.degrees(angle(at: context.date)))
        }
        .onChange(of: active, initial: true) { _, running in
            if running {
                since = Date()
            } else {
                base = angle(at: Date())
                since = nil
            }
        }
    }

    private func angle(at date: Date) -> Double {
        guard let since else { return base }
        return (base + max(0, date.timeIntervalSince(since)) * speed).truncatingRemainder(dividingBy: 360)
    }
}

/// Dancing bars while music plays. TrackPin cannot hear the audio Spotify plays (that would
/// need the screen recording permission), so the motion is generated, not measured. Drawn with
/// a single Canvas at 24 frames per second, and not at all while `active` is false.
struct Equalizer: View {
    let bars: Int
    let active: Bool
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !active)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                guard bars > 0 else { return }
                let gap = max(1.5, size.width / CGFloat(bars) * 0.3)
                let width = max(1, (size.width - gap * CGFloat(bars - 1)) / CGFloat(bars))
                for index in 0..<bars {
                    let level = active ? Self.level(index, at: time) : 0.12
                    let height = max(width, size.height * level)
                    let rect = CGRect(x: CGFloat(index) * (width + gap), y: size.height - height, width: width, height: height)
                    canvas.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(color.opacity(active ? 0.9 : 0.5)))
                }
            }
        }
    }

    /// A mix of a few sines with a different speed and phase per bar, 0.12...1.
    static func level(_ index: Int, at time: Double) -> CGFloat {
        let x = Double(index)
        let value = 0.5
            + 0.26 * sin(time * (4.3 + x.truncatingRemainder(dividingBy: 3) * 1.1) + x * 1.7)
            + 0.18 * sin(time * 7.9 + x * 0.83)
            + 0.08 * sin(time * 13.1 + x * 2.9)
        return CGFloat(min(max(value, 0.12), 1))
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
                    // The player shows the new volume right away, so the bar can let go at once.
                    // A delayed reset could also land in the middle of the next drag.
                    .onEnded { _ in dragging = nil })
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
