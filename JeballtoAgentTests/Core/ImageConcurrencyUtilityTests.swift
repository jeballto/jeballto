import CryptoKit
import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core), .serialized)
struct ImageConcurrencyUtilityTests {
  @Test
  func operationDirectoriesAreStableForSameSessionResumeKey() throws {
    try withTemporaryDirectory(prefix: "image-operation-directories") { root in
      let sessionURL = URL(fileURLWithPath: root, isDirectory: true)
        .appendingPathComponent("ImageWork/sessions/test", isDirectory: true)
      let pullPath = ImageManager.pullOperationDirectory(
        manifestDigest: "sha256:abc/def",
        imageWorkSessionURL: sessionURL
      )
      let samePullPath = ImageManager.pullOperationDirectory(
        manifestDigest: "sha256:abc/def",
        imageWorkSessionURL: sessionURL
      )
      let differentPullPath = ImageManager.pullOperationDirectory(
        manifestDigest: "sha256:xyz",
        imageWorkSessionURL: sessionURL
      )
      let pushPath = ImageManager.pushOperationDirectory(
        sourceFingerprint: "sha256:source",
        imageWorkSessionURL: sessionURL
      )
      let samePushPath = ImageManager.pushOperationDirectory(
        sourceFingerprint: "sha256:source",
        imageWorkSessionURL: sessionURL
      )

      #expect(pullPath == samePullPath)
      #expect(pullPath != differentPullPath)
      #expect(pushPath == samePushPath)
      #expect(pullPath.contains("/sessions/"))
      #expect(pullPath.contains("/operations/pulls/"))
      #expect(pushPath.contains("/operations/pushes/"))
    }
  }

  @Test
  func imageOperationDeadlineCancelsWholeOperation() async {
    let recorder = CancellationRecorder()

    do {
      _ = try await ImageManager.withImageOperationDeadline(
        timeout: 0.05,
        operationName: "test image operation"
      ) {
        do {
          try await Task.sleep(nanoseconds: 5_000_000_000)
        } catch is CancellationError {
          await recorder.markCancelled()
          throw CancellationError()
        }
        return true
      }
      Issue.record("Expected image operation deadline to throw")
    } catch let error as OrasError {
      guard case .timeout(let command) = error else {
        Issue.record("Expected OrasError.timeout, got \(error)")
        return
      }
      #expect(command == "test image operation")
    } catch {
      Issue.record("Expected OrasError.timeout, got \(error)")
    }

    #expect(await recorder.wasCancelled())
  }

  @Test
  func cachedBlobValidationRequiresMatchingSizeAndDigest() throws {
    try withTemporaryDirectory(prefix: "image-manager-blob-cache") { root in
      let payload = Data("cached blob".utf8)
      let path = "\(root)/blob"
      let digest = "sha256:" + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
      try payload.write(to: URL(fileURLWithPath: path))

      #expect(ImageManager.cachedBlobIsValid(path: path, expectedDigest: digest, expectedSize: UInt64(payload.count)))
      #expect(ImageManager.cachedBlobIsValid(path: path, expectedDigest: digest, expectedSize: 1) == false)
      #expect(
        ImageManager.cachedBlobIsValid(
          path: path,
          expectedDigest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
          expectedSize: UInt64(payload.count)
        ) == false
      )
    }
  }

  @Test
  func generatedManifestContainsExpectedDescriptors() throws {
    let config = OrasDescriptor(
      mediaType: jeballtoImageConfigMediaType,
      digest: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
      size: 12
    )
    let layer = OrasDescriptor(
      mediaType: jeballtoImageChunkMediaType,
      digest: "sha256:2222222222222222222222222222222222222222222222222222222222222222",
      size: 34
    )

    let data = try ImageManager.ociImageManifestData(configDescriptor: config, layerDescriptors: [layer])
    let rawManifest = try #require(String(data: data, encoding: .utf8))
    let manifest = try OrasManifestInfo(rawManifest: rawManifest)

    #expect(manifest.artifactType == jeballtoImageArtifactType)
    #expect(manifest.configDescriptor == config)
    #expect(manifest.layers == [layer])
  }

  @Test
  func blobCacheSerializesWorkForSameDigestOnly() async throws {
    let cache = ImageBlobCache()
    let recorder = BlobCacheRecorder()

    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0 ..< 3 {
        group.addTask {
          try await cache.withExclusiveAccess(for: "sha256:same") {
            await recorder.beginSameDigestWork()
            try await Task.sleep(nanoseconds: 20_000_000)
            await recorder.endSameDigestWork()
          }
        }
      }

      try await group.waitForAll()
    }

    #expect(await recorder.maxActiveSameDigestWork() == 1)
  }

  @Test
  func blobCacheCancelsWaitingWork() async throws {
    let cache = ImageBlobCache()
    let holderEntered = AsyncTestSignal()
    let holder = Task {
      try await cache.withExclusiveAccess(for: "sha256:same") {
        await holderEntered.signal()
        try await Task.sleep(nanoseconds: 250_000_000)
      }
    }
    await holderEntered.wait()

    let waiter = Task {
      try await cache.withExclusiveAccess(for: "sha256:same") {
        Issue.record("Cancelled waiter should not run blob work")
      }
    }
    try await Task.sleep(nanoseconds: 20_000_000)

    waiter.cancel()
    await #expect(throws: CancellationError.self) {
      try await waiter.value
    }

    holder.cancel()
    _ = try? await holder.value

    let completed = try await cache.withExclusiveAccess(for: "sha256:same") {
      true
    }
    #expect(completed)
  }

  @Test
  func operationCacheSerializesWorkForSameKey() async throws {
    let cache = KeyedOperationGate()
    let recorder = OperationCacheRecorder()

    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0 ..< 3 {
        group.addTask {
          try await cache.withExclusiveAccess(for: "pull:sha256-same") {
            await recorder.beginSameKeyWork()
            try await Task.sleep(nanoseconds: 20_000_000)
            await recorder.endSameKeyWork()
          }
        }
      }

      try await group.waitForAll()
    }

    #expect(await recorder.maxActiveSameKeyWork() == 1)
  }

  @Test
  func operationCacheCancelsWaitingWork() async throws {
    let cache = KeyedOperationGate()
    let holderEntered = AsyncTestSignal()
    let holder = Task {
      try await cache.withExclusiveAccess(for: "pull:sha256-same") {
        await holderEntered.signal()
        try await Task.sleep(nanoseconds: 250_000_000)
      }
    }
    await holderEntered.wait()

    let waiter = Task {
      try await cache.withExclusiveAccess(for: "pull:sha256-same") {
        Issue.record("Cancelled waiter should not run cached work")
      }
    }
    try await Task.sleep(nanoseconds: 20_000_000)

    waiter.cancel()
    await #expect(throws: CancellationError.self) {
      try await waiter.value
    }

    holder.cancel()
    _ = try? await holder.value

    let completed = try await cache.withExclusiveAccess(for: "pull:sha256-same") {
      true
    }
    #expect(completed)
  }

  @Test
  func concurrencyLimiterCancelsWaitingWork() async throws {
    let limiter = ImageConcurrencyLimiter(limit: 1)
    let holderEntered = AsyncTestSignal()
    let holder = Task {
      try await limiter.withPermit {
        await holderEntered.signal()
        try await Task.sleep(nanoseconds: 250_000_000)
      }
    }
    await holderEntered.wait()

    let waiter = Task {
      try await limiter.withPermit {
        Issue.record("Cancelled waiter should not receive a permit")
      }
    }
    try await Task.sleep(nanoseconds: 20_000_000)

    waiter.cancel()
    await #expect(throws: CancellationError.self) {
      try await waiter.value
    }

    holder.cancel()
    _ = try? await holder.value

    let completed = try await limiter.withPermit {
      true
    }
    #expect(completed)
  }

  @Test
  func concurrencyLimiterUpdatesOneAggregatePoolWithoutForgettingActivePermits() async throws {
    let limiter = ImageConcurrencyLimiter(limit: 1)
    let holderEntered = AsyncTestSignal()
    let releaseHolder = AsyncTestSignal()
    let secondEntered = AsyncTestSignal()

    let holder = Task {
      try await limiter.withPermit {
        await holderEntered.signal()
        await releaseHolder.wait()
      }
    }
    await holderEntered.wait()

    let second = Task {
      try await limiter.withPermit {
        await secondEntered.signal()
      }
    }
    await limiter.updateLimit(2)
    await secondEntered.wait()
    try await second.value

    await limiter.updateLimit(1)
    let thirdEntered = AsyncTestSignal()
    let third = Task {
      try await limiter.withPermit {
        await thirdEntered.signal()
      }
    }
    try await Task.sleep(nanoseconds: 20_000_000)
    #expect(await thirdEntered.hasBeenSignalled() == false)

    await releaseHolder.signal()
    try await holder.value
    await thirdEntered.wait()
    try await third.value
  }
}
