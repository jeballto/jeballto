import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct VirtualizationCapabilitiesTests {
  @Test
  func appleSiliconHostWithEntitlementReportsCurrentCapabilitiesAvailable() {
    let capabilities = VirtualizationCapabilities(
      probe: VirtualizationHostProbe(
        architecture: "arm64",
        operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0),
        virtualizationSupported: true,
        entitlements: ["com.apple.security.virtualization"]
      )
    )

    #expect(capabilities.host.architecture == "arm64")
    #expect(capabilities.host.macOSVersion == "26.5")
    #expect(capabilities.host.virtualizationSupported)
    #expect(capabilities.host.maxConcurrentVMs == 2)
    #expect(Set(capabilities.features.map(\.id)) == [
      "macOSVirtualization",
      "macOSInstallation",
      "natNetworking",
      "portForwarding",
      "commandExecution",
      "guiDisplay",
      "screenshotCapture",
      "keystrokeInjection",
      "jeballtofileExecution",
      "ociImagePackaging",
    ])
    #expect(capabilities.features.map(\.enabled).allSatisfy { $0 })
    #expect(capabilities.features.map(\.lifecycle.rawValue).allSatisfy { $0 == "stable" })
    #expect(capabilities.features.map(\.minimumOS).allSatisfy { $0 == "26.0" })
  }

  @Test
  func disabledFlagKeepsCapabilityVisibleButUnavailableToRoutes() throws {
    let capabilities = VirtualizationCapabilities(
      probe: VirtualizationHostProbe(
        architecture: "arm64",
        operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0),
        virtualizationSupported: true,
        entitlements: ["com.apple.security.virtualization"]
      ),
      featureFlags: VirtualizationFeatureFlags(overrides: [.guiDisplay: false])
    )

    let guiDisplay = try #require(capabilities.features.first { $0.id == "guiDisplay" })

    #expect(guiDisplay.status == .available)
    #expect(guiDisplay.enabled == false)
    #expect(guiDisplay.reason == "Capability is disabled")
  }

  @Test
  func developmentLifecycleDisablesCapabilityByDefault() throws {
    let capabilities = makeCapabilities(
      featureFlags: VirtualizationFeatureFlags(lifecycleOverrides: [.guiDisplay: .development])
    )

    let guiDisplay = try #require(capabilities.features.first { $0.id == "guiDisplay" })

    #expect(guiDisplay.status == .available)
    #expect(guiDisplay.enabled == false)
    #expect(guiDisplay.lifecycle == .development)
    #expect(guiDisplay.deprecation == nil)
    #expect(guiDisplay.reason == "Capability is in development")
  }

  @Test
  func developmentLifecycleCanBeExplicitlyEnabled() throws {
    let capabilities = makeCapabilities(
      featureFlags: VirtualizationFeatureFlags(
        overrides: [.guiDisplay: true],
        lifecycleOverrides: [.guiDisplay: .development]
      )
    )

    let guiDisplay = try #require(capabilities.features.first { $0.id == "guiDisplay" })

    #expect(guiDisplay.enabled)
    #expect(guiDisplay.lifecycle == .development)
    #expect(guiDisplay.reason == nil)
  }

  @Test
  func deprecatedLifecycleStaysDisabledAndReportsDeprecation() throws {
    let deprecation = VirtualizationFeatureDeprecation(
      since: "0.4.0",
      message: "Use screenshotCapture instead"
    )
    let capabilities = makeCapabilities(
      featureFlags: VirtualizationFeatureFlags(
        overrides: [.guiDisplay: true],
        lifecycleOverrides: [.guiDisplay: .deprecated(deprecation: deprecation)]
      )
    )

    let guiDisplay = try #require(capabilities.features.first { $0.id == "guiDisplay" })

    #expect(guiDisplay.status == .available)
    #expect(guiDisplay.enabled == false)
    #expect(guiDisplay.lifecycle == .deprecated(deprecation: deprecation))
    #expect(guiDisplay.deprecation == deprecation)
    #expect(guiDisplay.reason == "Capability is deprecated since 0.4.0: Use screenshotCapture instead")
  }

  @Test
  func apiResponseIncludesLifecycleAndDeprecationDetails() throws {
    let deprecation = VirtualizationFeatureDeprecation(
      since: "0.4.0",
      message: "Use screenshotCapture instead"
    )
    let capabilities = makeCapabilities(
      featureFlags: VirtualizationFeatureFlags(
        lifecycleOverrides: [.guiDisplay: .deprecated(deprecation: deprecation)]
      )
    )
    let response = SystemCapabilitiesResponse(capabilities: capabilities)

    let guiDisplay = try #require(response.features.first { $0.id == "guiDisplay" })
    let responseDeprecation = try #require(guiDisplay.deprecation)

    #expect(guiDisplay.lifecycle == "deprecated")
    #expect(responseDeprecation.since == "0.4.0")
    #expect(responseDeprecation.message == "Use screenshotCapture instead")
  }

  @Test
  func unsupportedArchitectureDisablesVirtualizationBackedCapabilities() throws {
    let capabilities = VirtualizationCapabilities(
      probe: VirtualizationHostProbe(
        architecture: "x86_64",
        operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0),
        virtualizationSupported: true,
        entitlements: ["com.apple.security.virtualization"]
      )
    )

    let macOSVirtualization = try #require(capabilities.features.first { $0.id == "macOSVirtualization" })
    let commandExecution = try #require(capabilities.features.first { $0.id == "commandExecution" })
    let jeballtofileExecution = try #require(capabilities.features.first { $0.id == "jeballtofileExecution" })
    let imagePackaging = try #require(capabilities.features.first { $0.id == "ociImagePackaging" })

    #expect(macOSVirtualization.status == .unavailable)
    #expect(macOSVirtualization.enabled == false)
    #expect(macOSVirtualization.reason == "Requires Apple Silicon")
    #expect(commandExecution.status == .unavailable)
    #expect(commandExecution.enabled == false)
    #expect(jeballtofileExecution.status == .unavailable)
    #expect(jeballtofileExecution.enabled == false)
    #expect(imagePackaging.status == .available)
    #expect(imagePackaging.enabled)
  }

  @Test
  func missingVirtualizationEntitlementReportsUnavailableReason() throws {
    let capabilities = VirtualizationCapabilities(
      probe: VirtualizationHostProbe(
        architecture: "arm64",
        operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0),
        virtualizationSupported: true,
        entitlements: []
      )
    )

    let natNetworking = try #require(capabilities.features.first { $0.id == "natNetworking" })

    #expect(natNetworking.status == .unavailable)
    #expect(natNetworking.enabled == false)
    #expect(natNetworking.reason == "Missing virtualization entitlement")
  }

  @Test
  func unsupportedVirtualizationFrameworkReportsUnavailableReason() throws {
    let capabilities = VirtualizationCapabilities(
      probe: VirtualizationHostProbe(
        architecture: "arm64",
        operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0),
        virtualizationSupported: false,
        entitlements: ["com.apple.security.virtualization"]
      )
    )

    let guiDisplay = try #require(capabilities.features.first { $0.id == "guiDisplay" })

    #expect(guiDisplay.status == .unavailable)
    #expect(guiDisplay.enabled == false)
    #expect(guiDisplay.reason == "Virtualization framework is not supported on this host")
  }

  @Test
  func osVersionGateUsesJeballtoMinimumHostOS() throws {
    let capabilities = VirtualizationCapabilities(
      probe: VirtualizationHostProbe(
        architecture: "arm64",
        operatingSystemVersion: OperatingSystemVersion(majorVersion: 25, minorVersion: 6, patchVersion: 0),
        virtualizationSupported: true,
        entitlements: ["com.apple.security.virtualization"]
      )
    )

    let macOSVirtualization = try #require(capabilities.features.first { $0.id == "macOSVirtualization" })

    #expect(macOSVirtualization.status == .unavailable)
    #expect(macOSVirtualization.enabled == false)
    #expect(macOSVirtualization.minimumOS == "26.0")
    #expect(macOSVirtualization.reason == "Requires macOS 26.0 or newer")
  }

  @Test
  func effectiveMinimumOSUsesLaterFeatureAPIFloor() {
    let effectiveMinimumOS = VirtualizationCapabilities.effectiveMinimumOS(
      forFeatureRequiring: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
    )

    #expect(VirtualizationCapabilities.versionString(effectiveMinimumOS) == "27.0")
  }

  private func makeCapabilities(
    featureFlags: VirtualizationFeatureFlags = VirtualizationFeatureFlags()
  ) -> VirtualizationCapabilities {
    VirtualizationCapabilities(
      probe: VirtualizationHostProbe(
        architecture: "arm64",
        operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0),
        virtualizationSupported: true,
        entitlements: ["com.apple.security.virtualization"]
      ),
      featureFlags: featureFlags
    )
  }
}
