//! File-type icons, VS Code Explorer style, using the Material theme:
//! Nerd Font glyphs matching
//! [vscode-material-icon-theme](https://github.com/material-extensions/vscode-material-icon-theme)
//! via the nvim-material-icon mapping.
//!
//! Classification happens once (`Kind`). Folders use vscode-material folder
//! names (src, node_modules, .github, …). Emoji drawing remains as a fallback
//! for tests and terminals without a Nerd Font, but it is not a user option.

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum IconTheme {
    Emoji,
    Material,
}

impl IconTheme {
    /// Explicit theme from `HERDR_SIDEBAR_ICONS` (legacy `HERDR_AA_*_ICONS`
    /// still honored); `None` when unset/unknown so resolution can fall
    /// through to the persisted choice and then Material.
    pub fn from_env(value: Option<&str>) -> Option<Self> {
        match value.map(|v| v.trim().to_lowercase()).as_deref() {
            Some("emoji") => Some(Self::Emoji),
            Some("material") => Some(Self::Material),
            _ => None,
        }
    }

    /// Always Material. Env and persisted emoji choices are ignored.
    pub fn resolve(_env: Option<&str>, _persisted: Option<Self>) -> Self {
        Self::Material
    }

    pub fn from_state_name(name: &str) -> Option<Self> {
        match name {
            "emoji" => Some(Self::Emoji),
            "material" => Some(Self::Material),
            _ => None,
        }
    }

    pub fn state_name(self) -> &'static str {
        match self {
            Self::Emoji => "emoji",
            Self::Material => "material",
        }
    }
}

/// Nerd Fonts register under several spellings: the DirectWrite family
/// ("CaskaydiaCove Nerd Font"), the GDI abbreviation Windows' font registry
/// actually stores ("CaskaydiaCove NF (TrueType)" — bit us live), and the
/// space-less filenames ("CaskaydiaCoveNerdFont-Regular.ttf").
fn output_mentions_nerd_font(text: &str) -> bool {
    let t = text.to_lowercase();
    t.contains("nerd font") || t.contains("nerdfont") || t.contains(" nf ")
}

/// Best-effort "is any Nerd Font installed" probe, cached. Windows: the two
/// font registries; elsewhere: `fc-list`. Installed is not the same as
/// selected in the terminal profile, but it is the strongest hint a TUI can
/// get, and the safe default for machines without one is what matters.
pub fn nerd_font_installed() -> bool {
    use std::sync::OnceLock;
    static PROBE: OnceLock<bool> = OnceLock::new();
    *PROBE.get_or_init(probe_nerd_font)
}

/// One UNCACHED probe pass — [`nerd_font_installed`] caches it for the
/// session; the first-run font prompt re-runs it after an install to
/// confirm the registration actually took.
pub fn probe_nerd_font() -> bool {
    #[cfg(windows)]
    {
        let keys = [
            r"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts",
            r"HKCU\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts",
        ];
        keys.iter().any(|key| {
            std::process::Command::new("reg")
                .args(["query", key])
                .output()
                .map(|out| output_mentions_nerd_font(&String::from_utf8_lossy(&out.stdout)))
                .unwrap_or(false)
        })
    }
    #[cfg(not(windows))]
    {
        std::process::Command::new("fc-list")
            .output()
            .map(|out| output_mentions_nerd_font(&String::from_utf8_lossy(&out.stdout)))
            .unwrap_or(false)
    }
}

/// A renderable icon: the glyph plus an optional foreground color. Emoji carry
/// their own colors (`None`); material glyphs are tinted like Atom Material.
pub struct Icon {
    pub glyph: &'static str,
    pub rgb: Option<(u8, u8, u8)>,
}

pub fn icon(theme: IconTheme, name: &str, is_dir: bool, expanded: bool) -> Icon {
    if is_dir {
        return match theme {
            IconTheme::Emoji => Icon {
                glyph: if expanded { "📂" } else { "📁" },
                rgb: None,
            },
            IconTheme::Material => material_folder(name, expanded),
        };
    }
    let kind = kind_of(name);
    match theme {
        IconTheme::Emoji => Icon {
            glyph: emoji(kind),
            rgb: None,
        },
        IconTheme::Material => {
            let (glyph, rgb) = material(kind);
            Icon {
                glyph,
                rgb: Some(rgb),
            }
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Kind {
    Rust,
    Python,
    Js,
    Ts,
    React,
    Vue,
    Svelte,
    Json,
    Markdown,
    Html,
    Css,
    Scss,
    Config,
    Toml,
    Yaml,
    Xml,
    Shell,
    PowerShell,
    CFamily,
    CSharp,
    Go,
    Ruby,
    Php,
    Java,
    Kotlin,
    Swift,
    Lua,
    Sql,
    Data,
    Text,
    Log,
    Pdf,
    Image,
    Svg,
    Audio,
    Video,
    Archive,
    Lock,
    Binary,
    Font,
    Notebook,
    Git,
    Docker,
    Package,
    Build,
    Readme,
    License,
    EnvKey,
    Zig,
    Nix,
    Graphql,
    Prisma,
    Terraform,
    File,
}

fn kind_of(name: &str) -> Kind {
    let lower = name.to_lowercase();
    if let Some(kind) = special_name(&lower) {
        return kind;
    }
    match lower.rsplit_once('.').map(|(_, ext)| ext) {
        Some(ext) => extension_kind(ext),
        None => Kind::File,
    }
}

/// Whole-filename matches take priority over the extension.
fn special_name(lower: &str) -> Option<Kind> {
    let kind = match lower {
        "cargo.lock" | "package-lock.json" | "yarn.lock" | "pnpm-lock.yaml" => Kind::Lock,
        "cargo.toml" | "package.json" | "pyproject.toml" | "go.mod" | "gemfile" => Kind::Package,
        "makefile" | "justfile" | "cmakelists.txt" => Kind::Build,
        ".gitignore" | ".gitattributes" | ".gitmodules" => Kind::Git,
        _ if lower.starts_with("dockerfile") || lower.starts_with("docker-compose") => Kind::Docker,
        _ if lower.starts_with("readme") => Kind::Readme,
        _ if lower.starts_with("license") || lower == "copying" => Kind::License,
        _ if lower == ".env" || lower.starts_with(".env.") => Kind::EnvKey,
        _ => return None,
    };
    Some(kind)
}

fn extension_kind(ext: &str) -> Kind {
    match ext {
        "rs" => Kind::Rust,
        "py" | "pyi" => Kind::Python,
        "js" | "mjs" | "cjs" => Kind::Js,
        "ts" => Kind::Ts,
        "jsx" | "tsx" => Kind::React,
        "json" | "jsonc" => Kind::Json,
        "md" | "markdown" => Kind::Markdown,
        "html" | "htm" => Kind::Html,
        "css" => Kind::Css,
        "scss" | "sass" | "less" => Kind::Scss,
        "toml" => Kind::Toml,
        "yaml" | "yml" => Kind::Yaml,
        "ini" | "cfg" | "conf" => Kind::Config,
        "xml" => Kind::Xml,
        "sh" | "bash" | "zsh" | "fish" => Kind::Shell,
        "ps1" | "psm1" | "psd1" | "bat" | "cmd" => Kind::PowerShell,
        "c" | "h" | "cpp" | "cc" | "cxx" | "hpp" | "hh" => Kind::CFamily,
        "cs" => Kind::CSharp,
        "go" => Kind::Go,
        "rb" => Kind::Ruby,
        "php" => Kind::Php,
        "java" | "jar" => Kind::Java,
        "kt" | "kts" => Kind::Kotlin,
        "swift" => Kind::Swift,
        "lua" => Kind::Lua,
        "sql" | "db" | "sqlite" | "sqlite3" => Kind::Sql,
        "csv" | "tsv" => Kind::Data,
        "txt" => Kind::Text,
        "log" => Kind::Log,
        "pdf" => Kind::Pdf,
        "svg" => Kind::Svg,
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "bmp" | "ico" | "tiff" => Kind::Image,
        "mp3" | "wav" | "flac" | "ogg" => Kind::Audio,
        "mp4" | "mkv" | "avi" | "mov" | "webm" => Kind::Video,
        "zip" | "tar" | "gz" | "tgz" | "bz2" | "xz" | "7z" | "rar" => Kind::Archive,
        "lock" => Kind::Lock,
        "exe" | "dll" | "so" | "dylib" | "a" | "o" | "bin" | "wasm" => Kind::Binary,
        "ttf" | "otf" | "woff" | "woff2" => Kind::Font,
        "ipynb" => Kind::Notebook,
        "vue" => Kind::Vue,
        "svelte" => Kind::Svelte,
        "zig" => Kind::Zig,
        "nix" => Kind::Nix,
        "graphql" | "gql" => Kind::Graphql,
        "prisma" => Kind::Prisma,
        "tf" | "tfvars" | "hcl" => Kind::Terraform,
        _ => Kind::File,
    }
}

fn emoji(kind: Kind) -> &'static str {
    match kind {
        Kind::Rust => "🦀",
        Kind::Python => "🐍",
        Kind::Js => "🟨",
        Kind::Ts => "🔷",
        Kind::React => "🟦",
        Kind::Vue => "🟩",
        Kind::Svelte => "🟧",
        Kind::Json => "🧾",
        Kind::Markdown => "📝",
        Kind::Html => "🌐",
        Kind::Css | Kind::Scss => "🎨",
        Kind::Config | Kind::Toml | Kind::Yaml => "🔧",
        Kind::Xml => "📰",
        Kind::Shell => "🐚",
        Kind::PowerShell => "💻",
        Kind::CFamily => "🔩",
        Kind::CSharp => "🟣",
        Kind::Go => "🐹",
        Kind::Ruby => "💎",
        Kind::Php => "🐘",
        Kind::Java => "☕",
        Kind::Kotlin => "🟪",
        Kind::Swift => "🐦",
        Kind::Lua => "🌙",
        Kind::Sql => "💾",
        Kind::Data => "📊",
        Kind::Text => "📄",
        Kind::Log => "📋",
        Kind::Pdf => "📕",
        Kind::Image | Kind::Svg => "📷",
        Kind::Audio => "🎵",
        Kind::Video => "🎬",
        Kind::Archive => "🧳",
        Kind::Lock => "🔒",
        Kind::Binary => "⚡",
        Kind::Font => "🔤",
        Kind::Notebook => "📓",
        Kind::Git => "🙈",
        Kind::Docker => "🐳",
        Kind::Package => "📦",
        Kind::Build => "🔨",
        Kind::Readme => "📖",
        Kind::License => "📜",
        Kind::EnvKey => "🔑",
        Kind::Zig => "⚡",
        Kind::Nix => "❄",
        Kind::Graphql => "◈",
        Kind::Prisma => "△",
        Kind::Terraform => "💠",
        Kind::File => "📄",
    }
}

/// Nerd Font glyph + vscode-material-icon-theme color per kind. Codepoints
/// follow nvim-material-icon (the Nerd Font port of that VS Code theme).
fn material(kind: Kind) -> (&'static str, (u8, u8, u8)) {
    match kind {
        Kind::Rust => ("\u{e68b}", (0xff, 0x70, 0x43)),
        Kind::Python => ("\u{ed1b}", (0x3a, 0x87, 0xcb)),
        Kind::Js => ("\u{f031e}", (0xff, 0xca, 0x29)),
        Kind::Ts => ("\u{f06e6}", (0x01, 0x88, 0xd1)),
        Kind::React => ("\u{ed46}", (0x04, 0xbc, 0xd4)),
        Kind::Vue => ("\u{e6a0}", (0x40, 0xb8, 0x83)),
        Kind::Svelte => ("\u{e697}", (0xff, 0x58, 0x21)),
        Kind::Json => ("\u{e60b}", (0xfa, 0xa8, 0x25)),
        Kind::Markdown => ("\u{eb1d}", (0x42, 0xa5, 0xf5)),
        Kind::Html => ("\u{f13b}", (0xe4, 0x4e, 0x27)),
        Kind::Css => ("\u{e749}", (0x42, 0xa5, 0xf5)),
        Kind::Scss => ("\u{e603}", (0xec, 0x41, 0x7a)),
        Kind::Config => ("\u{e615}", (0x6d, 0x80, 0x86)),
        Kind::Toml => ("\u{e6b2}", (0xef, 0x53, 0x51)),
        Kind::Yaml => ("\u{f0219}", (0xff, 0x52, 0x52)),
        Kind::Xml => ("\u{f022e}", (0x8b, 0xc3, 0x4a)),
        Kind::Shell => ("\u{f018d}", (0xff, 0x70, 0x43)),
        Kind::PowerShell => ("\u{f0a0a}", (0x53, 0x91, 0xfe)),
        Kind::CFamily => ("\u{e649}", (0x01, 0x88, 0xd1)),
        Kind::CSharp => ("\u{f031b}", (0x01, 0x88, 0xd1)),
        Kind::Go => ("\u{f07d3}", (0x02, 0xac, 0xc1)),
        Kind::Ruby => ("\u{f0d2d}", (0xf5, 0x44, 0x36)),
        Kind::Php => ("\u{f031f}", (0x20, 0x88, 0xe5)),
        Kind::Java => ("\u{f0f4}", (0xf5, 0x44, 0x36)),
        Kind::Kotlin => ("\u{e634}", (0x1a, 0x95, 0xd9)),
        Kind::Swift => ("\u{f06e5}", (0xfe, 0x5e, 0x2f)),
        Kind::Lua => ("\u{e620}", (0x42, 0xa5, 0xf5)),
        Kind::Sql => ("\u{f1c0}", (0xff, 0xca, 0x29)),
        Kind::Data => ("\u{f1c3}", (0x33, 0xa8, 0x52)),
        Kind::Text => ("\u{f15c}", (0x9e, 0x9e, 0x9e)),
        Kind::Log => ("\u{f15c}", (0x75, 0x75, 0x75)),
        Kind::Pdf => ("\u{f1c1}", (0xef, 0x53, 0x51)),
        Kind::Image => ("\u{f021f}", (0x25, 0xa6, 0xa0)),
        Kind::Svg => ("\u{f0721}", (0xff, 0xb3, 0x00)),
        Kind::Audio => ("\u{f1c7}", (0xec, 0x40, 0x7a)),
        Kind::Video => ("\u{f1c8}", (0xff, 0x70, 0x43)),
        Kind::Archive => ("\u{f05c4}", (0xaf, 0xb4, 0x2b)),
        Kind::Lock => ("\u{f023}", (0xff, 0xd5, 0x50)),
        Kind::Binary => ("\u{f471}", (0xef, 0x53, 0x50)),
        Kind::Font => ("\u{f031}", (0xb0, 0xbe, 0xc5)),
        Kind::Notebook => ("\u{f082e}", (0xf5, 0x7d, 0x01)),
        Kind::Git => ("\u{e702}", (0xf1, 0x4e, 0x32)),
        Kind::Docker => ("\u{f308}", (0x0d, 0xb7, 0xed)),
        Kind::Package => ("\u{f487}", (0x8d, 0x6e, 0x63)),
        Kind::Build => ("\u{f0ad}", (0x6d, 0x80, 0x86)),
        Kind::Readme => ("\u{f02d}", (0x42, 0xa5, 0xf5)),
        Kind::License => ("\u{f24e}", (0xff, 0xd5, 0x4f)),
        Kind::EnvKey => ("\u{f084}", (0xff, 0xd5, 0x4f)),
        Kind::Zig => ("\u{e6a9}", (0xfa, 0xa8, 0x25)),
        Kind::Nix => ("\u{f313}", (0x51, 0x75, 0xc2)),
        Kind::Graphql => ("\u{f0877}", (0xec, 0x41, 0x7a)),
        Kind::Prisma => ("\u{e684}", (0x00, 0xbf, 0xa5)),
        Kind::Terraform => ("\u{e69a}", (0x5d, 0x6b, 0xc0)),
        Kind::File => ("\u{f15b}", (0x90, 0xa4, 0xae)),
    }
}

/// vscode-material-icon-theme folder names: leading-dot matches `.github` as
/// `github`. Named folders keep a tinted folder (or a brand glyph); unknown
/// names use the generic closed/open Material folder.
fn material_folder(name: &str, expanded: bool) -> Icon {
    let lower = name.to_lowercase();
    let key = lower.strip_prefix('.').unwrap_or(lower.as_str());
    let generic = if expanded {
        "\u{f0770}" // nf-md-folder-open
    } else {
        "\u{f024b}" // nf-md-folder
    };
    let grey = (0x90_u8, 0xa4, 0xae);
    let (glyph, rgb) = match key {
        "src" | "srcs" | "source" | "sources" | "code" => (generic, (0x26, 0xa6, 0x9a)),
        "dist" | "out" | "output" | "outputs" | "build" | "builds" | "release" | "bin"
        | "distribution" | "built" | "compiled" | "target" => (generic, (0xf9, 0xa8, 0x25)),
        "node" | "nodejs" | "node_modules" => ("\u{e718}", (0x8b, 0xc3, 0x4a)),
        "git" | "patches" | "githooks" | "submodules" => ("\u{e5fb}", (0xe5, 0x39, 0x35)),
        "github" => ("\u{f408}", (0x54, 0x6e, 0x7a)),
        "gitlab" => ("\u{f296}", (0xfc, 0x6d, 0x26)),
        "test" | "tests" | "testing" | "spec" | "specs" | "__tests__" | "__test__"
        | "snapshots" => (generic, (0x26, 0xa6, 0x9a)),
        "doc" | "docs" | "document" | "documents" | "documentation" | "wiki" | "notes" => {
            (generic, (0x42, 0xa5, 0xf5))
        }
        "cfg" | "cfgs" | "conf" | "confs" | "config" | "configs" | "configuration"
        | "configurations" | "setting" | "settings" => (generic, (0xff, 0xcc, 0x80)),
        "images" | "image" | "imgs" | "img" | "icons" | "icon" | "assets" | "pictures"
        | "photos" => (generic, (0x26, 0xa6, 0x9a)),
        "public" | "www" | "static" | "html" | "public_html" => (generic, (0x26, 0xc6, 0xda)),
        "script" | "scripts" | "scripting" => (generic, (0xff, 0xca, 0x28)),
        "lib" | "libs" | "library" | "libraries" | "include" | "includes" => {
            (generic, (0x8d, 0x6e, 0x63))
        }
        "vendor" | "vendors" | "third-party" | "third_party" => (generic, (0xbd, 0xbd, 0xbd)),
        "tmp" | "temp" | "cache" | "cached" => (generic, (0x78, 0x90, 0x9c)),
        "ci" | "circleci" | ".circleci" | "workflows" => (generic, (0xf4, 0x43, 0x36)),
        "app" | "apps" | "application" | "applications" => (generic, (0x26, 0xa6, 0x9a)),
        "package" | "packages" | "pkg" => (generic, (0x8d, 0x6e, 0x63)),
        "component" | "components" | "widget" | "widgets" => (generic, (0x42, 0xa5, 0xf5)),
        "hook" | "hooks" => (generic, (0x7e, 0x57, 0xc2)),
        "css" | "stylesheet" | "stylesheets" | "style" | "styles" | "sass" | "scss" => {
            (generic, (0xec, 0x40, 0x7a))
        }
        "vscode" | "vscode-test" => ("\u{e70c}", (0x29, 0xb6, 0xf6)),
        "docker" | "dockerfiles" | "dockerhub" => ("\u{f308}", (0x00, 0x83, 0x8f)),
        "android" => ("\u{e70e}", (0x8b, 0xc3, 0x4a)),
        "ios" => ("\u{e711}", (0x54, 0x6e, 0x7a)),
        "font" | "fonts" | "typeface" | "typefaces" => (generic, (0xb0, 0xbe, 0xc5)),
        "locale" | "locales" | "i18n" | "l10n" | "lang" | "langs" | "translation"
        | "translations" => (generic, (0x79, 0x86, 0xcb)),
        "log" | "logs" => (generic, (0x78, 0x90, 0x9c)),
        "plugin" | "plugins" | "mod" | "mods" | "extension" | "extensions" => {
            (generic, (0x7e, 0x57, 0xc2))
        }
        "env" | "envs" | "environment" | "environments" => (generic, (0xff, 0xcc, 0x80)),
        "rust" | "cargo" => ("\u{e68b}", (0xff, 0x70, 0x43)),
        "view" | "views" | "screen" | "screens" | "page" | "pages" => (generic, (0x42, 0xa5, 0xf5)),
        "prisma" => ("\u{e684}", (0x2d, 0x37, 0x48)),
        "nix" => ("\u{f313}", (0x51, 0x75, 0xc2)),
        _ => (generic, grey),
    };
    Icon {
        glyph,
        rgb: Some(rgb),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn emoji_for(name: &str, is_dir: bool, expanded: bool) -> &'static str {
        icon(IconTheme::Emoji, name, is_dir, expanded).glyph
    }

    #[test]
    fn directories_reflect_expansion() {
        assert_eq!(emoji_for("src", true, false), "📁");
        assert_eq!(emoji_for("src", true, true), "📂");
    }

    #[test]
    fn special_names_beat_extensions() {
        assert_eq!(emoji_for("Cargo.toml", false, false), "📦");
        assert_eq!(emoji_for("Cargo.lock", false, false), "🔒");
        assert_eq!(emoji_for("README.md", false, false), "📖");
        assert_eq!(emoji_for("Dockerfile", false, false), "🐳");
        assert_eq!(emoji_for(".gitignore", false, false), "🙈");
        assert_eq!(emoji_for(".env.local", false, false), "🔑");
    }

    #[test]
    fn extensions_are_case_insensitive() {
        assert_eq!(emoji_for("MAIN.RS", false, false), "🦀");
        assert_eq!(emoji_for("photo.JPG", false, false), "📷");
    }

    #[test]
    fn unknown_and_extensionless_fall_back_to_file() {
        assert_eq!(emoji_for("data.xyzq", false, false), "📄");
        assert_eq!(emoji_for("CNAME", false, false), "📄");
    }

    #[test]
    fn material_theme_tints_glyphs() {
        let rust = icon(IconTheme::Material, "main.rs", false, false);
        assert_eq!(rust.glyph, "\u{e68b}");
        assert_eq!(rust.rgb, Some((0xff, 0x70, 0x43)));
        assert!(
            icon(IconTheme::Emoji, "main.rs", false, false)
                .rgb
                .is_none()
        );
    }

    #[test]
    fn material_folders_match_vscode_names() {
        let src = icon(IconTheme::Material, "src", true, false);
        assert_eq!(src.glyph, "\u{f024b}");
        assert_eq!(src.rgb, Some((0x26, 0xa6, 0x9a)));
        let github = icon(IconTheme::Material, ".github", true, false);
        assert_eq!(github.glyph, "\u{f408}");
        let node = icon(IconTheme::Material, "node_modules", true, false);
        assert_eq!(node.glyph, "\u{e718}");
        let open = icon(IconTheme::Material, "misc", true, true);
        assert_eq!(open.glyph, "\u{f0770}");
        assert_eq!(icon(IconTheme::Emoji, "src", true, false).glyph, "📁");
    }

    #[test]
    fn extra_extensions_match_material_icon_theme() {
        assert_eq!(
            icon(IconTheme::Material, "App.vue", false, false).glyph,
            "\u{e6a0}"
        );
        assert_eq!(
            icon(IconTheme::Material, "Widget.svelte", false, false).glyph,
            "\u{e697}"
        );
        assert_eq!(
            icon(IconTheme::Material, "schema.prisma", false, false).glyph,
            "\u{e684}"
        );
    }

    #[test]
    fn nerd_font_spellings_all_match() {
        assert!(output_mentions_nerd_font(
            r"CaskaydiaCove NF Mono (TrueType)    REG_SZ    C:\x\CaskaydiaCoveNerdFontMono-Regular.ttf"
        ));
        assert!(output_mentions_nerd_font(
            "JetBrainsMono Nerd Font: style=Regular"
        ));
        assert!(output_mentions_nerd_font("FiraCode NF Retina (TrueType)"));
        assert!(!output_mentions_nerd_font(
            "Consolas (TrueType)  Segoe UI  Cascadia Mono"
        ));
    }

    #[test]
    fn theme_selection_is_always_material() {
        assert_eq!(IconTheme::from_env(None), None);
        assert_eq!(
            IconTheme::from_env(Some("material")),
            Some(IconTheme::Material)
        );
        assert_eq!(
            IconTheme::resolve(Some("emoji"), Some(IconTheme::Emoji)),
            IconTheme::Material
        );
        assert_eq!(
            IconTheme::resolve(None, Some(IconTheme::Emoji)),
            IconTheme::Material
        );
        assert_eq!(IconTheme::resolve(None, None), IconTheme::Material);
    }
}
