#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$ROOT/Harness/Harness.xcodeproj"
SCHEME="Harness"
OUTPUT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fluxdo-share-preview-tests"
mkdir -p "$OUTPUT"

DEVICES="$(xcrun simctl list devices available --json)"
pick_device() {
  printf '%s' "$DEVICES" | python3 -c 'import json,sys
prefix=sys.argv[1]
all_devices=[device for devices in json.load(sys.stdin)["devices"].values() for device in devices]
print(next((device["udid"] for device in all_devices if device["name"].startswith(prefix) and device.get("isAvailable",True)),""))' "$1"
}

IPHONE_UDID="${IPHONE_DESTINATION:-$(pick_device 'iPhone')}"
IPAD_UDID="${IPAD_DESTINATION:-$(pick_device 'iPad')}"

if [[ -z "$IPHONE_UDID" ]]; then
  echo "未找到可用 iPhone 模拟器" >&2
  exit 1
fi
if [[ -z "$IPAD_UDID" ]]; then
  echo "未找到可用 iPad 模拟器" >&2
  exit 1
fi

run_tests() {
  local label="$1"
  local udid="$2"
  local result="$OUTPUT/${label}.xcresult"
  if [[ -e "$result" ]]; then
    echo "测试结果目录已存在，请另设 RUNNER_TEMP：$result" >&2
    exit 1
  fi
  echo "==> ${label}: ${udid}"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "id=${udid}" \
    -parallel-testing-enabled NO \
    -derivedDataPath "$OUTPUT/DerivedData-${label}" \
    -resultBundlePath "$result" \
    CODE_SIGNING_ALLOWED=NO \
    test
}

run_tests "iPhone" "$IPHONE_UDID"
run_tests "iPad" "$IPAD_UDID"
