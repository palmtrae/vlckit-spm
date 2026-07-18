#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PRODUCTION_URL="https://download.videolan.org/cocoapods/prod"
readonly UNSTABLE_URL="https://download.videolan.org/cocoapods/unstable"
readonly ASSET_NAME="VLCKit-all.xcframework.zip"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

for required_command in awk curl gh git grep mktemp sed shasum sleep swift tr unzip wc; do
    require_command "$required_command"
done

[[ -n "${GITHUB_REPOSITORY:-}" ]] || die "GITHUB_REPOSITORY is required"
[[ -n "${GH_TOKEN:-}" ]] || die "GH_TOKEN is required"
[[ "$GITHUB_REPOSITORY" =~ ^[0-9A-Za-z_.-]+/[0-9A-Za-z_.-]+$ ]] || \
    die "invalid GITHUB_REPOSITORY: $GITHUB_REPOSITORY"

readonly RUN_DIRECTORY="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vlckit-release.XXXXXX")"
trap 'rm -rf -- "$RUN_DIRECTORY"' EXIT

cd "$REPOSITORY_ROOT"
[[ -z "$(git status --porcelain)" ]] || die "working tree must be clean"

git fetch --prune origin main
git fetch --tags origin

readonly PRODUCTION_INDEX="${RUN_DIRECTORY}/production.html"
readonly UNSTABLE_INDEX="${RUN_DIRECTORY}/unstable.html"
readonly SELECTION_FILE="${RUN_DIRECTORY}/selection.tsv"

curl --fail --silent --show-error --location --retry 3 \
    "${PRODUCTION_URL}/" --output "$PRODUCTION_INDEX"
curl --fail --silent --show-error --location --retry 3 \
    "${UNSTABLE_URL}/" --output "$UNSTABLE_INDEX"

"${SCRIPT_DIR}/select-releases.swift" \
    "${PRODUCTION_URL}=${PRODUCTION_INDEX}" \
    "${UNSTABLE_URL}=${UNSTABLE_INDEX}" >"$SELECTION_FILE"

if [[ ! -s "$SELECTION_FILE" ]]; then
    printf 'No complete stable or beta VLCKit versions were discovered.\n'
    exit 0
fi

release_exists() {
    local tag="$1"
    local output_path="$2"
    local error_path="${RUN_DIRECTORY}/release-error.txt"

    if gh api "repos/${GITHUB_REPOSITORY}/releases/tags/${tag}" \
        >"$output_path" 2>"$error_path"; then
        return 0
    fi

    if grep -q 'HTTP 404' "$error_path"; then
        return 1
    fi

    cat "$error_path" >&2
    die "could not inspect GitHub release $tag"
}

manifest_value_at_tag() {
    local tag="$1"
    local value="$2"
    local manifest

    manifest="$(git show "${tag}^{commit}:Package.swift")" || \
        die "could not read Package.swift at tag $tag"

    case "$value" in
        checksum)
            printf '%s\n' "$manifest" |
                sed -n 's/.*checksum: "\([0-9a-f]\{64\}\)".*/\1/p'
            ;;
        url)
            printf '%s\n' "$manifest" |
                sed -n 's/.*url: "\([^"]*\)".*/\1/p'
            ;;
        *)
            die "unknown manifest value: $value"
            ;;
    esac
}

asset_digest() {
    local release_id="$1"
    local asset_rows
    local count

    asset_rows="$(
        gh api --paginate "repos/${GITHUB_REPOSITORY}/releases/${release_id}/assets" \
            --jq ".[] | select(.name == \"${ASSET_NAME}\") | [.id, .digest] | @tsv"
    )"

    if [[ -z "$asset_rows" ]]; then
        return 1
    fi

    count="$(printf '%s\n' "$asset_rows" | wc -l | tr -d ' ')"
    [[ "$count" == "1" ]] || die "release contains multiple $ASSET_NAME assets"
    printf '%s\n' "$asset_rows" | sed -n 's/^[^	]*	//p'
}

verify_release_asset() {
    local release_id="$1"
    local expected_checksum="$2"
    local allow_digest_delay="$3"
    local expected_digest="sha256:${expected_checksum}"
    local digest=""
    local attempt

    for attempt in {1..12}; do
        digest="$(asset_digest "$release_id" || true)"
        if [[ "$digest" == "$expected_digest" ]]; then
            return 0
        fi

        if [[ -n "$digest" && "$digest" != "null" ]]; then
            die "release asset digest $digest does not match $expected_digest"
        fi

        [[ "$allow_digest_delay" == "true" ]] || \
            die "release asset is missing its SHA-256 digest"
        sleep 5
    done

    die "release asset digest was not available after 60 seconds"
}

verify_tag_manifest() {
    local tag="$1"
    local expected_checksum="${2:-}"
    local tag_checksum
    local tag_url
    local expected_url="https://github.com/${GITHUB_REPOSITORY}/releases/download/${tag}/${ASSET_NAME}"

    tag_checksum="$(manifest_value_at_tag "$tag" checksum)"
    tag_url="$(manifest_value_at_tag "$tag" url)"
    [[ "$tag_checksum" =~ ^[0-9a-f]{64}$ ]] || \
        die "tag $tag does not contain one valid binary checksum"
    [[ "$tag_url" == "$expected_url" ]] || \
        die "tag $tag points at an unexpected binary URL: $tag_url"
    [[ -z "$expected_checksum" || "$tag_checksum" == "$expected_checksum" ]] || \
        die "generated checksum does not match immutable tag $tag"

    printf '%s\n' "$tag_checksum"
}

LAST_SELECTED_TAG=""
DID_PUBLISH="false"

while IFS=$'\t' read -r upstream_version package_tag is_prerelease base_url \
    mobile_artifact television_artifact desktop_artifact; do
    [[ -n "$package_tag" ]] || continue
    LAST_SELECTED_TAG="$package_tag"

    printf '\nInspecting VLCKit %s (SwiftPM tag %s)...\n' \
        "$upstream_version" "$package_tag"

    tag_exists="false"
    if git show-ref --verify --quiet "refs/tags/${package_tag}"; then
        tag_exists="true"
    fi

    release_json="${RUN_DIRECTORY}/release-${package_tag}.json"
    has_release="false"
    if release_exists "$package_tag" "$release_json"; then
        has_release="true"
    fi

    if [[ "$has_release" == "true" ]]; then
        release_id="$(gh api "repos/${GITHUB_REPOSITORY}/releases/tags/${package_tag}" --jq '.id')"
        is_draft="$(gh api "repos/${GITHUB_REPOSITORY}/releases/tags/${package_tag}" --jq '.draft')"
        actual_prerelease="$(gh api "repos/${GITHUB_REPOSITORY}/releases/tags/${package_tag}" --jq '.prerelease')"
        [[ "$actual_prerelease" == "$is_prerelease" ]] || \
            die "release $package_tag has the wrong prerelease state"

        [[ "$tag_exists" == "true" ]] || \
            die "release $package_tag exists without its immutable Git tag"

        if [[ "$is_draft" == "false" ]]; then
            published_checksum="$(verify_tag_manifest "$package_tag")"
            verify_release_asset "$release_id" "$published_checksum" false
            printf 'Release %s is already complete; skipping generation.\n' "$package_tag"
            continue
        fi
    fi

    if [[ "$tag_exists" == "false" && "$has_release" == "true" ]]; then
        die "draft release $package_tag exists without its Git tag"
    fi

    printf 'Generating deterministic archive for %s...\n' "$upstream_version"
    VIDEOLAN_BASE_URL="$base_url" \
    EXPECTED_MOBILE_ARTIFACT="$mobile_artifact" \
    EXPECTED_TV_ARTIFACT="$television_artifact" \
    EXPECTED_MACOS_ARTIFACT="$desktop_artifact" \
        ./generate.sh "$upstream_version"

    readonly_archive="${REPOSITORY_ROOT}/.tmp/${ASSET_NAME}"
    release_info="${REPOSITORY_ROOT}/.tmp/release-info.tsv"
    release_notes="${REPOSITORY_ROOT}/.tmp/release-notes.md"
    [[ -s "$readonly_archive" ]] || die "generator did not produce $ASSET_NAME"
    [[ -s "$release_info" ]] || die "generator did not produce release-info.tsv"
    [[ -s "$release_notes" ]] || die "generator did not produce release notes"

    IFS=$'\t' read -r generated_upstream generated_tag generated_prerelease \
        generated_base generated_mobile generated_tv generated_desktop generated_checksum \
        <"$release_info"
    [[ "$generated_upstream" == "$upstream_version" && \
       "$generated_tag" == "$package_tag" && \
       "$generated_prerelease" == "$is_prerelease" && \
       "$generated_base" == "$base_url" && \
       "$generated_mobile" == "$mobile_artifact" && \
       "$generated_tv" == "$television_artifact" && \
       "$generated_desktop" == "$desktop_artifact" ]] || \
        die "generator metadata does not match selected candidate $package_tag"

    actual_checksum="$(shasum -a 256 "$readonly_archive" | awk '{print $1}')"
    [[ "$actual_checksum" == "$generated_checksum" ]] || \
        die "generated archive checksum does not match generator metadata"
    unzip -tq "$readonly_archive" >/dev/null
    swift package dump-package >/dev/null

    if [[ "$tag_exists" == "true" ]]; then
        verify_tag_manifest "$package_tag" "$generated_checksum" >/dev/null
        git diff --quiet "${package_tag}^{commit}" -- Package.swift LICENSE || \
            die "generated package files do not match immutable tag $package_tag"
    else
        git add Package.swift LICENSE
        if ! git diff --cached --quiet; then
            git commit -m "Package VLCKit ${upstream_version}"
        else
            printf 'Package files for %s are already committed at HEAD.\n' "$package_tag"
        fi
        git tag -a "$package_tag" -m "VLCKit ${upstream_version}"
        git push --atomic origin \
            HEAD:refs/heads/main \
            "refs/tags/${package_tag}:refs/tags/${package_tag}"
        tag_exists="true"
    fi

    if [[ "$has_release" == "false" ]]; then
        create_arguments=(
            "$package_tag"
            --verify-tag
            --draft
            --title "VLCKit ${upstream_version}"
            --notes-file "$release_notes"
        )
        if [[ "$is_prerelease" == "true" ]]; then
            create_arguments+=(--prerelease --latest=false)
        fi
        gh release create "${create_arguments[@]}"
        has_release="true"
    else
        gh release edit "$package_tag" \
            --verify-tag \
            --title "VLCKit ${upstream_version}" \
            --notes-file "$release_notes" \
            --prerelease="$is_prerelease"
    fi

    release_id="$(gh api "repos/${GITHUB_REPOSITORY}/releases/tags/${package_tag}" --jq '.id')"
    existing_digest="$(asset_digest "$release_id" || true)"
    if [[ -n "$existing_digest" ]]; then
        [[ "$existing_digest" == "sha256:${generated_checksum}" ]] || \
            die "draft asset for $package_tag does not match its tagged manifest"
    else
        gh release upload "$package_tag" "$readonly_archive"
    fi

    verify_release_asset "$release_id" "$generated_checksum" true
    gh release edit "$package_tag" \
        --draft=false \
        --prerelease="$is_prerelease"
    verify_release_asset "$release_id" "$generated_checksum" false
    DID_PUBLISH="true"
    printf 'Published VLCKit %s as %s.\n' "$upstream_version" "$package_tag"

    # Generation against an existing tag can temporarily change these files
    # away from the current main commit. Restore them before the next candidate.
    if [[ -n "$(git status --porcelain -- Package.swift LICENSE)" ]]; then
        git restore --source=HEAD -- Package.swift LICENSE
    fi
done <"$SELECTION_FILE"

if [[ "$DID_PUBLISH" == "false" ]]; then
    [[ -z "$(git status --porcelain)" ]] || die "automation left a dirty working tree"
    printf '\nAll selected releases were already complete; no changes made.\n'
    exit 0
fi

# A newly published stable can still be semantically older than a previously
# published beta. Copying the newest selected tag's package state forward keeps
# main as the moving "latest available" pointer without moving any version tag.
if ! git diff --quiet "${LAST_SELECTED_TAG}^{commit}" -- Package.swift LICENSE; then
    git restore --source="${LAST_SELECTED_TAG}^{commit}" -- Package.swift LICENSE
    git add Package.swift LICENSE
    git commit -m "Point main to VLCKit ${LAST_SELECTED_TAG}"
    git push origin HEAD:refs/heads/main
fi

[[ -z "$(git status --porcelain)" ]] || die "automation left a dirty working tree"
printf '\nmain points at the newest selected VLCKit version: %s\n' "$LAST_SELECTED_TAG"
