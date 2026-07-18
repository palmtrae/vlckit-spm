#!/usr/bin/env swift

import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: normalize-xcframework-plist.swift <Info.plist>")
}

let plistURL = URL(fileURLWithPath: CommandLine.arguments[1])

do {
    let data = try Data(contentsOf: plistURL)
    let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
    guard var root = propertyList as? [String: Any],
          var libraries = root["AvailableLibraries"] as? [[String: Any]] else {
        fail("invalid XCFramework property list: \(plistURL.path)")
    }

    for library in libraries {
        guard library["LibraryIdentifier"] as? String != nil else {
            fail("XCFramework library is missing LibraryIdentifier")
        }
    }

    libraries.sort {
        ($0["LibraryIdentifier"] as! String) < ($1["LibraryIdentifier"] as! String)
    }
    root["AvailableLibraries"] = libraries

    let normalized = try PropertyListSerialization.data(
        fromPropertyList: root,
        format: .xml,
        options: 0
    )
    try normalized.write(to: plistURL, options: .atomic)
} catch {
    fail("could not normalize \(plistURL.path): \(error)")
}
