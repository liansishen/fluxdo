#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$ROOT/Harness/Harness.xcodeproj"
SCHEME="Harness"
OUTPUT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fluxdo-share-preview-tests"
mkdir -p "$OUTPUT"
DEVICE="${1:-all}"
case "$DEVICE" in
  all|iPhone|iPad) ;;
  *) echo "设备参数应为 all、iPhone 或 iPad" >&2; exit 64 ;;
esac

DEVICES="$(xcrun simctl list devices available --json)"
pick_device() {
  printf '%s' "$DEVICES" | python3 -c 'import json,re,sys
prefix=sys.argv[1]
runtimes=json.load(sys.stdin)["devices"]
def version(runtime):
    return tuple(map(int,re.findall(r"\d+",runtime.rsplit("iOS-",1)[-1])))
ios_runtimes=sorted((runtime for runtime in runtimes if ".iOS-" in runtime),key=version,reverse=True)
all_devices=[device for runtime in ios_runtimes for device in runtimes[runtime]]
print(next((device["udid"] for device in all_devices if device["name"].startswith(prefix) and device.get("isAvailable",True)),""))' "$1"
}

IPHONE_UDID="${IPHONE_DESTINATION:-$(pick_device 'iPhone')}"
IPAD_UDID="${IPAD_DESTINATION:-$(pick_device 'iPad')}"

if [[ "$DEVICE" != "iPad" && -z "$IPHONE_UDID" ]]; then
  echo "未找到可用 iPhone 模拟器" >&2
  exit 1
fi
if [[ "$DEVICE" != "iPhone" && -z "$IPAD_UDID" ]]; then
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
  xcrun simctl bootstatus "$udid" -b
  local status=0
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "id=${udid}" \
    -parallel-testing-enabled NO \
    -retry-tests-on-failure \
    -test-iterations 3 \
    -derivedDataPath "$OUTPUT/DerivedData-${label}" \
    -resultBundlePath "$result" \
    CODE_SIGNING_ALLOWED=NO \
    test || status=$?
  xcrun simctl shutdown "$udid"
  return "$status"
}

if [[ "$DEVICE" != "iPad" ]]; then run_tests "iPhone" "$IPHONE_UDID"; fi
if [[ "$DEVICE" != "iPhone" ]]; then run_tests "iPad" "$IPAD_UDID"; fi
