import Foundation
@preconcurrency import Virtualization

/// Compatibility wrapper for creating Apple Virtualization configurations from a VM definition.
final class AVFConfiguration {
  let vmDefinition: VMDefinition

  init(vmDefinition: VMDefinition) {
    self.vmDefinition = vmDefinition
  }

  func createConfiguration() throws -> VZVirtualMachineConfiguration {
    let spec = MacVMConfigurationBuilder().makeRuntimeSpec(for: vmDefinition)
    return try AVFConfigurationAssembler().createConfiguration(from: spec)
  }

  static func saveHardwareModel(_ model: VZMacHardwareModel, to path: String) throws {
    try model.dataRepresentation.write(to: URL(fileURLWithPath: path), options: .atomic)
  }

  static func saveMachineIdentifier(_ identifier: VZMacMachineIdentifier, to path: String) throws {
    try identifier.dataRepresentation.write(to: URL(fileURLWithPath: path), options: .atomic)
  }
}

enum AVFError: Error, LocalizedError {
  case invalidHardwareModel
  case invalidMachineIdentifier
  case invalidMACAddress(String)
  case diskImageNotFound(String)
  case storageAttachmentFailed(String, String)
  case platformIdentityReadFailed(String, String)
  case configurationValidationFailed(Error)
  case missingInstallationRequirements
  case insufficientResources(String)
  case auxiliaryStorageCreationFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidHardwareModel:
      "Invalid hardware model data"
    case .invalidMachineIdentifier:
      "Invalid machine identifier data"
    case .invalidMACAddress(let address):
      "Invalid VM MAC address: \(address)"
    case .diskImageNotFound(let path):
      "Disk image not found at: \(path)"
    case .storageAttachmentFailed(let path, let message):
      "Failed to attach disk image at \(path): \(message)"
    case .platformIdentityReadFailed(let path, let message):
      "Failed to read VM platform identity at \(path): \(message)"
    case .configurationValidationFailed(let error):
      "Configuration validation failed: \(error.localizedDescription)"
    case .missingInstallationRequirements:
      "Installation requirements are required to create an install configuration"
    case .insufficientResources(let message):
      "Insufficient resources: \(message)"
    case .auxiliaryStorageCreationFailed(let message):
      "Failed to create auxiliary storage: \(message)"
    }
  }
}
