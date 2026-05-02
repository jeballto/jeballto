import Sparkle
import UserNotifications

/// Manages Sparkle software update integration.
/// Implements gentle reminders for background app update notifications.
class UpdaterManager: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
  #if DEBUG
  private static let defaultBetaUpdatesEnabled = true
  #else
  private static let defaultBetaUpdatesEnabled = false
  #endif

  private let feedSettings: UpdateFeedSettings

  private(set) lazy var updaterController: SPUStandardUpdaterController = .init(
    startingUpdater: false,
    updaterDelegate: self,
    userDriverDelegate: self
  )

  init(feedSettings: UpdateFeedSettings = .init(defaultBetaUpdatesEnabled: UpdaterManager.defaultBetaUpdatesEnabled)) {
    self.feedSettings = feedSettings
    super.init()
    _ = updaterController
    // Defer starting to avoid layout recursion during app launch
    DispatchQueue.main.async { [weak self] in
      self?.updaterController.startUpdater()
    }
  }

  var isBetaUpdatesEnabled: Bool {
    feedSettings.isBetaUpdatesEnabled
  }

  func setBetaUpdatesEnabled(_ isEnabled: Bool) {
    feedSettings.setBetaUpdatesEnabled(isEnabled)
  }

  // MARK: - SPUUpdaterDelegate

  func feedURLString(for updater: SPUUpdater) -> String? {
    feedSettings.currentFeedURLString
  }

  // MARK: - SPUStandardUserDriverDelegate (Gentle Reminders)

  var supportsGentleScheduledUpdateReminders: Bool { true }

  func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem,
    andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    if immediateFocus { return true }
    return false
  }

  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool,
    forUpdate update: SUAppcastItem,
    state: SPUUserUpdateState
  ) {
    guard !handleShowingUpdate else { return }
    showUpdateNotification(for: update)
  }

  func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
    UNUserNotificationCenter.current().removeDeliveredNotifications(
      withIdentifiers: ["jeballto-update-available"]
    )
  }

  func standardUserDriverWillFinishUpdateSession() {
    UNUserNotificationCenter.current().removeDeliveredNotifications(
      withIdentifiers: ["jeballto-update-available"]
    )
  }

  // MARK: - Private

  private func showUpdateNotification(for update: SUAppcastItem) {
    let content = UNMutableNotificationContent()
    content.title = "Jeballto Update Available"
    content.body = "Version \(update.displayVersionString) is available."
    content.sound = .default

    let request = UNNotificationRequest(
      identifier: "jeballto-update-available",
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().add(request)
  }
}
