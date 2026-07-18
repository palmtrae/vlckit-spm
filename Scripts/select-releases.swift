#!/usr/bin/env swift

import Foundation

struct Version: Comparable, Hashable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let beta: Int?

    init?(_ upstreamValue: String) {
        let pattern = #"^([0-9]+)\.([0-9]+)\.([0-9]+)(?:b([0-9]+))?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(upstreamValue.startIndex..., in: upstreamValue)
        guard let match = expression.firstMatch(in: upstreamValue, range: range),
              match.range == range,
              let major = match.integer(at: 1, in: upstreamValue),
              let minor = match.integer(at: 2, in: upstreamValue),
              let patch = match.integer(at: 3, in: upstreamValue) else {
            return nil
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.beta = match.integer(at: 4, in: upstreamValue)
    }

    var description: String {
        let base = "\(major).\(minor).\(patch)"
        if let beta {
            return "\(base)b\(beta)"
        }
        return base
    }

    var packageTag: String {
        let base = "\(major).\(minor).\(patch)"
        if let beta {
            return "\(base)-b\(beta)"
        }
        return base
    }

    var isBeta: Bool { beta != nil }

    static func < (lhs: Version, rhs: Version) -> Bool {
        let lhsCore = [lhs.major, lhs.minor, lhs.patch]
        let rhsCore = [rhs.major, rhs.minor, rhs.patch]

        if lhsCore != rhsCore {
            return lhsCore.lexicographicallyPrecedes(rhsCore)
        }

        switch (lhs.beta, rhs.beta) {
        case let (.some(lhsBeta), .some(rhsBeta)):
            return lhsBeta < rhsBeta
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return false
        }
    }
}

private extension NSTextCheckingResult {
    func string(at index: Int, in source: String) -> String? {
        let matchRange = range(at: index)
        guard matchRange.location != NSNotFound,
              let range = Range(matchRange, in: source) else {
            return nil
        }
        return String(source[range])
    }
}

private extension NSTextCheckingResult {
    func integer(at index: Int, in source: String) -> Int? {
        guard let value = string(at: index, in: source) else {
            return nil
        }
        return Int(value)
    }
}

enum Product: String, CaseIterable {
    case mobile = "MobileVLCKit"
    case television = "TVVLCKit"
    case desktop = "VLCKit"
}

struct Source {
    let baseURL: String
    let indexPath: String
}

struct Candidate {
    let version: Version
    let source: Source
    let artifacts: [Product: String]
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

private func usage() -> Never {
    FileHandle.standardError.write(Data("""
    Usage: select-releases.swift <base-url>=<index-file> [<base-url>=<index-file> ...]

    Prints zero, one, or two tab-separated candidates in ascending SemVer order:
    upstream-version, package-tag, prerelease, base-url, MobileVLCKit artifact,
    TVVLCKit artifact, VLCKit artifact.

    Sources are preferred in argument order when the same complete version exists
    in more than one index.
    \n
    """.utf8))
    exit(2)
}

private func parseSource(_ argument: String) -> Source? {
    guard let separator = argument.lastIndex(of: "=") else {
        return nil
    }

    let baseURL = String(argument[..<separator]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let pathStart = argument.index(after: separator)
    let indexPath = String(argument[pathStart...])
    guard !baseURL.isEmpty, !indexPath.isEmpty else {
        return nil
    }
    return Source(baseURL: baseURL, indexPath: indexPath)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else {
    usage()
}

let sources = arguments.map { argument -> Source in
    guard let source = parseSource(argument) else {
        fail("invalid source argument: \(argument)")
    }
    return source
}

let artifactPattern = #"(?:href=[\"'])?((MobileVLCKit|TVVLCKit|VLCKit)-([0-9]+\.[0-9]+\.[0-9]+(?:b[0-9]+)?)-([0-9A-Za-z][0-9A-Za-z.-]*)\.tar\.xz)"#
let artifactExpression: NSRegularExpression
do {
    artifactExpression = try NSRegularExpression(pattern: artifactPattern)
} catch {
    fail("could not construct artifact parser: \(error)")
}

var candidatesByVersion: [Version: Candidate] = [:]

for source in sources {
    let html: String
    do {
        html = try String(contentsOfFile: source.indexPath, encoding: .utf8)
    } catch {
        fail("could not read \(source.indexPath): \(error)")
    }

    var artifactsByVersion: [Version: [Product: Set<String>]] = [:]
    let range = NSRange(html.startIndex..., in: html)

    for match in artifactExpression.matches(in: html, range: range) {
        guard let artifact = match.string(at: 1, in: html),
              let productName = match.string(at: 2, in: html),
              let product = Product(rawValue: productName),
              let upstreamVersion = match.string(at: 3, in: html),
              let version = Version(upstreamVersion) else {
            continue
        }

        artifactsByVersion[version, default: [:]][product, default: []].insert(artifact)
    }

    for (version, productArtifacts) in artifactsByVersion where candidatesByVersion[version] == nil {
        var uniqueArtifacts: [Product: String] = [:]
        var isComplete = true

        for product in Product.allCases {
            guard let matches = productArtifacts[product], matches.count == 1,
                  let artifact = matches.first else {
                isComplete = false
                break
            }
            uniqueArtifacts[product] = artifact
        }

        if isComplete {
            candidatesByVersion[version] = Candidate(
                version: version,
                source: source,
                artifacts: uniqueArtifacts
            )
        }
    }
}

let stable = candidatesByVersion.values
    .filter { !$0.version.isBeta }
    .max { $0.version < $1.version }

let beta = candidatesByVersion.values
    .filter { candidate in
        guard candidate.version.isBeta else { return false }
        guard let stable else { return true }
        return candidate.version > stable.version
    }
    .max { $0.version < $1.version }

let selected = [stable, beta]
    .compactMap { $0 }
    .sorted { $0.version < $1.version }

for candidate in selected {
    guard let mobile = candidate.artifacts[.mobile],
          let television = candidate.artifacts[.television],
          let desktop = candidate.artifacts[.desktop] else {
        fail("internal error: selected incomplete version \(candidate.version)")
    }

    let fields = [
        candidate.version.description,
        candidate.version.packageTag,
        candidate.version.isBeta ? "true" : "false",
        candidate.source.baseURL,
        mobile,
        television,
        desktop,
    ]
    print(fields.joined(separator: "\t"))
}
