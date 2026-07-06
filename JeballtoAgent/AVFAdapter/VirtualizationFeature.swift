import Foundation

/// Deprecation details for a deprecated capability.
struct VirtualizationFeatureDeprecation: Equatable, Sendable {
  let since: String
  let message: String
}

/// Product lifecycle state for a Jeballto runtime capability.
enum VirtualizationFeatureLifecycle: Equatable, Sendable {
  case development
  case stable
  case deprecated(deprecation: VirtualizationFeatureDeprecation)

  var rawValue: String {
    switch self {
    case .development:
      "development"
    case .stable:
      "stable"
    case .deprecated:
      "deprecated"
    }
  }

  var deprecation: VirtualizationFeatureDeprecation? {
    switch self {
    case .development, .stable:
      nil
    case .deprecated(let deprecation):
      deprecation
    }
  }

  var isEnabledByDefault: Bool {
    switch self {
    case .stable:
      true
    case .development, .deprecated:
      false
    }
  }

  var allowsEnablement: Bool {
    switch self {
    case .development, .stable:
      true
    case .deprecated:
      false
    }
  }
}

/// A runtime capability that Jeballto exposes or depends on.
enum VirtualizationFeature: String, CaseIterable, Codable, Sendable {
  case macOSVirtualization
  case macOSInstallation
  case natNetworking
  case portForwarding
  case commandExecution
  case guiDisplay
  case screenshotCapture
  case keystrokeInjection
  case jeballtofileExecution
  case ociImagePackaging

  var minimumOS: OperatingSystemVersion {
    switch self {
    case .macOSInstallation, .guiDisplay, .screenshotCapture, .keystrokeInjection:
      OperatingSystemVersion(majorVersion: 12, minorVersion: 0, patchVersion: 0)
    case .macOSVirtualization, .natNetworking, .portForwarding, .commandExecution,
         .jeballtofileExecution, .ociImagePackaging:
      OperatingSystemVersion(majorVersion: 11, minorVersion: 0, patchVersion: 0)
    }
  }

  var requiresVirtualizationSupport: Bool {
    switch self {
    case .portForwarding, .ociImagePackaging:
      false
    case .macOSVirtualization, .macOSInstallation, .natNetworking, .guiDisplay,
         .screenshotCapture, .keystrokeInjection, .commandExecution, .jeballtofileExecution:
      true
    }
  }

  var lifecycle: VirtualizationFeatureLifecycle {
    .stable
  }

  var isEnabledByDefault: Bool {
    lifecycle.isEnabledByDefault
  }

  static let vmRuntimeRequirements: [VirtualizationFeature] = [
    .macOSVirtualization,
    .natNetworking,
  ]

  static let vmInstallationRequirements: [VirtualizationFeature] = [
    .macOSInstallation,
    .natNetworking,
  ]

  static let commandExecutionRequirements: [VirtualizationFeature] = [
    .commandExecution,
    .portForwarding,
  ]
}

/// Availability state for a Jeballto runtime capability.
enum VirtualizationFeatureStatus: String, Codable, Sendable {
  case available
  case unavailable
}
