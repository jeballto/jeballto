import Darwin
import Foundation

func freeLocalTCPPort() throws -> UInt16 {
  let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
  guard socketDescriptor >= 0 else {
    throw POSIXError(.init(rawValue: errno) ?? .EIO)
  }
  defer { close(socketDescriptor) }

  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = 0
  address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

  let bindResult = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
      Darwin.bind(socketDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard bindResult == 0 else {
    throw POSIXError(.init(rawValue: errno) ?? .EIO)
  }

  var boundAddress = sockaddr_in()
  var length = socklen_t(MemoryLayout<sockaddr_in>.size)
  let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
      getsockname(socketDescriptor, sockaddrPointer, &length)
    }
  }
  guard nameResult == 0 else {
    throw POSIXError(.init(rawValue: errno) ?? .EIO)
  }

  return UInt16(bigEndian: boundAddress.sin_port)
}
