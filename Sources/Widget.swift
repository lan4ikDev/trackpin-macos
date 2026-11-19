import AppKit
import SwiftUI

struct WidgetView: View {
    @ObservedObject var player: Player
    let colors: ThemeColors
    let showTime: Bool
    let showSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Spotify", systemImage: "waveform")
                    .foregroundStyle(colors.accent)
                    .font(.system(size: 11, weight: .semibold))
                if player.demo {
                    Text("ДЕМО").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: showSettings) {
                    Image(systemName: "slider.horizontal.3").frame(width: 26, height: 22)
                }
                .accessibilityLabel("Настройки")
                .help("Настройки виджета")
            }
            switch player.playback {
            case let .track(track):
                TrackView(player: player, track: track, accent: colors.accent, showTime: showTime)
                    .id(track.id)
            case .closed:
                empty("Открой Spotify", detail: "Запусти трек в приложении.", action: "Открыть Spotify", perform: player.openSpotify)
            case .idle:
                empty("Трек не выбран", detail: "Включи музыку в Spotify.", action: "Открыть Spotify", perform: player.openSpotify)
            case .denied:
                empty("Нужен доступ", detail: "Разреши TrackPin управлять Spotify в настройках «Автоматизация».", action: "Настройки macOS") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(url)
                    }
                }
            case .unavailable:
                empty("Spotify не ответил", detail: "Проверь, что плеер запущен.", action: "Повторить", perform: player.retry)
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(LinearGradient(colors: colors.background, startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.14), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .buttonStyle(.plain)
    }

    private func empty(_ title: String, detail: String, action: String, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Spacer(minLength: 0)
            Text(title).font(.system(size: 18, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(action, action: perform)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(colors.accent)
                .padding(.top, 4)
            Spacer(minLength: 0)
        }
    }
}

private struct TrackView: View {
    @ObservedObject var player: Player
    let track: Track
    let accent: Color
    let showTime: Bool
    @State private var isDragging = false
    @State private var preview: Double?
    @State private var target: Double?
    @State private var pendingReset: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                cover(size: 57)
                info
                Spacer(minLength: 0)
                controls
            }
            progress
        }
        .onChange(of: track.position) { _, position in
            if let target, abs(position - target) <= 2 { self.target = nil }
        }
        .onDisappear { pendingReset?.cancel() }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(track.title).font(.system(size: 14, weight: .semibold))
                .lineLimit(1).help(track.title)
            Text(track.artist).font(.system(size: 12)).foregroundStyle(.secondary)
                .lineLimit(1).help(track.artist)
        }
    }

    private func cover(size: CGFloat) -> some View {
        AsyncImage(url: track.artwork) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    if player.demo {
                        LinearGradient(colors: [.indigo, .purple, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
                        ForEach(0..<4) { ring in
                            Circle().strokeBorder(.white.opacity(0.27), lineWidth: 1)
                                .frame(width: size * (0.26 + Double(ring) * 0.17))
                        }
                    } else {
                        Color.white.opacity(0.08)
                        Image(systemName: "music.note").foregroundStyle(accent)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Обложка")
    }

    private var progress: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(get: { preview ?? target ?? track.position }, set: { value in
                    if isDragging { preview = value }
                    else { seek(to: value) }
                }),
                in: 0...max(1, track.duration),
                onEditingChanged: { editing in
                    isDragging = editing
                    if !editing, let preview { seek(to: preview) }
                },
                minimumValueLabel: EmptyView(),
                maximumValueLabel: EmptyView()
            ) { Text("Позиция в треке") }
                .labelsHidden()
                .controlSize(.small)
                .tint(accent)
                .disabled(track.duration <= 0)
                .accessibilityAdjustableAction { direction in
                    let time = preview ?? target ?? track.position
                    switch direction {
                    case .increment: seek(to: min(track.duration, time + 5))
                    case .decrement: seek(to: max(0, time - 5))
                    @unknown default: break
                    }
                }
                .accessibilityValue(Self.time(preview ?? target ?? track.position))
            if showTime {
                HStack {
                    Text(Self.time(preview ?? target ?? track.position))
                    Spacer()
                    Text(Self.time(track.duration))
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    private func seek(to seconds: Double) {
        preview = nil
        target = seconds
        player.send(.seek(seconds, track.id))
        pendingReset?.cancel()
        pendingReset = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { target = nil }
        }
    }

    private var controls: some View {
        HStack(spacing: 5) {
            control("backward.end.fill", name: "Предыдущий трек", command: .previous)
            let label = track.playing ? "Пауза" : "Воспроизвести"
            Button { player.send(.toggle) } label: {
                Image(systemName: track.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(accent, in: Circle())
                    .foregroundStyle(Color.black.opacity(0.84))
            }
            .accessibilityLabel(label).help(label)
            control("forward.end.fill", name: "Следующий трек", command: .next)
        }
    }

    private func control(_ icon: String, name: String, command: PlayerCommand) -> some View {
        Button { player.send(command) } label: {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.83))
                .frame(width: 22, height: 28)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(name).help(name)
    }

    private static func time(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
