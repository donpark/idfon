//! Shared path safety for the filespace providers and the daemon resource store.
//!
//! Both the folder provider (`idfon-mcp fs`) and the daemon's media-resource
//! store address bytes by a caller-supplied relative path joined under a root,
//! so both must reject the same escapes. This is the one validation they share;
//! symlink escapes additionally need a canonicalize + prefix check at the point
//! of use.

use std::path::{Component, Path, PathBuf};

/// Validates a caller-supplied relative path for joining under a root.
///
/// Returns `None` for empty input, absolute paths, and any non-`Normal`
/// component (`..`, `.`, root, Windows prefix), so the result stays under the
/// root lexically. It says nothing about the filesystem: a symlink inside the
/// root can still point out, so readers must also canonicalize and check the
/// prefix.
pub fn safe_relative_path(rel: &str) -> Option<PathBuf> {
    if rel.is_empty() {
        return None;
    }
    let path = Path::new(rel);
    if path.is_absolute()
        || path
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return None;
    }
    Some(path.to_path_buf())
}

/// Content type inferred from the file extension. Shared by the folder
/// provider and the daemon's live-root provider so both answer the same way and
/// previews (html, images, media) render without a `.mime` sidecar.
pub fn mime_for(path: &Path) -> String {
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    match extension.as_str() {
        "txt" | "log" => "text/plain",
        "md" => "text/markdown",
        "json" => "application/json",
        "csv" => "text/csv",
        "html" | "htm" => "text/html",
        "xml" => "application/xml",
        "yaml" | "yml" => "application/yaml",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "pdf" => "application/pdf",
        "wav" => "audio/wav",
        "mp3" => "audio/mpeg",
        "opus" | "ogg" => "audio/ogg",
        "mp4" => "video/mp4",
        "zip" => "application/zip",
        _ => "application/octet-stream",
    }
    .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_nested_normal_paths() {
        assert_eq!(
            safe_relative_path("session_1/chart/artifact.html"),
            Some(PathBuf::from("session_1/chart/artifact.html"))
        );
        assert_eq!(
            safe_relative_path("readme.txt"),
            Some(PathBuf::from("readme.txt"))
        );
    }

    #[test]
    fn infers_content_types_from_extensions() {
        assert_eq!(mime_for(Path::new("a/b.html")), "text/html");
        assert_eq!(mime_for(Path::new("chart.PNG")), "image/png");
        assert_eq!(mime_for(Path::new("noext")), "application/octet-stream");
    }

    #[test]
    fn rejects_escapes_and_empty() {
        assert_eq!(safe_relative_path(""), None);
        assert_eq!(safe_relative_path(".."), None);
        assert_eq!(safe_relative_path("../secret"), None);
        assert_eq!(safe_relative_path("a/../../secret"), None);
        assert_eq!(safe_relative_path("/etc/passwd"), None);
        assert_eq!(safe_relative_path("./a"), None);
    }
}
