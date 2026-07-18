#!/bin/bash

set -euo pipefail

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[[ $# -eq 2 ]] || die "usage: $0 <input-directory> <output-zip>"

readonly INPUT_DIRECTORY="$1"
readonly OUTPUT_ZIP="$2"

[[ -d "$INPUT_DIRECTORY" ]] || die "input directory not found: $INPUT_DIRECTORY"
command -v zip >/dev/null 2>&1 || die "required command not found: zip"
command -v touch >/dev/null 2>&1 || die "required command not found: touch"

readonly INPUT_PARENT="$(cd "$(dirname "$INPUT_DIRECTORY")" && pwd)"
readonly INPUT_NAME="$(basename "$INPUT_DIRECTORY")"
readonly OUTPUT_PARENT="$(cd "$(dirname "$OUTPUT_ZIP")" && pwd)"
readonly OUTPUT_NAME="$(basename "$OUTPUT_ZIP")"

[[ "$OUTPUT_NAME" != */* ]] || die "invalid output filename: $OUTPUT_NAME"

# ZIP stores DOS timestamps and cannot represent dates before 1980. Normalizing
# every entry, excluding extended attributes, and sorting the member list makes
# the archive independent of download and extraction time.
find "$INPUT_DIRECTORY" -exec touch -h -t 200101010000 {} +
rm -f -- "${OUTPUT_PARENT}/${OUTPUT_NAME}"

(
    cd "$INPUT_PARENT"
    export COPYFILE_DISABLE=1
    find "$INPUT_NAME" -print | LC_ALL=C sort |
        zip -X -y -q "${OUTPUT_PARENT}/${OUTPUT_NAME}" -@
)

[[ -s "${OUTPUT_PARENT}/${OUTPUT_NAME}" ]] || \
    die "archive was not created: ${OUTPUT_PARENT}/${OUTPUT_NAME}"
