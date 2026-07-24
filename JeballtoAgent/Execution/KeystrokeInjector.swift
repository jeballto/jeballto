import Cocoa
import Virtualization

enum KeystrokeInjectorError: Error, LocalizedError {
  case noVirtualMachine(UUID)
  case eventCreationFailed

  var errorDescription: String? {
    switch self {
    case .noVirtualMachine(let id): "No virtual machine available for VM \(id.uuidString)"
    case .eventCreationFailed: "Failed to create synthetic keyboard event"
    }
  }
}

struct KeystrokeModifierRelease: Equatable {
  let keyCode: UInt16
  let remainingFlags: NSEvent.ModifierFlags
}

struct KeystrokeModifierState {
  private var flagsByKeyCode: [UInt16: NSEvent.ModifierFlags] = [:]
  private var activationOrder: [UInt16] = []

  var flags: NSEvent.ModifierFlags {
    flagsByKeyCode.values.reduce(into: []) { result, flags in
      result.formUnion(flags)
    }
  }

  mutating func apply(flags: NSEvent.ModifierFlags, keyCode: UInt16, keyDown: Bool) {
    if keyDown {
      if flagsByKeyCode[keyCode] == nil {
        activationOrder.append(keyCode)
      }
      flagsByKeyCode[keyCode] = flags
    } else {
      flagsByKeyCode.removeValue(forKey: keyCode)
      activationOrder.removeAll { $0 == keyCode }
    }
  }

  mutating func takeReleaseEvents() -> [KeystrokeModifierRelease] {
    var releases: [KeystrokeModifierRelease] = []
    for keyCode in activationOrder.reversed() {
      flagsByKeyCode.removeValue(forKey: keyCode)
      releases.append(KeystrokeModifierRelease(keyCode: keyCode, remainingFlags: flags))
    }
    activationOrder.removeAll()
    return releases
  }
}

final class KeystrokeInjector {
  private let delayBetweenKeys: TimeInterval = 0.075

  @MainActor func execute(
    actions: [KeystrokeAction],
    vm: VZVirtualMachine,
    vmId: UUID,
    guiManager: GUIManager
  ) async throws -> Int {
    let vmView = guiManager.acquireKeystrokeView(vmId: vmId, virtualMachine: vm)
    defer { guiManager.releaseKeystrokeView(vmId: vmId) }

    var modifierState = KeystrokeModifierState()
    var count = 0

    defer {
      for release in modifierState.takeReleaseEvents() {
        try? sendFlagsChanged(
          modifiers: release.remainingFlags,
          keyCode: release.keyCode,
          view: vmView
        )
      }
    }

    for action in actions {
      switch action {
      case .keyPress(let keyCode, let characters):
        try sendKeyPress(keyCode: keyCode, characters: characters, modifiers: modifierState.flags, view: vmView)
        count += 1
        try await Task.sleep(nanoseconds: UInt64(delayBetweenKeys * 1_000_000_000))

      case .modifierChange(let flags, let keyCode, let keyDown):
        var proposedState = modifierState
        proposedState.apply(flags: flags, keyCode: keyCode, keyDown: keyDown)
        try sendFlagsChanged(modifiers: proposedState.flags, keyCode: keyCode, view: vmView)
        modifierState = proposedState
        count += 1
        try await Task.sleep(nanoseconds: UInt64(delayBetweenKeys * 1_000_000_000))

      case .wait(let duration):
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
      }
    }

    return count
  }

  // MARK: - Private

  @MainActor private func sendKeyPress(
    keyCode: UInt16,
    characters: String,
    modifiers: NSEvent.ModifierFlags,
    view: VZVirtualMachineView
  ) throws {
    let charsIgnoringModifiers = characters.lowercased()

    guard let keyDown = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: view.window?.windowNumber ?? 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: charsIgnoringModifiers,
      isARepeat: false,
      keyCode: keyCode
    ) else { throw KeystrokeInjectorError.eventCreationFailed }

    guard let keyUp = NSEvent.keyEvent(
      with: .keyUp,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: view.window?.windowNumber ?? 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: charsIgnoringModifiers,
      isARepeat: false,
      keyCode: keyCode
    ) else { throw KeystrokeInjectorError.eventCreationFailed }

    view.keyDown(with: keyDown)
    view.keyUp(with: keyUp)
  }

  @MainActor private func sendFlagsChanged(
    modifiers: NSEvent.ModifierFlags,
    keyCode: UInt16,
    view: VZVirtualMachineView
  ) throws {
    guard let event = NSEvent.keyEvent(
      with: .flagsChanged,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: view.window?.windowNumber ?? 0,
      context: nil,
      characters: "",
      charactersIgnoringModifiers: "",
      isARepeat: false,
      keyCode: keyCode
    ) else { throw KeystrokeInjectorError.eventCreationFailed }

    view.flagsChanged(with: event)
  }
}
