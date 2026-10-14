#!/bin/bash
# Used by contributors and CI to catch accidental changes to the SDK's resolved package contract.
set -euo pipefail

cd "$(dirname "$0")/.."

# Check the resolved manifest, rather than matching formatting in Package.swift.
swift package dump-package | jq -e '
  .name == "Skyra" and
  .toolsVersion._version == "5.9.0" and
  .swiftLanguageVersions == ["5"] and
  .platforms == [{"options": [], "platformName": "ios", "version": "15.0"},
                 {"options": [], "platformName": "macos", "version": "10.15"}] and
  .dependencies == [] and
  (.products | map({name, targets, type})) ==
    [{"name": "Skyra", "targets": ["Skyra"], "type": {"library": ["automatic"]}}] and
  (.targets | length == 2) and
  (.targets[] | select(.name == "Skyra") |
    .type == "regular" and .dependencies == [] and
    .resources == [{"path": "PrivacyInfo.xcprivacy", "rule": {"copy": {}}}]) and
  (.targets[] | select(.name == "SkyraTests") |
    .type == "test" and .dependencies == [{"byName": ["Skyra", null]}])
'
