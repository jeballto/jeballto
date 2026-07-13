import Foundation
@testable import JeballtoAgent

actor AsyncTestSignal {
  private var isSignalled = false
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func signal() {
    isSignalled = true
    let waitingContinuations = continuations
    continuations.removeAll()
    for continuation in waitingContinuations {
      continuation.resume()
    }
  }

  func wait() async {
    guard isSignalled == false else { return }
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func hasBeenSignalled() -> Bool {
    isSignalled
  }
}

actor BlobCacheRecorder {
  private var activeSameDigestWork = 0
  private var maxActiveSameDigestWorkValue = 0

  func beginSameDigestWork() {
    activeSameDigestWork += 1
    maxActiveSameDigestWorkValue = max(maxActiveSameDigestWorkValue, activeSameDigestWork)
  }

  func endSameDigestWork() {
    activeSameDigestWork -= 1
  }

  func maxActiveSameDigestWork() -> Int {
    maxActiveSameDigestWorkValue
  }
}

actor OperationCacheRecorder {
  private var activeSameKeyWork = 0
  private var maxActiveSameKeyWorkValue = 0

  func beginSameKeyWork() {
    activeSameKeyWork += 1
    maxActiveSameKeyWorkValue = max(maxActiveSameKeyWorkValue, activeSameKeyWork)
  }

  func endSameKeyWork() {
    activeSameKeyWork -= 1
  }

  func maxActiveSameKeyWork() -> Int {
    maxActiveSameKeyWorkValue
  }
}

actor CancellationRecorder {
  private var cancelled = false

  func markCancelled() {
    cancelled = true
  }

  func wasCancelled() -> Bool {
    cancelled
  }
}

actor PackProgressRecorder {
  private var updates: [VMImagePackProgressUpdate] = []

  func append(_ update: VMImagePackProgressUpdate) {
    updates.append(update)
  }

  func all() -> [VMImagePackProgressUpdate] {
    updates
  }
}

actor ImageOperationProgressRecorder {
  private var updates: [ImageOperationProgressUpdate] = []

  func append(_ update: ImageOperationProgressUpdate) {
    updates.append(update)
  }

  func all() -> [ImageOperationProgressUpdate] {
    updates
  }
}

func makeImageManagerFakeZstd(at path: String) throws {
  let script = """
  #!/bin/sh
  output=""
  previous=""
  for argument in "$@"; do
    if [ "$previous" = "-o" ]; then
      output="$argument"
      break
    fi
    previous="$argument"
  done
  if [ -z "$output" ]; then
    exit 1
  fi
  mkdir -p "$(dirname "$output")"
  cat > "$output"
  """
  try script.write(toFile: path, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
}

func makeImageManagerFakePushOras(at path: String) throws {
  let script = """
  #!/bin/sh
  if [ "$1" = "blob" ] && [ "$2" = "fetch" ]; then
    echo "404 not found" >&2
    exit 1
  fi
  if [ "$1" = "blob" ] && [ "$2" = "push" ]; then
    media_type=""
    size=""
    target=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --media-type)
          shift
          media_type="$1"
          ;;
        --size)
          shift
          size="$1"
          ;;
        *@sha256:*)
          target="$1"
          ;;
      esac
      shift
    done
    digest="${target##*@}"
    printf '{"mediaType":"%s","digest":"%s","size":%s}\n' "$media_type" "$digest" "$size"
    exit 0
  fi
  if [ "$1" = "manifest" ] && [ "$2" = "push" ]; then
    manifest=""
    for argument in "$@"; do
      if [ -f "$argument" ]; then
        manifest="$argument"
      fi
    done
    digest="sha256:$(/usr/bin/shasum -a 256 "$manifest" | /usr/bin/awk '{print $1}')"
    size="$(/usr/bin/stat -f %z "$manifest")"
    printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"%s","size":%s}\n' \
      "$digest" "$size"
    exit 0
  fi
  exit 0
  """
  try script.write(toFile: path, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
}
