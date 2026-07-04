import Foundation
import Security
@preconcurrency import Virtualization

/// Host facts used to evaluate Jeballto runtime capabilities.
struct VirtualizationHostProbe: Sendable {
  let architecture: String
  let operatingSystemVersion: OperatingSystemVersion
  let virtualizationSupported: Bool
  let entitlements: Set<String>

  static var live: VirtualizationHostProbe {
    VirtualizationHostProbe(
      architecture: RuntimeArchitecture.current,
      operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion,
      virtualizationSupported: VZVirtualMachine.isSupported,
      entitlements: EntitlementProbe.currentEntitlements()
    )
  }
}

/// Internal feature switch input for capability resolution.
struct VirtualizationFeatureFlags: Sendable {
  private let overrides: [VirtualizationFeature: Bool]

  init(overrides: [VirtualizationFeature: Bool] = [:]) {
    self.overrides = overrides
  }

  func enabledOverride(for feature: VirtualizationFeature) -> Bool? {
    overrides[feature]
  }
}

/// Resolved host and feature capabilities for the running app.
struct VirtualizationCapabilities: Sendable {
  static let maxConcurrentVMs = 2

  let host: Host
  let features: [Feature]

  init(probe: VirtualizationHostProbe = .live, featureFlags: VirtualizationFeatureFlags = VirtualizationFeatureFlags()) {
    host = Host(
      architecture: probe.architecture,
      macOSVersion: Self.versionString(probe.operatingSystemVersion),
      virtualizationSupported: probe.virtualizationSupported,
      maxConcurrentVMs: Self.maxConcurrentVMs
    )
    features = VirtualizationFeature.allCases.map { feature in
      Self.resolve(feature, using: probe, featureFlags: featureFlags)
    }
  }

  struct Host: Sendable {
    let architecture: String
    let macOSVersion: String
    let virtualizationSupported: Bool
    let maxConcurrentVMs: Int
  }

  struct Feature: Sendable {
    let id: String
    let status: VirtualizationFeatureStatus
    let enabled: Bool
    let minimumOS: String
    let reason: String?
  }

  private static func resolve(
    _ feature: VirtualizationFeature,
    using probe: VirtualizationHostProbe,
    featureFlags: VirtualizationFeatureFlags
  ) -> Feature {
    let unavailableReason = unavailableReason(for: feature, using: probe)
    let supported = unavailableReason == nil
    let flagEnabled = featureFlags.enabledOverride(for: feature) ?? feature.isEnabledByDefault
    let enabled = supported && flagEnabled
    let reason = unavailableReason ?? (enabled ? nil : "Capability is disabled")

    return Feature(
      id: feature.rawValue,
      status: supported ? .available : .unavailable,
      enabled: enabled,
      minimumOS: versionString(feature.minimumOS),
      reason: reason
    )
  }

  private static func unavailableReason(
    for feature: VirtualizationFeature,
    using probe: VirtualizationHostProbe
  ) -> String? {
    if isVersion(probe.operatingSystemVersion, earlierThan: feature.minimumOS) {
      return "Requires macOS \(versionString(feature.minimumOS)) or newer"
    }

    if feature.requiresVirtualizationSupport {
      guard probe.architecture == "arm64" || probe.architecture == "arm64e" else {
        return "Requires Apple Silicon"
      }
      guard probe.virtualizationSupported else {
        return "Virtualization framework is not supported on this host"
      }
      guard probe.entitlements.contains("com.apple.security.virtualization") else {
        return "Missing virtualization entitlement"
      }
    }

    return nil
  }

  static func versionString(_ version: OperatingSystemVersion) -> String {
    if version.patchVersion > 0 {
      return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
    return "\(version.majorVersion).\(version.minorVersion)"
  }

  private static func isVersion(
    _ version: OperatingSystemVersion,
    earlierThan minimum: OperatingSystemVersion
  ) -> Bool {
    if version.majorVersion != minimum.majorVersion {
      return version.majorVersion < minimum.majorVersion
    }
    if version.minorVersion != minimum.minorVersion {
      return version.minorVersion < minimum.minorVersion
    }
    return version.patchVersion < minimum.patchVersion
  }
}

private enum RuntimeArchitecture {
  static var current: String {
    #if arch(arm64)
      "arm64"
    #elseif arch(x86_64)
      "x86_64"
    #else
      "unknown"
    #endif
  }
}

private enum EntitlementProbe {
  static func currentEntitlements() -> Set<String> {
    [
      "com.apple.security.virtualization",
    ].filter(hasEntitlement).reduce(into: Set<String>()) { result, entitlement in
      result.insert(entitlement)
    }
  }

  private static func hasEntitlement(_ entitlement: String) -> Bool {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil)
    return (value as? Bool) == true
  }
}
