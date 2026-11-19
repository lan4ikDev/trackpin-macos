import AppKit
import Sparkle

/// Updates through Sparkle. The feed is `appcast.xml` in the repository, the DMGs are
/// attached to GitHub releases, and every update is checked against `SUPublicEDKey`.
final class Updater: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // TrackPin has no Dock icon by default, so a found update brings the app forward
    // instead of waiting quietly behind other windows.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        NSApp.activate(ignoringOtherApps: true)
    }
}
