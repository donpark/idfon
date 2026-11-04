#if PHONON_TTS
import CryptoKit
import Foundation

/// The Phonon model pack: the Core ML bundle `scripts/fetch-phonon-31m.sh`
/// writes, delivered over HTTP from a content-addressed tree (`<base>/bundle.json`,
/// files at `<base>/sha256/<hash>`) or kept by the caller.
///
/// Two manifest paths are the same bytes: the flow LM's weights ship inside
/// both `flow-c414-t1` and `flow-c414-t48`, which differ by one 240 KB graph
/// (the graphs are static-shape per `(ctx, t)` because the ANE needs that).
/// The manifest lists 170 MB of files for 115 MB of content, so each distinct
/// SHA-256 is downloaded once and every other path for it is a hardlink. Core
/// ML then writes the same weights a second time when it compiles
/// `.mlpackage` → `.mlmodelc`; `relinkCompiled` links those after a load,
/// which is what compiles them.
///
/// Self-contained (no ptts types) on purpose: `mac/Checks/PhononPackCheck`
/// compiles it alone.
enum PhononPack {
    /// A `bundle.json` as the exporter writes it.
    struct Manifest: Decodable {
        struct File: Decodable {
            let path: String
            let size: Int
            let sha256: String
        }
        let built: Int64
        let files: [File]
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Install the pack `base` serves at `dir` and return `dir`.
    @discardableResult
    static func download(from base: URL, to dir: URL) async throws -> URL {
        let fm = FileManager.default
        // An installed pack must stay usable offline: a failed manifest fetch
        // is only fatal when there is nothing to fall back to.
        let data: Data
        do {
            let (remote, response) = try await URLSession.shared.data(
                from: base.appending(path: "bundle.json"))
            try check(response, "bundle.json")
            data = remote
        } catch {
            if installed(at: dir) { return dir }
            throw error
        }
        let want = try JSONDecoder().decode(Manifest.self, from: data)
        if installedBuilt(at: dir) == want.built {
            linkDuplicates(want, at: dir)  // shrink a pack an older build wrote
            return dir
        }

        let staging = dir.deletingLastPathComponent()
            .appending(path: "\(dir.lastPathComponent).partial-\(want.built)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        // Hash -> the first path holding those bytes; every later path for the
        // same hash is a link, not a download.
        var donors: [String: URL] = [:]
        for file in want.files {
            let dest = staging.appending(path: file.path)
            if let donor = donors[file.sha256] {
                try link(donor, to: dest)
                continue
            }
            if try matches(dest, file) {
                donors[file.sha256] = dest
                continue
            }
            let (tmp, response) = try await URLSession.shared.download(
                from: base.appending(path: "sha256/\(file.sha256)"))
            try check(response, file.path)
            guard try matches(tmp, file) else {
                try? fm.removeItem(at: tmp)
                throw Failure(message: "\(file.path) does not match its size or SHA-256")
            }
            try fm.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: tmp, to: dest)
            donors[file.sha256] = dest
        }

        try data.write(to: staging.appending(path: "bundle.json"))
        try? fm.removeItem(at: dir)
        try fm.moveItem(at: staging, to: dir)
        var url = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return dir
    }

    /// Whether `dir` holds every file the manifest lists.
    static func installed(at dir: URL) -> Bool {
        guard let manifest = manifest(at: dir) else { return false }
        return manifest.files.allSatisfy {
            FileManager.default.fileExists(atPath: dir.appending(path: $0.path).path)
        }
    }

    /// Core ML writes a `.mlmodelc` beside each package, weights included:
    /// the t1 and t48 graphs repeat the same 55 MB a second time. Relink them
    /// (the ANE maps the file read-only, so one copy serves both graphs). Call
    /// after `Phonon.load`, which is what compiles them. No hashing: the
    /// manifest's SHA-256 already says which sources are the same bytes.
    static func relinkCompiled(at dir: URL) {
        guard let manifest = manifest(at: dir) else { return }
        var groups: [String: [URL]] = [:]
        for file in manifest.files {
            guard let compiled = compiledURL(for: file.path, in: dir) else { continue }
            groups[file.sha256, default: []].append(compiled)
        }
        for paths in groups.values where paths.count > 1 {
            guard let donor = paths.first(where: { FileManager.default.fileExists(atPath: $0.path) })
            else { continue }
            for path in paths where path != donor { try? link(donor, to: path) }
        }
    }

    /// Link the paths an installed manifest says are the same bytes. No I/O
    /// beyond the links, so a pack of the current export costs nothing.
    private static func linkDuplicates(_ manifest: Manifest, at dir: URL) {
        var groups: [String: [URL]] = [:]
        for file in manifest.files {
            groups[file.sha256, default: []].append(dir.appending(path: file.path))
        }
        for paths in groups.values where paths.count > 1 {
            guard let donor = paths.first(where: { FileManager.default.fileExists(atPath: $0.path) })
            else { continue }
            for path in paths where path != donor { try? link(donor, to: path) }
        }
    }

    private static func manifest(at dir: URL) -> Manifest? {
        (try? Data(contentsOf: dir.appending(path: "bundle.json")))
            .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
    }

    private static func installedBuilt(at dir: URL) -> Int64? {
        guard installed(at: dir) else { return nil }
        return manifest(at: dir)?.built
    }

    /// `<pkg>.mlpackage/Data/com.apple.CoreML/weights/x` becomes
    /// `<pkg>.mlmodelc/weights/x` once compiled.
    private static func compiledURL(for path: String, in dir: URL) -> URL? {
        guard let tag = path.range(of: ".mlpackage/") else { return nil }
        guard let name = path.split(separator: "/").last else { return nil }
        return dir.appending(path: "\(path[path.startIndex..<tag.lowerBound]).mlmodelc/weights/\(name)")
    }

    private static func check(_ response: URLResponse, _ what: String) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure(message: "\(what): HTTP \(http.statusCode)")
        }
    }

    /// Replace `dest` with a hardlink to `donor`, or a copy where the file
    /// system has no links. Linking a path to itself is a no-op.
    private static func link(_ donor: URL, to dest: URL) throws {
        let fm = FileManager.default
        if sameFile(donor, dest) { return }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = dest.appendingPathExtension("link")
        try? fm.removeItem(at: staged)
        do {
            try fm.linkItem(at: donor, to: staged)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: staged, to: dest)
        } catch {
            try? fm.removeItem(at: staged)
            if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: donor, to: dest) }
        }
    }

    /// Same inode: the two paths already share one file. Fresh URLs: a URL
    /// caches the resource values it has already read.
    private static func sameFile(_ a: URL, _ b: URL) -> Bool {
        func id(_ url: URL) -> NSObject? {
            let fresh = URL(fileURLWithPath: url.path)
            return (try? fresh.resourceValues(forKeys: [.fileResourceIdentifierKey])
                .fileResourceIdentifier) as? NSObject
        }
        guard let x = id(a), let y = id(b) else { return false }
        return x.isEqual(y)
    }

    private static func matches(_ url: URL, _ file: Manifest.File) throws -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size == file.size else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256
    }
}
#endif
