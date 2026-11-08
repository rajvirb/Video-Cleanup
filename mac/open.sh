#!/bin/bash
# Makes Sift.xcodeproj from project.yml and opens it in Xcode.
# Needs Xcode, and XcodeGen (installed with Homebrew if it's missing).
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v xcodegen >/dev/null; then
    if ! command -v brew >/dev/null; then
        echo "Please install Homebrew first: https://brew.sh" >&2
        exit 1
    fi
    echo "Installing XcodeGen…"
    brew install xcodegen
fi
xcodegen generate --quiet
open Sift.xcodeproj
