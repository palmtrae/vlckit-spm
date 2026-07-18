# VLCKit SPM

This is a Swift Package Manager compatible version of [VLCKit](https://code.videolan.org/videolan/VLCKit).
It distributes and bundles VLCKit for iOS, macOS, and tvOS as a single Swift Package.

## Installation

Add this repository as a Swift Package dependency:

```
https://github.com/palmtrae/vlckit-spm
```

For a stable version range in another package:

```swift
.package(
    url: "https://github.com/palmtrae/vlckit-spm/",
    .upToNextMajor(from: "3.7.3")
)
```

Beta tags use SemVer prerelease syntax. Select them explicitly so a stable
version range never opts into beta code:

```swift
.package(
    url: "https://github.com/palmtrae/vlckit-spm/",
    exact: "3.8.0-b1"
)
```

VideoLAN's upstream beta name remains in the release title and notes; only the
SwiftPM tag is normalized (`3.8.0b1` becomes `3.8.0-b1`).

## Usage

To get started, import this library: `import VLCKitSPM`

See the [VLCKit documentation](https://videolan.videolan.me/VLCKit/) for more info on integration and usage for VLCKit.

## Releases

The release workflow checks VideoLAN every Sunday and can also be run manually
without inputs. It publishes at most two versions per run:

- The newest complete stable version.
- The newest complete beta version, only when it is newer than that stable.

A version is complete only when VideoLAN provides matching MobileVLCKit,
TVVLCKit, and VLCKit archives. The workflow builds a deterministic combined
XCFramework, commits its binary-target checksum, creates the immutable version
tag, verifies the uploaded release asset's SHA-256 digest, and then publishes
the release. Interrupted draft releases are resumed only when every existing
piece still matches.

`main` intentionally follows the newest available packaged version, including
a beta. Stable versus beta identity belongs to immutable version tags, so
package consumers should depend on a tag or version requirement rather than a
branch.

The generated archive is attached directly to its GitHub release. It is never
committed to Git or retained as a workflow artifact.

## Local generation

To package a particular upstream release locally, pass its VideoLAN version:

```
./generate.sh 3.7.3
./generate.sh 3.8.0b1
```

The script searches VideoLAN's production and unstable indexes, discovers the
matching archives and extracted framework slices, derives this GitHub
repository from `origin`, and updates `Package.swift`. Its outputs are:

- `.tmp/VLCKit-all.xcframework.zip`
- `.tmp/release-info.tsv`
- `.tmp/release-notes.md`
- the updated `Package.swift` and `LICENSE`

Run `Tests/test-release-tools.sh` to verify release selection, SemVer ordering,
completeness filtering, deterministic ZIP output, and framework symlink
preservation.
