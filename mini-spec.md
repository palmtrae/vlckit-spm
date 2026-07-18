# Mini Spec

## Summary

- Problem: `generate.sh` hard-codes the VLCKit version, three complete VideoLAN artifact URLs, architecture-specific framework paths, and the original repository owner.
- Proposed approach: accept one release tag, discover the matching upstream artifacts and extracted framework slices, derive the GitHub repository from `origin`, and update `Package.swift` with the generated archive checksum.
- Why this is small enough for the micro harness: the change is isolated to one packaging script plus its usage documentation.

## Scope

- In: tag validation, artifact discovery, reliable downloads, slice discovery, package URL generation, checksum generation, and usage documentation.
- Out: creating GitHub releases, uploading assets, tagging commits, or changing the package API.

## Constraints

- The normal invocation must require only a VLCKit release tag.
- Failures and ambiguous artifact matches must stop without producing a misleading package definition.

## Success Check

- `./generate.sh 3.7.3` can resolve exactly one official artifact for iOS, macOS, and tvOS without embedding their build hashes or architecture directory names in the script.

## Notes

- `GITHUB_REPOSITORY` and `VIDEOLAN_BASE_URL` remain optional environment overrides for CI and testing.
