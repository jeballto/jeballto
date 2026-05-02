import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct UpdateFeedSettingsTests {
  @Test
  func defaultBetaUpdatesEnabledUsesBetaFeed() throws {
    let defaults = try makeDefaults()
    let settings = UpdateFeedSettings(defaults: defaults, defaultBetaUpdatesEnabled: true)

    #expect(settings.isBetaUpdatesEnabled)
    #expect(settings.currentFeedURLString == UpdateFeedSettings.betaFeedURLString)
  }

  @Test
  func defaultBetaUpdatesDisabledUsesStableFeed() throws {
    let defaults = try makeDefaults()
    let settings = UpdateFeedSettings(defaults: defaults, defaultBetaUpdatesEnabled: false)

    #expect(!settings.isBetaUpdatesEnabled)
    #expect(settings.currentFeedURLString == UpdateFeedSettings.stableFeedURLString)
  }

  @Test(arguments: [true, false])
  func persistedValueOverridesDefault(_ persistedValue: Bool) throws {
    let defaults = try makeDefaults()
    let settings = UpdateFeedSettings(defaults: defaults, defaultBetaUpdatesEnabled: !persistedValue)

    settings.setBetaUpdatesEnabled(persistedValue)

    #expect(settings.isBetaUpdatesEnabled == persistedValue)
    #expect(settings.currentFeedURLString == expectedFeedURLString(for: persistedValue))
  }

  private func makeDefaults() throws -> UserDefaults {
    let suiteName = "com.jeballto.vmagent.tests.update-feed.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  private func expectedFeedURLString(for isBetaUpdatesEnabled: Bool) -> String {
    isBetaUpdatesEnabled ? UpdateFeedSettings.betaFeedURLString : UpdateFeedSettings.stableFeedURLString
  }
}
