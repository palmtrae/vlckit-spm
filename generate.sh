#!/bin/bash

set -euo pipefail

readonly DEFAULT_VIDEOLAN_BASE_URL="https://download.videolan.org/cocoapods/prod"
readonly VIDEOLAN_BASE_URL="${VIDEOLAN_BASE_URL:-$DEFAULT_VIDEOLAN_BASE_URL}"
readonly BINARY_TARGET_NAME="VLCKit-all"
readonly RELEASE_ARCHIVE_NAME="${BINARY_TARGET_NAME}.xcframework.zip"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WORK_DIR="${SCRIPT_DIR}/.tmp"

usage() {
    cat <<EOF
Usage: ./generate.sh <vlckit-tag>

Example:
  ./generate.sh 3.7.3

The script discovers the matching MobileVLCKit, TVVLCKit, and VLCKit
archives from VideoLAN, then updates Package.swift for this Git fork.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

[[ $# -eq 1 ]] || {
    usage >&2
    exit 2
}

readonly TAG_VERSION="$1"
[[ "$TAG_VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || \
    die "invalid VLCKit tag: $TAG_VERSION"

for required_command in curl tar find sort xcodebuild ditto swift sed git; do
    require_command "$required_command"
done

cd "$SCRIPT_DIR"
[[ "$WORK_DIR" == "$SCRIPT_DIR/.tmp" ]] || die "refusing to use unexpected work directory"

printf 'Fetching VideoLAN artifact index...\n'
ARTIFACT_INDEX="$({
    curl --fail --silent --show-error --location --retry 3 \
        "${VIDEOLAN_BASE_URL}/"
})"
readonly ARTIFACT_INDEX

artifact_names=()
while IFS= read -r artifact_name; do
    [[ -n "$artifact_name" ]] && artifact_names+=("$artifact_name")
done < <(
    printf '%s\n' "$ARTIFACT_INDEX" |
        sed -n 's/.*href="\([^"]*\.tar\.xz\)".*/\1/p'
)

[[ ${#artifact_names[@]} -gt 0 ]] || \
    die "no .tar.xz artifacts found at $VIDEOLAN_BASE_URL"

discover_artifact() {
    local product_name="$1"
    local artifact_name
    local -a matches=()

    for artifact_name in "${artifact_names[@]}"; do
        if [[ "$artifact_name" == "${product_name}-${TAG_VERSION}-"*.tar.xz ]]; then
            matches+=("$artifact_name")
        fi
    done

    if [[ ${#matches[@]} -ne 1 ]]; then
        printf 'error: expected one %s %s artifact, found %d\n' \
            "$product_name" "$TAG_VERSION" "${#matches[@]}" >&2
        if [[ ${#matches[@]} -gt 0 ]]; then
            printf '  %s\n' "${matches[@]}" >&2
        fi
        return 1
    fi

    printf '%s\n' "${matches[0]}"
}

IOS_ARTIFACT="$(discover_artifact MobileVLCKit)"
TVOS_ARTIFACT="$(discover_artifact TVVLCKit)"
MACOS_ARTIFACT="$(discover_artifact VLCKit)"
readonly IOS_ARTIFACT TVOS_ARTIFACT MACOS_ARTIFACT

rm -rf -- "$WORK_DIR"
mkdir -p "$WORK_DIR"

download_and_extract() {
    local product_name="$1"
    local artifact_name="$2"
    local archive_path="${WORK_DIR}/${product_name}.tar.xz"
    local artifact_url="${VIDEOLAN_BASE_URL}/${artifact_name}"

    printf 'Downloading %s\n' "$artifact_name"
    curl --fail --location --retry 3 --output "$archive_path" "$artifact_url"
    tar -xf "$archive_path" -C "$WORK_DIR"
}

download_and_extract MobileVLCKit "$IOS_ARTIFACT"
download_and_extract TVVLCKit "$TVOS_ARTIFACT"
download_and_extract VLCKit "$MACOS_ARTIFACT"

discover_xcframework() {
    local framework_name="$1"
    local candidate
    local -a matches=()

    while IFS= read -r candidate; do
        matches+=("$candidate")
    done < <(
        find "$WORK_DIR" -type d -name "${framework_name}.xcframework" \
            -prune -print | sort
    )

    if [[ ${#matches[@]} -ne 1 ]]; then
        printf 'error: expected one extracted %s.xcframework, found %d\n' \
            "$framework_name" "${#matches[@]}" >&2
        return 1
    fi

    printf '%s\n' "${matches[0]}"
}

IOS_XCFRAMEWORK="$(discover_xcframework MobileVLCKit)"
TVOS_XCFRAMEWORK="$(discover_xcframework TVVLCKit)"
MACOS_XCFRAMEWORK="$(discover_xcframework VLCKit)"
readonly IOS_XCFRAMEWORK TVOS_XCFRAMEWORK MACOS_XCFRAMEWORK

framework_arguments=()

add_framework_slices() {
    local framework_name="$1"
    local xcframework_path="$2"
    local framework_path
    local slice_directory
    local debug_symbols_path
    local -a framework_paths=()

    while IFS= read -r framework_path; do
        framework_paths+=("$framework_path")
    done < <(
        find "$xcframework_path" -mindepth 2 -maxdepth 2 -type d \
            -name "${framework_name}.framework" -print | sort
    )

    [[ ${#framework_paths[@]} -gt 0 ]] || \
        die "no framework slices found in $xcframework_path"

    for framework_path in "${framework_paths[@]}"; do
        slice_directory="$(dirname "$framework_path")"
        debug_symbols_path="${slice_directory}/dSYMs/${framework_name}.framework.dSYM"
        [[ -d "$debug_symbols_path" ]] || \
            die "missing dSYM for framework slice: $framework_path"
        framework_arguments+=(
            -framework "$framework_path"
            -debug-symbols "$debug_symbols_path"
        )
    done
}

add_framework_slices VLCKit "$MACOS_XCFRAMEWORK"
add_framework_slices TVVLCKit "$TVOS_XCFRAMEWORK"
add_framework_slices MobileVLCKit "$IOS_XCFRAMEWORK"

readonly OUTPUT_XCFRAMEWORK="${WORK_DIR}/${BINARY_TARGET_NAME}.xcframework"
readonly OUTPUT_ARCHIVE="${WORK_DIR}/${RELEASE_ARCHIVE_NAME}"

printf 'Creating combined XCFramework...\n'
xcodebuild -create-xcframework \
    "${framework_arguments[@]}" \
    -output "$OUTPUT_XCFRAMEWORK"

ditto -c -k --sequesterRsrc --keepParent "$OUTPUT_XCFRAMEWORK" "$OUTPUT_ARCHIVE"

discover_repository_slug() {
    local repository_slug="${GITHUB_REPOSITORY:-}"
    local remote_url

    if [[ -z "$repository_slug" ]]; then
        remote_url="$(git remote get-url origin)"
        case "$remote_url" in
            https://github.com/*)
                repository_slug="${remote_url#https://github.com/}"
                ;;
            git@github.com:*)
                repository_slug="${remote_url#git@github.com:}"
                ;;
            ssh://git@github.com/*)
                repository_slug="${remote_url#ssh://git@github.com/}"
                ;;
            *)
                die "cannot derive GitHub repository from origin: $remote_url"
                ;;
        esac
    fi

    repository_slug="${repository_slug%/}"
    repository_slug="${repository_slug%.git}"
    [[ "$repository_slug" =~ ^[0-9A-Za-z_.-]+/[0-9A-Za-z_.-]+$ ]] || \
        die "invalid GitHub repository slug: $repository_slug"
    printf '%s\n' "$repository_slug"
}

REPOSITORY_SLUG="$(discover_repository_slug)"
PACKAGE_HASH="$(swift package compute-checksum "$OUTPUT_ARCHIVE")"
readonly REPOSITORY_SLUG PACKAGE_HASH
readonly RELEASE_URL="https://github.com/${REPOSITORY_SLUG}/releases/download/${TAG_VERSION}/${RELEASE_ARCHIVE_NAME}"
readonly PACKAGE_DECLARATION="let vlcBinary = Target.binaryTarget(name: \"${BINARY_TARGET_NAME}\", url: \"${RELEASE_URL}\", checksum: \"${PACKAGE_HASH}\")"

printf 'Updating Package.swift with checksum %s\n' "$PACKAGE_HASH"
sed -i '' -e "s|^let vlcBinary = .*|${PACKAGE_DECLARATION}|" Package.swift
grep -Fq "url: \"${RELEASE_URL}\"" Package.swift || \
    die "failed to update Package.swift"

license_path="$(find "$WORK_DIR" -type f -path '*/MobileVLCKit-binary/COPYING.txt' -print -quit)"
[[ -n "$license_path" ]] || die "MobileVLCKit license file not found"
cp -f "$license_path" "$SCRIPT_DIR/LICENSE"

cat <<EOF

Generated: $OUTPUT_ARCHIVE
Updated:   $SCRIPT_DIR/Package.swift
Release:   $RELEASE_URL

Create the GitHub release for tag $TAG_VERSION and upload $RELEASE_ARCHIVE_NAME.
EOF
