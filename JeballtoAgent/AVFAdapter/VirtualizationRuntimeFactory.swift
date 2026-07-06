import Foundation
@preconcurrency import Virtualization

struct VirtualizationRuntime {
  let virtualMachine: VZVirtualMachine
  let delegate: AVFDelegate
}

/// Creates Virtualization framework runtime objects for Jeballto VMs.
struct VirtualizationRuntimeFactory {
  @MainActor
  func makeRuntime(
    configuration: VZVirtualMachineConfiguration,
    vmId: UUID,
    eventBus: EventBus
  ) -> VirtualizationRuntime {
    let virtualMachine = VZVirtualMachine(configuration: configuration)
    let delegate = AVFDelegate(vmId: vmId, eventBus: eventBus)
    virtualMachine.delegate = delegate
    return VirtualizationRuntime(virtualMachine: virtualMachine, delegate: delegate)
  }
}
