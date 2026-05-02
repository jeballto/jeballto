import Foundation
import Virtualization

/// Delegate implementation for VZVirtualMachine that integrates with the EventBus
/// See: https://developer.apple.com/documentation/virtualization/vzvirtualmachinedelegate
class AVFDelegate: NSObject, VZVirtualMachineDelegate {
  /// VM identifier for event correlation
  let vmId: UUID

  /// Event bus for publishing VM events
  let eventBus: EventBus

  /// Optional error handler callback
  var onError: ((Error) -> Void)?

  /// Optional stop handler callback
  var onStop: (() -> Void)?

  init(vmId: UUID, eventBus: EventBus) {
    self.vmId = vmId
    self.eventBus = eventBus
    super.init()
  }

  // MARK: - VZVirtualMachineDelegate Methods

  /// Called when the virtual machine stops with an error
  /// See: https://developer.apple.com/documentation/virtualization/vzvirtualmachinedelegate/3656740-virtualmachine
  func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
    let errorMessage = "Virtual machine \(vmId.uuidString) stopped with error: \(error.localizedDescription)"
    logError(errorMessage, category: "AVF")

    eventBus.publish(.errorOccurred(vmId: vmId, error: error.localizedDescription))

    onError?(error)
  }

  /// Called when the guest operating system stops the virtual machine
  /// See: https://developer.apple.com/documentation/virtualization/vzvirtualmachinedelegate/3656739-guestdidstop
  func guestDidStop(_ virtualMachine: VZVirtualMachine) {
    logInfo("=== AVFDelegate: Guest OS stopped VM \(vmId.uuidString) ===", category: "AVF")
    logInfo("VZVirtualMachine state in guestDidStop: \(virtualMachine.state.rawValue)", category: "AVF")

    onStop?()
  }

  /// Called when the network devices' configuration changes
  /// See: https://developer.apple.com/documentation/virtualization/vzvirtualmachinedelegate/4175364-virtualmachine
  func virtualMachine(
    _ virtualMachine: VZVirtualMachine,
    networkDevice: VZNetworkDevice,
    attachmentWasDisconnectedWithError error: Error
  ) {
    let errorMessage = "Network device disconnected for VM \(vmId.uuidString): \(error.localizedDescription)"
    logWarning(errorMessage, category: "AVF")

    // Publish error event for network issue
    eventBus.publish(
      .errorOccurred(vmId: vmId, error: "Network attachment disconnected: \(error.localizedDescription)")
    )
  }
}
