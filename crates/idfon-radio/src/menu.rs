//! A menu contact's OPML resource: a nested catalogue of shows.
//!
//! OPML is data, not code: the contact is configured with one outline document
//! (sections and shows, arbitrarily nested) and our own UI renders it. A menu
//! contact serves individual needs — one caller, one selection, their own play
//! position — as opposed to the shared broadcast station.
//!
//! An outline entry is playable when it names a source:
//!
//! - `url` (or `xmlUrl`) with a scheme (`https://…`) — the **far end** serves it;
//! - `url` without a scheme — a path in the **local download cache**;
//! - `cache` — the cached copy of a far-end source (wins when the file exists).
//!
//! ```xml
//! <outline text="News">
//!   <outline text="Morning Briefing" url="https://example.com/morning.m3u8" cache="cache/morning.wav" />
//!   <outline text="Evening Report" url="cache/evening.wav" />
//! </outline>
//! ```
//!
//! shortcut: no feed fetching or cache management here. Nothing downloads or
//! refreshes entries; far-end sources decode at play time in the adapter.

use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use quick_xml::events::{BytesStart, Event};
use quick_xml::reader::Reader;
use quick_xml::XmlVersion;

/// The catalogue: top-level outline entries.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Menu {
    pub items: Vec<Item>,
}

/// One outline entry: a section (children), a show (a source), or both.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Item {
    /// The `text` attribute (or `title`), trimmed.
    pub title: String,
    /// The far end: a scheme-bearing source URL.
    pub remote: Option<String>,
    /// The local download cache copy, resolved against the OPML file's folder.
    pub local: Option<PathBuf>,
    pub items: Vec<Item>,
}

/// Where a show plays from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source {
    /// A file in the local download cache.
    Local(PathBuf),
    /// A URL the far end serves.
    Remote(String),
}

impl Menu {
    /// Read an OPML document from disk; relative sources resolve against its folder.
    pub fn load(path: &Path) -> Result<Self> {
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("read OPML {}", path.display()))?;
        Self::parse(&text, path.parent().unwrap_or(Path::new(".")))
    }

    pub fn parse(text: &str, base: &Path) -> Result<Self> {
        let mut reader = Reader::from_str(text);
        reader.config_mut().trim_text(true);
        let mut root: Vec<Item> = Vec::new();
        let mut stack: Vec<Item> = Vec::new();
        loop {
            match reader.read_event().with_context(|| "parse OPML")? {
                Event::Start(tag) if tag.local_name().as_ref() == "outline" => {
                    stack.push(item(&tag, base)?);
                }
                Event::Empty(tag) if tag.local_name().as_ref() == "outline" => {
                    let entry = item(&tag, base)?;
                    match stack.last_mut() {
                        Some(parent) => parent.items.push(entry),
                        None => root.push(entry),
                    }
                }
                Event::End(tag) if tag.local_name().as_ref() == "outline" => {
                    let entry = stack
                        .pop()
                        .with_context(|| "OPML closes an outline that never opened")?;
                    match stack.last_mut() {
                        Some(parent) => parent.items.push(entry),
                        None => root.push(entry),
                    }
                }
                Event::Eof => break,
                _ => {}
            }
        }
        if let Some(entry) = stack.last() {
            bail!("OPML leaves <outline text={:?} unterminated", entry.title);
        }
        Ok(Self { items: root })
    }

    /// Walk a menu path — `News/Morning Briefing`, or 1-based indices `1/2`,
    /// segments case-insensitive and mixable — and return the entry it names.
    pub fn resolve(&self, path: &str) -> Result<&Item> {
        let mut items = &self.items;
        let mut current: Option<&Item> = None;
        let mut walked = String::new();
        for segment in path.split('/').map(str::trim).filter(|s| !s.is_empty()) {
            let titled: Vec<&Item> = items
                .iter()
                .filter(|entry| entry.title.eq_ignore_ascii_case(segment))
                .collect();
            let entry = match titled.as_slice() {
                [entry] => *entry,
                [] => {
                    let index: usize = segment.parse().ok().filter(|n| *n >= 1 && *n <= items.len())
                        .with_context(|| format!("no menu entry at {walked}/{segment}"))?;
                    &items[index - 1]
                }
                many => bail!(
                    "{segment:?} is ambiguous in the menu ({} entries under {walked})",
                    many.len()
                ),
            };
            walked.push('/');
            walked.push_str(&entry.title);
            current = Some(entry);
            items = &entry.items;
        }
        current.with_context(|| format!("menu path {path:?} selects nothing"))
    }
}

impl Item {
    /// Play decision: the local download cache when a copy exists, the far end
    /// otherwise.
    pub fn source(&self) -> Result<Source> {
        if let Some(path) = &self.local {
            if path.exists() {
                return Ok(Source::Local(path.clone()));
            }
        }
        if let Some(url) = &self.remote {
            return Ok(Source::Remote(url.clone()));
        }
        match &self.local {
            Some(path) => bail!("{} has no cached copy at {}", self.title, path.display()),
            None => bail!("{} names no playable source", self.title),
        }
    }
}

/// One outline entry from its tag: `text`/`title` label, `url`/`xmlUrl` source,
/// optional `cache` copy; paths resolve against the OPML file's folder.
fn item(tag: &BytesStart, base: &Path) -> Result<Item> {
    let mut text = String::new();
    let mut title = String::new();
    let mut url = None;
    let mut xml_url = None;
    let mut cache = None;
    for attribute in tag.attributes() {
        let attribute = attribute.with_context(|| "read OPML attribute")?;
        let value = attribute
            .normalized_value(XmlVersion::Implicit1_0)
            .with_context(|| "decode OPML attribute")?
            .trim()
            .to_owned();
        match attribute.key.as_ref() {
            "text" => text = value,
            "title" => title = value,
            "url" => url = Some(value),
            "xmlUrl" => xml_url = Some(value),
            "cache" => cache = Some(base.join(value)),
            _ => {}
        }
    }
    // `text` labels, `url` plays; the alternates fill in when absent.
    let title = if text.is_empty() { title } else { text };
    let (remote, local) = match url.or(xml_url) {
        Some(source) if source.contains("://") => (Some(source), cache),
        Some(source) => (None, Some(cache.unwrap_or_else(|| base.join(source)))),
        None => (None, cache),
    };
    Ok(Item {
        title,
        remote,
        local,
        items: Vec::new(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<opml version="2.0">
  <head><title>Talk radio &amp; friends</title></head>
  <body>
    <outline text="News">
      <outline text="Morning Briefing" type="audio" url="https://example.com/morning.m3u8" cache="cache/morning.wav" />
      <outline title="Evening Report" url="cache/evening.wav"></outline>
    </outline>
    <outline text="Tech" xmlUrl="https://example.com/tech.m3u8" />
  </body>
</opml>"#;

    fn menu() -> Menu {
        Menu::parse(FIXTURE, Path::new("/shows")).expect("parse")
    }

    #[test]
    fn parses_nested_outlines_and_sources() {
        let menu = menu();
        assert_eq!(menu.items.len(), 2);
        let news = &menu.items[0];
        assert_eq!(news.title, "News");
        assert_eq!(news.remote, None);
        assert_eq!(news.items.len(), 2);
        let briefing = &news.items[0];
        assert_eq!(briefing.title, "Morning Briefing");
        assert_eq!(briefing.remote.as_deref(), Some("https://example.com/morning.m3u8"));
        assert_eq!(briefing.local, Some(PathBuf::from("/shows/cache/morning.wav")));
        // `title` labels when `text` is absent; a bare path is local.
        let evening = &news.items[1];
        assert_eq!(evening.title, "Evening Report");
        assert_eq!(evening.remote, None);
        assert_eq!(evening.local, Some(PathBuf::from("/shows/cache/evening.wav")));
        // `xmlUrl` plays when `url` is absent; a scheme means the far end.
        let tech = &menu.items[1];
        assert_eq!(tech.title, "Tech");
        assert_eq!(tech.remote.as_deref(), Some("https://example.com/tech.m3u8"));
        assert_eq!(tech.local, None);
    }

    #[test]
    fn resolves_paths_by_title_or_index() {
        let menu = menu();
        assert_eq!(menu.resolve("News/Morning Briefing").unwrap().title, "Morning Briefing");
        assert_eq!(menu.resolve("news/2").unwrap().title, "Evening Report");
        assert_eq!(menu.resolve("1/1").unwrap().title, "Morning Briefing");
        assert_eq!(menu.resolve("Tech").unwrap().title, "Tech");
    }

    #[test]
    fn refuses_bad_paths_cleanly() {
        let menu = menu();
        assert!(format!("{}", menu.resolve("Nope").unwrap_err()).contains("no menu entry"));
        assert!(format!("{}", menu.resolve("").unwrap_err()).contains("selects nothing"));
        assert!(format!("{}", menu.resolve("News/3").unwrap_err()).contains("no menu entry"));
        let ambiguous = r#"<opml><body>
            <outline text="Same" url="a.wav" /><outline text="same" url="b.wav" />
        </body></opml>"#;
        let menu = Menu::parse(ambiguous, Path::new(".")).expect("parse");
        assert!(format!("{}", menu.resolve("same").unwrap_err()).contains("ambiguous"));
    }

    #[test]
    fn picks_the_cache_when_it_exists_and_the_far_end_otherwise() {
        let dir = std::env::temp_dir().join(format!("idfon-menu-source-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let cached = dir.join("morning.wav");
        std::fs::write(&cached, b"clip").expect("clip");

        let item = Item {
            title: "Morning".into(),
            remote: Some("https://example.com/morning.m3u8".into()),
            local: Some(cached.clone()),
            items: Vec::new(),
        };
        assert_eq!(item.source().unwrap(), Source::Local(cached));
        // Cache gone: the far end serves it.
        let item = Item { local: Some(dir.join("gone.wav")), ..item };
        assert_eq!(item.source().unwrap(), Source::Remote("https://example.com/morning.m3u8".into()));
        // Cache-only and gone: nothing plays.
        let item = Item { remote: None, ..item };
        assert!(format!("{}", item.source().unwrap_err()).contains("no cached copy"));
        // No source at all.
        let item = Item { local: None, ..item };
        assert!(format!("{}", item.source().unwrap_err()).contains("no playable source"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn rejects_unterminated_outlines() {
        let error = Menu::parse(r#"<opml><body><outline text="News">"#, Path::new("."))
            .expect_err("unterminated");
        assert!(format!("{error}").contains("unterminated"));
    }
}
