#!/bin/bash

set -euo pipefail

readonly REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SELECTOR="${REPOSITORY_ROOT}/Scripts/select-releases.swift"
readonly ZIPPER="${REPOSITORY_ROOT}/Scripts/create-deterministic-zip.sh"
readonly PLIST_NORMALIZER="${REPOSITORY_ROOT}/Scripts/normalize-xcframework-plist.swift"
readonly FIXTURES="${REPOSITORY_ROOT}/Tests/Fixtures"

fail() {
    printf 'test failure: %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    if [[ "$actual" != "$expected" ]]; then
        printf 'test failure: %s\nexpected:\n%s\nactual:\n%s\n' \
            "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

selection="$(
    "$SELECTOR" \
        "https://download.videolan.org/cocoapods/prod=${FIXTURES}/current-prod.html" \
        "https://download.videolan.org/cocoapods/unstable=${FIXTURES}/current-unstable.html"
)"
expected_selection=$'3.7.3\t3.7.3\tfalse\thttps://download.videolan.org/cocoapods/prod\tMobileVLCKit-3.7.3-stable-ios.tar.xz\tTVVLCKit-3.7.3-stable-tv.tar.xz\tVLCKit-3.7.3-stable-mac.tar.xz\n3.8.0b3\t3.8.0-b3\ttrue\thttps://download.videolan.org/cocoapods/unstable\tMobileVLCKit-3.8.0b3-beta3-ios.tar.xz\tTVVLCKit-3.8.0b3-beta3-tv.tar.xz\tVLCKit-3.8.0b3-beta3-mac.tar.xz'
assert_equal "$expected_selection" "$selection" \
    "selector should emit only the newest complete stable and newer beta, oldest first"

stable_only="$(
    "$SELECTOR" \
        "https://download.videolan.org/cocoapods/prod=${FIXTURES}/stable-supersedes-beta.html"
)"
[[ "$(printf '%s\n' "$stable_only" | wc -l | tr -d ' ')" == "1" ]] || \
    fail "a beta superseded by its stable release must be ignored"
[[ "$stable_only" == $'3.8.0\t3.8.0\tfalse\t'* ]] || \
    fail "the newest stable must be selected"

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/vlckit-spm-tests.XXXXXX")"
trap 'rm -rf -- "$temporary_directory"' EXIT

first_plist="${temporary_directory}/first.plist"
second_plist="${temporary_directory}/second.plist"
cp "${FIXTURES}/xcframework-order-a.plist" "$first_plist"
cp "${FIXTURES}/xcframework-order-b.plist" "$second_plist"
"$PLIST_NORMALIZER" "$first_plist"
"$PLIST_NORMALIZER" "$second_plist"
cmp "$first_plist" "$second_plist" || \
    fail "XCFramework plist normalization must remove library-order variance"

fixture_directory="${temporary_directory}/Fixture.xcframework"
mkdir -p "${fixture_directory}/slice/Fixture.framework/Versions/A"
printf 'binary bytes\n' >"${fixture_directory}/slice/Fixture.framework/Versions/A/Fixture"
ln -s A "${fixture_directory}/slice/Fixture.framework/Versions/Current"
ln -s Versions/Current/Fixture "${fixture_directory}/slice/Fixture.framework/Fixture"

first_archive="${temporary_directory}/first.zip"
second_archive="${temporary_directory}/second.zip"
"$ZIPPER" "$fixture_directory" "$first_archive"
touch -t 202512312359 "${fixture_directory}/slice/Fixture.framework/Versions/A/Fixture"
"$ZIPPER" "$fixture_directory" "$second_archive"

first_hash="$(shasum -a 256 "$first_archive" | awk '{print $1}')"
second_hash="$(shasum -a 256 "$second_archive" | awk '{print $1}')"
assert_equal "$first_hash" "$second_hash" \
    "deterministic archive checksums should match after timestamp changes"

unzip -tq "$second_archive" >/dev/null
extracted_directory="${temporary_directory}/extracted"
mkdir -p "$extracted_directory"
unzip -q "$second_archive" -d "$extracted_directory"
[[ -L "${extracted_directory}/Fixture.xcframework/slice/Fixture.framework/Fixture" ]] || \
    fail "framework symlinks must survive archiving"

printf 'All release-tool tests passed.\n'
