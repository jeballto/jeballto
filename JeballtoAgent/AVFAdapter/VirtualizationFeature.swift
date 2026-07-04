import Foundation

/// A runtime capability that Jeballto exposes or depends on.
enum VirtualizationFeature: String, CaseIterable, Codable, Sendable {
  case macOSVirtualization
  case macOSInstallation
  case natNetworking
  case portForwarding
  case guiDisplay
  case screenshotCapture
  case keystrokeInjection
  case saveRestore
  case ociImagePackaging

  var minimumOS: OperatingSystemVersion {
    switch self {
    case .saveRestore:
      OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
    case .macOSInstallation, .guiDisplay, .screenshotCapture, .keystrokeInjection:
      OperatingSystemVersion(majorVersion: 12, minorVersion: 0, patchVersion: 0)
    case .macOSVirtualization, .natNetworking, .portForwarding, .ociImagePackaging:
      OperatingSystemVersion(majorVersion: 11, minorVersion: 0, patchVersion: 0)
    }
  }

  var requiresVirtualizationSupport: Bool {
    switch self {
    case .portForwarding, .ociImagePackaging:
      false
    case .macOSVirtualization, .macOSInstallation, .natNetworking, .guiDisplay,
         .screenshotCapture, .keystrokeInjection, .saveRestore:
      true
    }
  }

  var isEnabledByDefault: Bool {
    true
  }
}

/// Availability state for a Jeballto runtime capability.
enum VirtualizationFeatureStatus: String, Codable, Sendable {
  case available
  case unavailable
}
