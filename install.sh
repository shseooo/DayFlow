#!/usr/bin/env bash
#
# DayFlow 로컬 설치 스크립트
# Release 구성으로 빌드 후 /Applications에 설치한다.
#
# 사용:
#   ./install.sh           # 빌드 + 설치 + 실행
#   ./install.sh --no-run  # 빌드 + 설치만 (실행 안 함)
#   ./install.sh --clean   # 빌드 폴더 정리 후 새로 빌드
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="${SCRIPT_DIR}/DayFlow.xcodeproj"
SCHEME="DayFlow"
CONFIG="Release"
BUILD_DIR="${SCRIPT_DIR}/build"
APP_NAME="DayFlow.app"
DEST="/Applications/${APP_NAME}"
BUNDLE_ID="com.dayflow.app"

# 옵션 파싱
RUN_AFTER=1
CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --no-run) RUN_AFTER=0 ;;
        --clean)  CLEAN=1 ;;
        -h|--help)
            echo "Usage: $0 [--no-run] [--clean]"
            exit 0 ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 1 ;;
    esac
done

# Xcode 경로 확인 (Command Line Tools만 깔린 경우 대비)
if [[ ! -d /Applications/Xcode.app ]]; then
    echo "❌ /Applications/Xcode.app이 없습니다. App Store에서 Xcode 설치 후 다시 실행하세요." >&2
    exit 1
fi
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
XCODEBUILD="${DEVELOPER_DIR}/usr/bin/xcodebuild"

# 1. 빌드 폴더 정리 (옵션)
if [[ $CLEAN -eq 1 ]]; then
    echo "🧹 빌드 폴더 정리 중..."
    rm -rf "${BUILD_DIR}"
fi

# 2. 실행 중인 인스턴스 종료 (tccutil reset 적용을 위해 빌드 전에 수행)
if pgrep -x DayFlow >/dev/null; then
    echo "🛑 실행 중인 DayFlow 종료..."
    killall DayFlow || true
    sleep 1
fi

# 3. 권한 초기화 (빌드 전 — tccutil은 앱이 종료된 상태에서만 안정적으로 동작)
echo "🔐 권한 초기화 (Accessibility + Full Disk + Calendar)..."
tccutil reset Accessibility "${BUNDLE_ID}" 2>/dev/null || true
tccutil reset SystemPolicyAllFiles "${BUNDLE_ID}" 2>/dev/null || true
tccutil reset Calendar "${BUNDLE_ID}" 2>/dev/null || true

# 4. SPM 의존성 해결 (.xcodeproj에 등록된 패키지를 fetch/resolve)
echo "📦 SPM 패키지 resolve 중..."
"${XCODEBUILD}" \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -derivedDataPath "${BUILD_DIR}" \
    -resolvePackageDependencies \
    2>&1 | tail -5 || true

# 5. Release 빌드
echo "🔨 ${CONFIG} 빌드 중..."
"${XCODEBUILD}" \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIG}" \
    -derivedDataPath "${BUILD_DIR}" \
    -destination 'platform=macOS' \
    build \
    | grep -E "(error:|warning:|BUILD)" || true

# 6. 빌드 산출물 경로 확인
BUILT_APP="${BUILD_DIR}/Build/Products/${CONFIG}/${APP_NAME}"
if [[ ! -d "${BUILT_APP}" ]]; then
    echo "❌ 빌드 산출물을 찾을 수 없습니다: ${BUILT_APP}" >&2
    exit 1
fi

# 7. /Applications에 복사
echo "📦 ${DEST} 로 설치..."
rm -rf "${DEST}"
cp -R "${BUILT_APP}" "${DEST}"

# 8. quarantine 속성 제거 (Gatekeeper 일회성 경고 회피)
xattr -dr com.apple.quarantine "${DEST}" 2>/dev/null || true

echo "✅ 설치 완료: ${DEST}"

# 9. 실행
if [[ $RUN_AFTER -eq 1 ]]; then
    echo "🚀 실행 중..."
    open "${DEST}"
fi

echo ""
echo "📌 참고사항:"
echo "  • 권한(접근성/전체 디스크/캘린더)이 초기화되었습니다 — 첫 실행 시 다시 허용해야 합니다."
echo "  • 자동 시작은 설정에서 OFF → ON으로 재등록하세요 (경로 변경 반영)."
