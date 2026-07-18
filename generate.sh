#!/bin/bash

set -euo pipefail

readonly VIDEOLAN_PRODUCTION_URL="https://download.videolan.org/cocoapods/prod"
readonly VIDEOLAN_UNSTABLE_URL="https://download.videolan.org/cocoapods/unstable"
readonly BINARY_TARGET_NAME="VLCKit-all"
readonly RELEASE_ARCHIVE_NAME="${BINARY_TARGET_NAME}.xcframework.zip"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WORK_DIR="${SCRIPT_DIR}/.tmp"

usage() {
    cat <<EOF
Usage: ./generate.sh <upstream-vlckit-version>

Example:
  ./generate.sh 3.7.3
  ./generate.sh 3.8.0b1

The script discovers the matching MobileVLCKit, TVVLCKit, and VLCKit
archives from VideoLAN, then updates Package.swift for this Git fork. A beta
such as 3.8.0b1 is published with the SwiftPM-compatible tag 3.8.0-b1.
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

readonly UPSTREAM_VERSION="$1"
if [[ "$UPSTREAM_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    readonly PACKAGE_TAG="$UPSTREAM_VERSION"
    readonly IS_PRERELEASE="false"
elif [[ "$UPSTREAM_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)b([0-9]+)$ ]]; then
    readonly PACKAGE_TAG="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}-b${BASH_REMATCH[4]}"
    readonly IS_PRERELEASE="true"
else
    die "unsupported VLCKit version: $UPSTREAM_VERSION"
fi

for required_command in curl tar find sort xcodebuild swift sed git zip touch; do
    require_command "$required_command"
done

cd "$SCRIPT_DIR"
[[ "$WORK_DIR" == "$SCRIPT_DIR/.tmp" ]] || die "refusing to use unexpected work directory"

if [[ -n "${VIDEOLAN_BASE_URL:-}" ]]; then
    source_urls=("${VIDEOLAN_BASE_URL%/}")
else
    source_urls=("$VIDEOLAN_PRODUCTION_URL" "$VIDEOLAN_UNSTABLE_URL")
fi

SELECTED_BASE_URL=""
IOS_ARTIFACT=""
TVOS_ARTIFACT=""
MACOS_ARTIFACT=""

for source_url in "${source_urls[@]}"; do
    printf 'Fetching VideoLAN artifact index: %s\n' "$source_url"
    artifact_index="$(
        curl --fail --silent --show-error --location --retry 3 "${source_url}/"
    )"

    ios_match=""
    tvos_match=""
    macos_match=""
    ios_count=0
    tvos_count=0
    macos_count=0
    while IFS= read -r artifact_name; do
        case "$artifact_name" in
            "MobileVLCKit-${UPSTREAM_VERSION}-"*.tar.xz)
                ios_match="$artifact_name"
                ios_count=$((ios_count + 1))
                ;;
            "TVVLCKit-${UPSTREAM_VERSION}-"*.tar.xz)
                tvos_match="$artifact_name"
                tvos_count=$((tvos_count + 1))
                ;;
            "VLCKit-${UPSTREAM_VERSION}-"*.tar.xz)
                macos_match="$artifact_name"
                macos_count=$((macos_count + 1))
                ;;
        esac
    done < <(
        printf '%s\n' "$artifact_index" |
            sed -n 's/.*href="\([^"]*\.tar\.xz\)".*/\1/p'
    )

    if [[ $ios_count -gt 1 || $tvos_count -gt 1 || $macos_count -gt 1 ]]; then
        die "ambiguous $UPSTREAM_VERSION artifacts at $source_url"
    fi

    if [[ $ios_count -eq 1 && $tvos_count -eq 1 && $macos_count -eq 1 ]]; then
        SELECTED_BASE_URL="$source_url"
        IOS_ARTIFACT="$ios_match"
        TVOS_ARTIFACT="$tvos_match"
        MACOS_ARTIFACT="$macos_match"
        break
    fi
done

[[ -n "$SELECTED_BASE_URL" ]] || \
    die "could not find one complete artifact set for $UPSTREAM_VERSION"

[[ -z "${EXPECTED_MOBILE_ARTIFACT:-}" || "$IOS_ARTIFACT" == "$EXPECTED_MOBILE_ARTIFACT" ]] || \
    die "discovered MobileVLCKit artifact does not match the selected candidate"
[[ -z "${EXPECTED_TV_ARTIFACT:-}" || "$TVOS_ARTIFACT" == "$EXPECTED_TV_ARTIFACT" ]] || \
    die "discovered TVVLCKit artifact does not match the selected candidate"
[[ -z "${EXPECTED_MACOS_ARTIFACT:-}" || "$MACOS_ARTIFACT" == "$EXPECTED_MACOS_ARTIFACT" ]] || \
    die "discovered VLCKit artifact does not match the selected candidate"

readonly SELECTED_BASE_URL IOS_ARTIFACT TVOS_ARTIFACT MACOS_ARTIFACT

rm -rf -- "$WORK_DIR"
mkdir -p "$WORK_DIR"

download_and_extract() {
    local product_name="$1"
    local artifact_name="$2"
    local archive_path="${WORK_DIR}/${product_name}.tar.xz"
    local artifact_url="${SELECTED_BASE_URL}/${artifact_name}"

    printf 'Downloading %s\n' "$artifact_name"
    curl --fail --location --retry 3 --output "$archive_path" "$artifact_url"

    while IFS= read -r archive_entry; do
        [[ "$archive_entry" != /* ]] || die "archive contains an absolute path: $artifact_name"
        case "/${archive_entry}/" in
            */../*) die "archive contains a parent traversal: $artifact_name" ;;
        esac
    done < <(tar -tf "$archive_path")

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

"${SCRIPT_DIR}/Scripts/normalize-xcframework-plist.swift" \
    "${OUTPUT_XCFRAMEWORK}/Info.plist"

"${SCRIPT_DIR}/Scripts/create-deterministic-zip.sh" \
    "$OUTPUT_XCFRAMEWORK" "$OUTPUT_ARCHIVE"

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
readonly RELEASE_URL="https://github.com/${REPOSITORY_SLUG}/releases/download/${PACKAGE_TAG}/${RELEASE_ARCHIVE_NAME}"
readonly PACKAGE_DECLARATION="let vlcBinary = Target.binaryTarget(name: \"${BINARY_TARGET_NAME}\", url: \"${RELEASE_URL}\", checksum: \"${PACKAGE_HASH}\")"

printf 'Updating Package.swift with checksum %s\n' "$PACKAGE_HASH"
sed -i '' -e "s|^let vlcBinary = .*|${PACKAGE_DECLARATION}|" Package.swift
grep -Fq "url: \"${RELEASE_URL}\"" Package.swift || \
    die "failed to update Package.swift"

license_path="$(find "$WORK_DIR" -type f -path '*/MobileVLCKit-binary/COPYING.txt' -print -quit)"
[[ -n "$license_path" ]] || die "MobileVLCKit license file not found"
cp -f "$license_path" "$SCRIPT_DIR/LICENSE"

readonly RELEASE_NOTES_PATH="${WORK_DIR}/release-notes.md"
readonly RELEASE_INFO_PATH="${WORK_DIR}/release-info.tsv"

cat >"$RELEASE_NOTES_PATH" <<EOF
Packaged from the official VideoLAN VLCKit **${UPSTREAM_VERSION}** artifacts.

- MobileVLCKit: [${IOS_ARTIFACT}](${SELECTED_BASE_URL}/${IOS_ARTIFACT})
- TVVLCKit: [${TVOS_ARTIFACT}](${SELECTED_BASE_URL}/${TVOS_ARTIFACT})
- VLCKit: [${MACOS_ARTIFACT}](${SELECTED_BASE_URL}/${MACOS_ARTIFACT})
- SwiftPM tag: \`${PACKAGE_TAG}\`
- SHA-256: \`${PACKAGE_HASH}\`
EOF

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$UPSTREAM_VERSION" "$PACKAGE_TAG" "$IS_PRERELEASE" \
    "$SELECTED_BASE_URL" "$IOS_ARTIFACT" "$TVOS_ARTIFACT" \
    "$MACOS_ARTIFACT" "$PACKAGE_HASH" >"$RELEASE_INFO_PATH"

cat <<EOF

Generated: $OUTPUT_ARCHIVE
Updated:   $SCRIPT_DIR/Package.swift
Release:   $RELEASE_URL

Create the GitHub release for tag $PACKAGE_TAG and upload $RELEASE_ARCHIVE_NAME.
EOF
