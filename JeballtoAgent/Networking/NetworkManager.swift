import Foundation

/// Manages network configuration for VMs
actor NetworkManager {
  /// Event bus for publishing network events
  let eventBus: EventBus

  /// Registry of MAC addresses to prevent collisions
  private var allocatedMACAddresses: Set<String> = []

  init(eventBus: EventBus) { self.eventBus = eventBus }

  // MARK: - MAC Address Management

  /// Generates a unique MAC address that hasn't been allocated
  /// See: https://developer.apple.com/documentation/virtualization/vzmacaddress
  func generateUniqueMACAddress() -> String {
    var macAddress: String

    // Keep generating until we get a unique one
    repeat {
      macAddress = VMNetwork.generateMACAddress()
    } while allocatedMACAddresses.contains(macAddress)

    // Register it
    allocatedMACAddresses.insert(macAddress)

    logInfo("Generated unique MAC address: \(macAddress)", category: "NetworkManager")
    return macAddress
  }

  /// Registers an existing MAC address (when loading persisted VMs)
  func registerMACAddress(_ macAddress: String) {
    let normalized = macAddress.lowercased()
    allocatedMACAddresses.insert(normalized)
    logDebug("Registered MAC address: \(normalized)", category: "NetworkManager")
  }

  /// Releases a MAC address when a VM is deleted
  func releaseMACAddress(_ macAddress: String) {
    let normalized = macAddress.lowercased()
    allocatedMACAddresses.remove(normalized)
    logDebug("Released MAC address: \(normalized)", category: "NetworkManager")
  }

  /// Checks if a MAC address is already allocated
  func isMACAddressAllocated(_ macAddress: String) -> Bool {
    allocatedMACAddresses.contains(macAddress.lowercased())
  }

  // MARK: - NAT IP Resolution

  /// Resolves a VM's NAT IP address by looking up its MAC address in the ARP table.
  /// Retries with adaptive delays since ARP entries may not appear immediately after VM boot.
  /// Early attempts use short delays to catch fast cases; later attempts back off to reduce CPU overhead.
  func resolveNATIP(
    macAddress: String,
    maxAttempts: Int = 20,
    logFailure: Bool = true
  ) async -> String? {
    guard maxAttempts > 0 else {
      if logFailure {
        logWarning("NAT IP resolution requires at least one attempt", category: "NetworkManager")
      }
      return nil
    }
    let normalizedMAC = macAddress.lowercased()

    for attempt in 1 ... maxAttempts {
      if Task.isCancelled { return nil }
      if let ip = await lookupARPTable(macAddress: normalizedMAC) {
        logInfo("Resolved NAT IP \(ip) for MAC \(normalizedMAC) (attempt \(attempt))", category: "NetworkManager")
        return ip
      }
      if attempt < maxAttempts {
        logDebug(
          "ARP lookup attempt \(attempt)/\(maxAttempts) for MAC \(normalizedMAC), no match, retrying",
          category: "NetworkManager"
        )
        // Adaptive delay: aggressive early on (ARP entry typically appears within 1-2s),
        // then back off to reduce overhead for slow cases.
        let adaptiveDelay: TimeInterval = switch attempt {
        case ..<3: 0.5
        case ..<8: 2.0
        default: 5.0
        }
        do {
          try await Task.sleep(nanoseconds: UInt64(adaptiveDelay * 1_000_000_000))
        } catch {
          return nil
        }
      }
    }

    if logFailure {
      logWarning(
        "Failed to resolve NAT IP for MAC \(normalizedMAC) after \(maxAttempts) attempts",
        category: "NetworkManager"
      )
    }
    return nil
  }

  /// Normalizes a MAC address by stripping leading zeros from each octet
  /// so it matches the format used by macOS `arp` output.
  /// e.g. "72:8e:44:0c:42:dc" -> "72:8e:44:c:42:dc"
  private func normalizeMAC(_ mac: String) -> String {
    mac.split(separator: ":").map { octet in
      let stripped = String(octet.drop(while: { $0 == "0" }))
      return stripped.isEmpty ? "0" : stripped
    }.joined(separator: ":")
  }

  /// Parses the system ARP table to find an IP for the given MAC address
  private func lookupARPTable(macAddress: String) async -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
    process.arguments = ["-a", "-n"]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.standardInput = FileHandle.nullDevice

    do {
      let result = try await AsyncProcessRunner.run(
        process: process,
        stdoutPipe: stdoutPipe,
        stderrPipe: stderrPipe,
        options: AsyncProcessRunnerOptions(
          timeout: 5,
          timeoutDescription: "ARP table lookup",
          maxOutputSize: 1024 * 1024
        )
      )
      guard result.exitCode == 0 else {
        logWarning("arp exited with status \(result.exitCode)", category: "NetworkManager")
        return nil
      }
      guard let output = String(data: result.stdout, encoding: .utf8) else { return nil }
      return parseARPOutput(output, normalizedTarget: normalizeMAC(macAddress))
    } catch is CancellationError {
      return nil
    } catch {
      logError("Failed to run arp: \(error)", category: "NetworkManager")
      return nil
    }
  }

  private func parseARPOutput(_ output: String, normalizedTarget: String) -> String? {
    // macOS arp strips leading zeros from MAC octets (e.g. 0c -> c),
    // so normalize both sides before comparing.
    // ARP output format: ? (192.168.64.2) at aa:bb:cc:dd:ee:ff on bridge100 ...
    for line in output.components(separatedBy: "\n") {
      let fields = line.lowercased().split(separator: " ").map(String.init)
      guard let atIndex = fields.firstIndex(of: "at"),
            atIndex + 1 < fields.count,
            normalizeMAC(fields[atIndex + 1]) == normalizedTarget else { continue }

      // Extract IP between parentheses
      if let openParen = line.firstIndex(of: "("),
         let closeParen = line.firstIndex(of: ")"),
         openParen < closeParen
      {
        let ipStart = line.index(after: openParen)
        let ip = String(line[ipStart ..< closeParen])
        if !ip.isEmpty { return ip }
      }
    }

    return nil
  }

  // MARK: - Statistics

  /// Returns the number of allocated MAC addresses
  var allocatedMACCount: Int { allocatedMACAddresses.count }

  /// Returns all allocated MAC addresses
  func getAllocatedMACAddresses() -> [String] { Array(allocatedMACAddresses) }
}
