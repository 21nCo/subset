#!/usr/bin/env bash
# Fetches the pinned upstream whisper.cpp Apple XCFramework into native/dictate/.build/.
# The XCFramework and any Whisper model files are never committed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DICTATE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

WHISPER_TAG="${WHISPER_TAG:-v1.8.1}"
# SHA-256 of whisper-v1.8.1-xcframework.zip from the upstream GitHub release.
WHISPER_ZIP_SHA256="${WHISPER_ZIP_SHA256:-fc02a7efe6ede7a73c032ee2e67027766e49e3ff8cb35aa8651519ec1ab97cb7}"
FORCE_DOWNLOAD="${FORCE_DOWNLOAD:-0}"

BUILD_DIR="${DICTATE_ROOT}/.build"
WHISPER_FRAMEWORK="${BUILD_DIR}/whisper.xcframework"
WHISPER_XCFRAMEWORK_URL="https://github.com/ggml-org/whisper.cpp/releases/download/${WHISPER_TAG}/whisper-${WHISPER_TAG}-xcframework.zip"
VENDOR_DIR="${DICTATE_ROOT}/whisper/vendor"
MACOS_HEADERS="${WHISPER_FRAMEWORK}/macos-arm64_x86_64/whisper.framework/Versions/A/Headers"
# Records which archive the cached framework came from, so a changed tag or checksum refetches.
WHISPER_MARKER="${BUILD_DIR}/whisper.xcframework.source"
expected_marker="${WHISPER_TAG} ${WHISPER_ZIP_SHA256}"

for tool in curl ditto shasum; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "Missing required tool: ${tool}" >&2
        exit 1
    fi
done

cached_marker="$(cat "${WHISPER_MARKER}" 2>/dev/null || true)"
if [[ "${FORCE_DOWNLOAD}" == "1" || ! -d "${WHISPER_FRAMEWORK}" || "${cached_marker}" != "${expected_marker}" ]]; then
    archive_path="$(mktemp -t whisper-xcframework.XXXXXX)"
    staging="$(mktemp -d -t whisper-xcframework)"
    trap 'rm -rf "${archive_path}" "${staging}"' EXIT

    echo "Downloading whisper.xcframework ${WHISPER_TAG}"
    curl --proto "=https" --proto-redir "=https" --tlsv1.2 -fL --progress-bar "${WHISPER_XCFRAMEWORK_URL}" -o "${archive_path}"

    actual_sha="$(shasum -a 256 "${archive_path}" | awk '{print $1}')"
    if [[ "${actual_sha}" != "${WHISPER_ZIP_SHA256}" ]]; then
        echo "Checksum mismatch for ${WHISPER_XCFRAMEWORK_URL}" >&2
        echo "expected ${WHISPER_ZIP_SHA256}" >&2
        echo "actual   ${actual_sha}" >&2
        exit 1
    fi

    ditto -xk "${archive_path}" "${staging}"
    if [[ ! -d "${staging}/build-apple/whisper.xcframework" ]]; then
        echo "The archive does not contain build-apple/whisper.xcframework; keeping the existing cache." >&2
        exit 1
    fi
    # Replace the cache only after the new framework was extracted successfully.
    mkdir -p "${BUILD_DIR}"
    rm -rf "${WHISPER_FRAMEWORK}" "${WHISPER_MARKER}"
    mv "${staging}/build-apple/whisper.xcframework" "${WHISPER_FRAMEWORK}"
    printf '%s\n' "${expected_marker}" > "${WHISPER_MARKER}"
else
    echo "Reusing existing XCFramework at ${WHISPER_FRAMEWORK}"
fi

if [[ ! -d "${MACOS_HEADERS}" ]]; then
    echo "Expected macOS headers were not found at ${MACOS_HEADERS}" >&2
    exit 1
fi

# The vendored headers are for indexing only; the build uses the framework headers.
for header in whisper.h ggml.h ggml-alloc.h ggml-backend.h ggml-blas.h ggml-cpu.h ggml-metal.h gguf.h; do
    if ! cmp -s "${MACOS_HEADERS}/${header}" "${VENDOR_DIR}/${header}"; then
        echo "Vendored ${header} differs from ${WHISPER_TAG}; updating it."
        cp "${MACOS_HEADERS}/${header}" "${VENDOR_DIR}/${header}"
    fi
done

echo "whisper.cpp setup complete: ${WHISPER_FRAMEWORK}"
