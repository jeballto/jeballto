import Foundation

/// Pure Swift description of the hardware Jeballto wants for a macOS VM.
struct VMConfigurationSpec: Equatable, Sendable {
  var platform: MacPlatformSpec
  var resources: Resources
  var storage: [StorageDevice]
  var network: [NetworkDevice]
  var graphics: [GraphicsDevice]
  var audio: [AudioDevice]
  var pointing: [PointingDevice]
  var keyboards: [KeyboardDevice]
  var validateSaveRestoreSupport: Bool

  struct Resources: Equatable, Sendable {
    var cpuCount: Int
    var memorySize: UInt64
  }

  enum MacPlatformSpec: Equatable, Sendable {
    case existing(PlatformPaths)
    case installation(PlatformPaths)
  }

  struct PlatformPaths: Equatable, Sendable {
    var auxiliaryStoragePath: String
    var hardwareModelPath: String
    var machineIdentifierPath: String
  }

  struct StorageDevice: Equatable, Sendable {
    var path: String
    var readOnly: Bool
    var controller: StorageController
  }

  enum StorageController: Equatable, Sendable {
    case virtioBlock
  }

  struct NetworkDevice: Equatable, Sendable {
    var macAddress: String
    var attachment: NetworkAttachment
  }

  enum NetworkAttachment: Equatable, Sendable {
    case nat
  }

  struct GraphicsDevice: Equatable, Sendable {
    var displays: [Display]
  }

  struct Display: Equatable, Sendable {
    var widthInPixels: Int
    var heightInPixels: Int
    var pixelsPerInch: Int
  }

  struct AudioDevice: Equatable, Sendable {
    var inputEnabled: Bool
    var outputEnabled: Bool
  }

  enum PointingDevice: Equatable, Sendable {
    case macTrackpad
    case usbScreenCoordinate
  }

  enum KeyboardDevice: Equatable, Sendable {
    case macKeyboard
    case usbKeyboard
  }
}
