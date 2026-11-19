import AppIntents
import Foundation

/// Playback command sent from a widget button (or Shortcuts) to the host app.
enum PlayerAction: String, AppEnum {
    case toggle, next, previous, rewind, forward, volumeUp, volumeDown

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Действие"
    static var caseDisplayRepresentations: [PlayerAction: DisplayRepresentation] = [
        .toggle: "Пауза или воспроизведение",
        .next: "Следующий трек",
        .previous: "Предыдущий трек",
        .rewind: "Перемотать назад",
        .forward: "Перемотать вперёд",
        .volumeUp: "Громче",
        .volumeDown: "Тише"
    ]
}

enum TrackPinError: Error, CustomLocalizedStringResourceConvertible {
    case hostUnavailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .hostUnavailable: "TrackPin не запущен. Открой приложение и попробуй снова."
        }
    }
}

/// Runs inside the widget extension when a widget button is pressed. The extension is
/// sandboxed and cannot talk to the player itself, so it forwards the command to the
/// TrackPin app, which executes it through AppleScript and answers with fresh state.
/// WidgetKit reloads the widget timeline once `perform()` returns.
struct PlayerControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Управлять плеером"
    static var description = IntentDescription("Пауза, переключение и перемотка треков в Spotify, Apple Music или Яндекс Музыке через TrackPin.")

    @Parameter(title: "Действие")
    var action: PlayerAction

    @Parameter(title: "Шаг перемотки в секундах", default: 15)
    var step: Int

    init() {}

    init(action: PlayerAction, step: Int = 15) {
        self.action = action
        self.step = step
    }

    func perform() async throws -> some IntentResult {
        guard await WidgetTransport.send(.command(action, step: step)) != nil else {
            throw TrackPinError.hostUnavailable
        }
        return .result()
    }
}
