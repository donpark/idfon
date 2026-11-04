#if PHONON_TTS
import CryptoKit
import Foundation

/// Install a `PhononModels` bundle, fetching each distinct blob once and
/// hardlinking the files that share it.
///
/// The export writes the flow LM's weights into both `flow-c414-t1` and
/// `flow-c414-t48` (same bytes, same SHA-256 in `bundle.json`): 55 MB of the
/// 170 MB manifest for one 240 KB graph difference. `PhononModels.download`
/// fetches every path, so the phone pulled and kept two copies. This does the
/// same job — per-file size+SHA-256, `built` stamp, `bundle.json` last — with
/// one download per distinct hash. A bundle that is already installed is
/// relinked in place, which is how an existing 170 MB install shrinks.
///
/// Self-contained on purpose (no ptts types): `Checks/PhononBundleCheck`
/// compiles it alone.
///
/// Files are verified by size and SHA-256 every time, not by the manifest's
/// `built` stamp: an edited or partial bundle never loads.
///
/// The same bytes are duplicated a second time once Core ML compiles: it writes
/// `<pkg>.mlmodelc` beside each package with its own `weights/weight.bin`.
/// `relinkCompiled` links those too, after a load (that is what compiles them).
///
/// shortcut: a served pack still sends both paths over HTTP — the saving is
/// this side, one download per hash.
enum PhononBundle {
    /// A `bundle.json` as the exporter writes it.
    struct Manifest: Decodable {
        struct File: Decodable {
            let path: String
            let size: Int
            let sha256: String
        }
        let built: Int
        let files: [File]
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Install the bundle `base` serves at `dir` and return `dir`.
    /// Idempotent: an installed bundle of the same export is only relinked.
    /// shortcut: files a newer export no longer lists are left behind (nothing
    /// is pruned — `voices/` is user state and must survive), so a re-export
    /// that renames a package costs disk until the dir is cleared.
    static func install(from base: URL, to dir: URL) async throws -> URL {
        let manifestURL = base.appendingPathComponent("bundle.json")
        let data = try await fetch(manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Hash -> the first path that holds those bytes. Every later path for
        // the same hash becomes a link instead of a download.
        var donors: [String: URL] = [:]
        for file in manifest.files {
            let dest = dir.appendingPathComponent(file.path)
            if let donor = donors[file.sha256] {
                try link(donor, to: dest)
                continue
            }
            if try !matches(dest, file) {
                let (tmp, _) = try await URLSession.shared.download(
                    from: base.appendingPathComponent(file.path))
                guard try matches(tmp, file) else {
                    throw Failure(message: "\(file.path) does not match its size or SHA-256")
                }
                try fm.createDirectory(
                    at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: tmp, to: dest)
            }
            donors[file.sha256] = dest
        }

        // Last, so an interrupted install is not "installed".
        try data.write(to: dir.appendingPathComponent("bundle.json"))
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = dir
        try? dir.setResourceValues(values)
        return dir
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

    private static func manifest(at dir: URL) -> Manifest? {
        (try? Data(contentsOf: dir.appendingPathComponent("bundle.json")))
            .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
    }

    /// `<pkg>.mlpackage/Data/com.apple.CoreML/weights/x` becomes
    /// `<pkg>.mlmodelc/weights/x` once compiled.
    private static func compiledURL(for path: String, in dir: URL) -> URL? {
        guard let tag = path.range(of: ".mlpackage/") else { return nil }
        guard let name = path.split(separator: "/").last else { return nil }
        return dir.appendingPathComponent(
            "\(path[path.startIndex..<tag.lowerBound]).mlmodelc/weights/\(name)")
    }

    private static func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure(message: "\(url.lastPathComponent): HTTP \(http.statusCode)")
        }
        return data
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

    /// ptts's rule: same size, then SHA-256 over the file.
    private static func matches(_ url: URL, _ file: Manifest.File) throws -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size == file.size
        else { return false }
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
