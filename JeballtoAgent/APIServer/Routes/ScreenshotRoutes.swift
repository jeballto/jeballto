import Foundation

// MARK: - Screenshot Route Handlers

extension APIServer {
  func handleScreenshot(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }
    if let response = requireCapability(.screenshotCapture) { return response }

    do {
      let pngData = try await vmManager.screenshotVM(vmId)
      return HTTPResponse(
        statusCode: 200,
        headers: [
          "Content-Type": "image/png",
          "Content-Disposition": "inline; filename=\"screenshot-\(vmId.uuidString).png\"",
        ],
        body: pngData
      )
    } catch let error as VMManagerError {
      switch error {
      case .vmNotFound:
        return HTTPResponse.error("NOT_FOUND", message: "VM not found", statusCode: 404)
      case .invalidState:
        return HTTPResponse.error("INVALID_STATE", message: error.localizedDescription, statusCode: 409)
      default:
        return HTTPResponse.error("SCREENSHOT_FAILED", message: error.localizedDescription, statusCode: 500)
      }
    } catch {
      return HTTPResponse.error("SCREENSHOT_FAILED", message: error.localizedDescription, statusCode: 500)
    }
  }
}
