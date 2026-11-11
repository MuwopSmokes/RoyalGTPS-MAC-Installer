#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
xcrun swiftc -swift-version 5 Sources/Hosts.swift Tests/HostsTests.swift -o "$work/hosts-tests"
"$work/hosts-tests"
