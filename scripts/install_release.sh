#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_NAME="Quotio"
BUILD_DIR="${PROJECT_DIR}/build"
DERIVED_DATA="${BUILD_DIR}/ReleaseDerivedData"
APP_PATH="${DERIVED_DATA}/Build/Products/Release/${PROJECT_NAME}.app"
INSTALL_PATH="/Applications/${PROJECT_NAME}.app"
LOG_FILE="${BUILD_DIR}/release-build.log"

case "${1:-}" in
    "") ;;
    -h|--help)
        echo "Usage: $0"
        echo ""
        echo "Build Release, replace ${INSTALL_PATH}, relaunch it, and make sure it starts at login."
        exit 0
        ;;
    *)
        echo "Usage: $0" >&2
        exit 1
        ;;
esac

mkdir -p "${BUILD_DIR}"

echo "==> Building ${PROJECT_NAME} (Release); log: ${LOG_FILE}"
if ! xcodebuild \
    -project "${PROJECT_DIR}/${PROJECT_NAME}.xcodeproj" \
    -scheme "${PROJECT_NAME}" \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath "${DERIVED_DATA}" \
    build >"${LOG_FILE}" 2>&1; then
    grep -E 'error:' "${LOG_FILE}" >&2 || tail -20 "${LOG_FILE}" >&2
    echo "error: Release build failed" >&2
    exit 1
fi

if [ ! -d "${APP_PATH}" ]; then
    echo "error: built app not found at ${APP_PATH}" >&2
    exit 1
fi

echo "==> Stopping any running ${PROJECT_NAME} process"
osascript -e "tell application \"${PROJECT_NAME}\" to quit" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do
    pgrep -x "${PROJECT_NAME}" >/dev/null || break
    sleep 1
done
pkill -x "${PROJECT_NAME}" 2>/dev/null || true

echo "==> Installing to ${INSTALL_PATH}"
rm -rf "${INSTALL_PATH}"
ditto "${APP_PATH}" "${INSTALL_PATH}"

if ! osascript -e 'tell application "System Events" to get the path of every login item' | grep -qF "${INSTALL_PATH}"; then
    echo "==> Adding login item"
    osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"${INSTALL_PATH}\", hidden:true}" >/dev/null
fi

/usr/bin/open "${INSTALL_PATH}"
sleep 2
if ! pgrep -x "${PROJECT_NAME}" >/dev/null; then
    echo "error: ${PROJECT_NAME} did not start" >&2
    exit 1
fi
echo "==> ${PROJECT_NAME} installed, running, and set to launch at login"
