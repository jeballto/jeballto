import Foundation

struct SystemCapabilitiesResponse: Codable {
  let host: HostCapabilitiesResponse
  let features: [FeatureCapabilityResponse]

  init(capabilities: VirtualizationCapabilities = VirtualizationCapabilities()) {
    host = HostCapabilitiesResponse(capabilities.host)
    features = capabilities.features.map(FeatureCapabilityResponse.init)
  }
}

struct HostCapabilitiesResponse: Codable {
  let architecture: String
  let macOSVersion: String
  let virtualizationSupported: Bool
  let maxConcurrentVMs: Int

  init(_ host: VirtualizationCapabilities.Host) {
    architecture = host.architecture
    macOSVersion = host.macOSVersion
    virtualizationSupported = host.virtualizationSupported
    maxConcurrentVMs = host.maxConcurrentVMs
  }
}

struct FeatureCapabilityResponse: Codable {
  let id: String
  let status: String
  let enabled: Bool
  let lifecycle: String
  let minimumOS: String
  let deprecation: FeatureDeprecationResponse?
  let reason: String?

  init(_ feature: VirtualizationCapabilities.Feature) {
    id = feature.id
    status = feature.status.rawValue
    enabled = feature.enabled
    lifecycle = feature.lifecycle.rawValue
    minimumOS = feature.minimumOS
    deprecation = feature.deprecation.map(FeatureDeprecationResponse.init)
    reason = feature.reason
  }
}

struct FeatureDeprecationResponse: Codable {
  let since: String
  let message: String

  init(_ deprecation: VirtualizationFeatureDeprecation) {
    since = deprecation.since
    message = deprecation.message
  }
}
