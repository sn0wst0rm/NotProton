// Give only the staged Wine loader the identity of its game app. Never modify
// the runner's shared inode. No Python installation is required at runtime.
import Foundation
import Darwin

enum PrepareError: Error { case invalid(String) }

func word(_ data: Data, _ offset: Int, _ size: Int) throws -> UInt64 {
    guard offset >= 0, size <= 8, offset <= data.count - size else {
        throw PrepareError.invalid("Truncated Mach-O")
    }
    return (0..<size).reduce(0) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
}

func plistSection(_ data: Data) throws -> Range<Int>? {
    guard try word(data, 0, 4) == 0xfeedfacf else {
        throw PrepareError.invalid("Expected a thin 64-bit Wine loader")
    }
    var position = 32
    let count = try word(data, 16, 4)
    for _ in 0..<count {
        let command = try word(data, position, 4)
        let size = Int(try word(data, position + 4, 4))
        guard size >= 8, position <= data.count - size else {
            throw PrepareError.invalid("Invalid Mach-O load command")
        }
        if command == 0x19 {
            let sections = Int(try word(data, position + 64, 4))
            guard size >= 72, sections <= (size - 72) / 80 else {
                throw PrepareError.invalid("Invalid section table")
            }
            for index in 0..<sections {
                let entry = position + 72 + index * 80
                let name = String(decoding: data[entry..<entry + 16].prefix { $0 != 0 }, as: UTF8.self)
                if name == "__info_plist" {
                    let length = try word(data, entry + 40, 8)
                    let start = Int(try word(data, entry + 48, 4))
                    guard start <= data.count, length <= UInt64(data.count - start) else {
                        throw PrepareError.invalid("Embedded plist extends beyond the loader")
                    }
                    return start..<start + Int(length)
                }
            }
        }
        position += size
    }
    return nil
}

func run(_ arguments: [String]) throws -> Data {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = arguments
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw PrepareError.invalid("codesign failed") }
    return data
}

func prepare(_ target: URL, _ info: URL) throws {
    let original = try Data(contentsOf: target)
    guard let section = try plistSection(original) else {
        print("Game Mode: no embedded plist; keeping app metadata")
        return
    }
    var bytes = original.subdata(in: section)
    while bytes.last == 0 || bytes.last == 32 { bytes.removeLast() }
    guard let old = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
          let app = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any],
          let identity = app["CFBundleIdentifier"] as? String,
          identity.hasPrefix("com.notproton.launcher."),
          let name = app["CFBundleName"] as? String,
          target.lastPathComponent == "wine" else {
        throw PrepareError.invalid("Not a staged NotProton game loader")
    }
    var updated = old.filter { ["CFBundleAllowMixedLocalizations", "CFBundleDevelopmentRegion",
        "CFBundleInfoDictionaryVersion", "CFBundleShortVersionString", "CFBundleVersion"].contains($0.key) }
    updated.merge(["CFBundleIdentifier": identity, "CFBundleName": name,
        "CFBundleExecutable": "wine", "CFBundlePackageType": "APPL", "NSPrincipalClass": "WineApplication",
        "NSHighResolutionCapable": true, "LSApplicationCategoryType": "public.app-category.games",
        "LSSupportsGameMode": true]) { _, new in new }
    let xml = try PropertyListSerialization.data(fromPropertyList: updated, format: .xml, options: 0)
    let compact = Data(String(decoding: xml, as: UTF8.self).split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }.joined().utf8)
    guard compact.count <= section.count else { throw PrepareError.invalid("Game metadata exceeds reserved section") }
    var replacement = original
    replacement.replaceSubrange(section, with: compact + Data(repeating: 32, count: section.count - compact.count))
    if replacement == original { return }
    let files = FileManager.default
    let temporary = target.deletingLastPathComponent().appendingPathComponent(".game-loader-" + UUID().uuidString)
    try files.createDirectory(at: temporary, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: temporary) }
    let staged = temporary.appendingPathComponent("wine")
    try replacement.write(to: staged)
    let attributes = try files.attributesOfItem(atPath: target.path)
    try files.setAttributes([.posixPermissions: attributes[.posixPermissions] ?? 0o755], ofItemAtPath: staged.path)
    let entitlements = try run(["-d", "--entitlements", ":-", target.path])
    var arguments = ["--force", "--sign", "-", "--identifier", identity, "--options", "runtime"]
    if !entitlements.isEmpty {
        _ = try PropertyListSerialization.propertyList(from: entitlements, format: nil)
        let file = temporary.appendingPathComponent("entitlements.plist")
        try entitlements.write(to: file)
        arguments += ["--entitlements", file.path]
    }
    _ = try run(arguments + [staged.path])
    _ = try run(["--verify", "--strict", staged.path])
    guard rename(staged.path, target.path) == 0 else { throw PrepareError.invalid("Atomic replacement failed: \(errno)") }
    print("Game Mode: staged Wine metadata updated for \(identity)")
}

do {
    guard CommandLine.arguments.count == 3 else { exit(64) }
    try prepare(URL(fileURLWithPath: CommandLine.arguments[1]), URL(fileURLWithPath: CommandLine.arguments[2]))
} catch {
    fputs("Game Mode: \(error)\n", stderr)
    exit(1)
}
