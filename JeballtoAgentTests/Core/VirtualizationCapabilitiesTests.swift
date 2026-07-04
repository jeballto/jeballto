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
    #expect(capabilities.features.map(\.enabled).allSatisfy { $0 })
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
    let imagePackaging = try #require(capabilities.features.first { $0.id == "ociImagePackaging" })

    #expect(macOSVirtualization.status == .unavailable)
    #expect(macOSVirtualization.enabled == false)
    #expect(macOSVirtualization.reason == "Requires Apple Silicon")
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
  func osVersionGateReportsMinimumVersion() throws {
    let capabilities = VirtualizationCapabilities(
      probe: VirtualizationHostProbe(
        architecture: "arm64",
        operatingSystemVersion: OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 0),
        virtualizationSupported: true,
        entitlements: ["com.apple.security.virtualization"]
      )
    )

    let saveRestore = try #require(capabilities.features.first { $0.id == "saveRestore" })

    #expect(saveRestore.status == .unavailable)
    #expect(saveRestore.enabled == false)
    #expect(saveRestore.minimumOS == "14.0")
    #expect(saveRestore.reason == "Requires macOS 14.0 or newer")
  }
}
