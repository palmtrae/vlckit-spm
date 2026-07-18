# VLCKit SPM

This is a Swift Package Manager compatible version of [VLCKit](https://code.videolan.org/videolan/VLCKit). 
It distributes and bundles VLCKit for iOS, macOS and tvOS as a single Swift Package. 

### Installation
Add this repo to as a Swift Package dependency to your project
```
https://github.com/palmtrae/vlckit-spm
```

If using this in a swift package, add this repo as a dependency.
```
.package(url: "https://github.com/palmtrae/vlckit-spm/", .upToNextMajor(from: "3.7.3"))
```

### Usage

To get started, import this library: `import VLCKitSPM`

See the [VLCKit documentation](https://videolan.videolan.me/VLCKit/) for more info on integration and usage for VLCKit.

### Building
To package a VLCKit release, pass its VideoLAN release tag:

```
./generate.sh 3.7.3
```

The script discovers the matching iOS, macOS, and tvOS archives from
VideoLAN's production index. It also discovers the extracted framework slices
and derives the GitHub release repository from the checkout's `origin` remote.

After generation:

1. Commit the generated `Package.swift`.
2. Tag that commit with the same version passed to the script.
3. Push the commit and tag.
4. Create the matching GitHub release and upload
   `.tmp/VLCKit-all.xcframework.zip`.
