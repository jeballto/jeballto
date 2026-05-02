import Foundation

struct UpdateFeedSettings {
  static let stableFeedURLString = "https://jeballto.com/releases/stable/appcast.xml"
  static let betaFeedURLString = "https://jeballto.com/releases/beta/appcast.xml"

  private static let betaUpdatesEnabledKey = "BetaUpdatesEnabled"

  private let defaults: UserDefaults
  private let defaultBetaUpdatesEnabled: Bool

  init(defaults: UserDefaults = .standard, defaultBetaUpdatesEnabled: Bool) {
    self.defaults = defaults
    self.defaultBetaUpdatesEnabled = defaultBetaUpdatesEnabled
  }

  var isBetaUpdatesEnabled: Bool {
    guard let value = defaults.object(forKey: Self.betaUpdatesEnabledKey) as? Bool else {
      return defaultBetaUpdatesEnabled
    }
    return value
  }

  var currentFeedURLString: String {
    isBetaUpdatesEnabled ? Self.betaFeedURLString : Self.stableFeedURLString
  }

  func setBetaUpdatesEnabled(_ isEnabled: Bool) {
    defaults.set(isEnabled, forKey: Self.betaUpdatesEnabledKey)
  }
}
