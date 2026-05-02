#!/bin/bash
# Claude Code post-session hook
# Runs automatically when a Claude Code session ends

set -e

echo "🔍 Running pre-commit checks on all files..."
pre-commit run --all-files || {
  echo "⚠️  Pre-commit checks failed. Please review and fix the issues."
  exit 1
}

echo "✅ All pre-commit checks passed!"

echo "📦 Testing the project..."

xcodebuild test \
  -project JeballtoProject.xcodeproj \
  -scheme JeballtoAgent \
  -destination 'platform=macOS' \
  -only-testing:JeballtoAgentTests || {
    echo "⚠️  Tests failed. Please review the test results and fix the issues."
    exit 1
  }

echo "✅ All tests passed! Session ended successfully."
