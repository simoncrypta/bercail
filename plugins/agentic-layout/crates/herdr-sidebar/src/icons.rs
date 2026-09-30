//! File-type icons, VS Code Explorer style, using the Pierre theme: the
//! file-name/extension mapping and palette of
//! [Pierre Icons for VS Code](https://github.com/pierrecomputer/vscode-icons)
//! ("Complete" tier), drawn with the closest Nerd Font glyph.
//!
//! Pierre keeps the tree quiet: folders, documents, data, and generic files
//! are gray; only languages, frameworks, and tooling get a palette hue.
//! Classification happens once (`Kind`). Emoji drawing remains as a fallback
//! for tests and terminals without a Nerd Font, but it is not a user option.

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum IconTheme {
    Emoji,
    Pierre,
}

impl IconTheme {
    /// Explicit theme from `HERDR_SIDEBAR_ICONS` (legacy `HERDR_AA_*_ICONS`
    /// still honored); `None` when unset/unknown so resolution can fall
    /// through to the persisted choice and then Pierre. `material` is the
    /// pre-Pierre name and still maps to the glyph theme.
    pub fn from_env(value: Option<&str>) -> Option<Self> {
        match value.map(|v| v.trim().to_lowercase()).as_deref() {
            Some("emoji") => Some(Self::Emoji),
            Some("pierre" | "material") => Some(Self::Pierre),
            _ => None,
        }
    }

    /// Always Pierre. Env and persisted emoji choices are ignored.
    pub fn resolve(_env: Option<&str>, _persisted: Option<Self>) -> Self {
        Self::Pierre
    }

    pub fn from_state_name(name: &str) -> Option<Self> {
        match name {
            "emoji" => Some(Self::Emoji),
            "pierre" | "material" => Some(Self::Pierre),
            _ => None,
        }
    }

    pub fn state_name(self) -> &'static str {
        match self {
            Self::Emoji => "emoji",
            Self::Pierre => "pierre",
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
/// their own colors (`None`); Pierre glyphs are tinted from its palette.
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
            IconTheme::Pierre => pierre_folder(expanded),
        };
    }
    let kind = kind_of(name);
    match theme {
        IconTheme::Emoji => Icon {
            glyph: emoji(kind),
            rgb: None,
        },
        IconTheme::Pierre => {
            let (glyph, rgb) = pierre(kind);
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
    Astro,
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
    C,
    Cpp,
    CSharp,
    ObjC,
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
    Wasm,
    Npm,
    Bun,
    Eslint,
    Prettier,
    Stylelint,
    Biome,
    Babel,
    Vite,
    Webpack,
    PostCss,
    Svgo,
    Tailwind,
    Nextjs,
    Claude,
    VsCode,
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

/// Whole-filename matches take priority over the extension. Tooling configs
/// match by prefix (`vite.config.*`, `.eslintrc*`) so every flavor Pierre
/// lists — and the ones it doesn't yet — resolve the same way.
fn special_name(lower: &str) -> Option<Kind> {
    let starts = |prefixes: &[&str]| prefixes.iter().any(|p| lower.starts_with(p));
    let kind = match lower {
        "claude.md" | "claude.local.md" => Kind::Claude,
        "package.json" | "package-lock.json" | ".npmrc" | ".npmignore" => Kind::Npm,
        "bun.lock" | "bun.lockb" | "bunfig.toml" => Kind::Bun,
        "cargo.lock" | "yarn.lock" | "pnpm-lock.yaml" | "composer.lock" | "gemfile.lock" => {
            Kind::Lock
        }
        "cargo.toml" | "pyproject.toml" | "go.mod" => Kind::Package,
        "gemfile" | "rakefile" => Kind::Ruby,
        "makefile" | "justfile" | "cmakelists.txt" => Kind::Build,
        ".gitignore" | ".gitattributes" | ".gitmodules" | ".gitkeep" => Kind::Git,
        ".dockerignore" | "compose.yml" | "compose.yaml" => Kind::Docker,
        ".terraform.lock.hcl" => Kind::Terraform,
        ".bashrc" | ".bash_profile" | ".zshrc" | ".zshenv" | ".zprofile" => Kind::Shell,
        ".browserslistrc" => Kind::Config,
        _ if starts(&["dockerfile", "docker-compose"]) => Kind::Docker,
        _ if starts(&[".eslintrc", "eslint.config.", ".eslintignore"]) => Kind::Eslint,
        _ if starts(&[".prettierrc", "prettier.config.", ".prettierignore"]) => Kind::Prettier,
        _ if starts(&[".stylelintrc", "stylelint.config.", ".stylelintignore"]) => Kind::Stylelint,
        _ if starts(&["biome.json"]) => Kind::Biome,
        _ if starts(&[".babelrc", "babel.config."]) => Kind::Babel,
        _ if starts(&["vite.config.", "vitest.config."]) => Kind::Vite,
        _ if starts(&["webpack.config."]) => Kind::Webpack,
        _ if starts(&["postcss.config.", ".postcssrc"]) => Kind::PostCss,
        _ if starts(&["svgo.config."]) => Kind::Svgo,
        _ if starts(&["tailwind.config."]) => Kind::Tailwind,
        _ if starts(&["next.config."]) => Kind::Nextjs,
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
        "py" | "pyi" | "pyw" | "pyx" => Kind::Python,
        "js" | "mjs" | "cjs" => Kind::Js,
        "ts" | "mts" | "cts" => Kind::Ts,
        "jsx" | "tsx" => Kind::React,
        "json" | "jsonc" | "json5" | "jsonl" => Kind::Json,
        "md" | "mdx" | "markdown" => Kind::Markdown,
        "html" | "htm" | "xhtml" => Kind::Html,
        "css" | "less" | "postcss" | "styl" => Kind::Css,
        "scss" | "sass" => Kind::Scss,
        "toml" => Kind::Toml,
        "yaml" | "yml" => Kind::Yaml,
        "ini" | "cfg" | "conf" | "editorconfig" => Kind::Config,
        "xml" => Kind::Xml,
        "sh" | "bash" | "zsh" | "fish" | "ksh" | "csh" => Kind::Shell,
        "ps1" | "psm1" | "psd1" | "bat" | "cmd" => Kind::PowerShell,
        "c" | "h" => Kind::C,
        "cpp" | "cc" | "cxx" | "hpp" | "hh" | "hxx" | "inl" => Kind::Cpp,
        "cs" => Kind::CSharp,
        "m" | "mm" => Kind::ObjC,
        "go" => Kind::Go,
        "rb" | "erb" | "gemspec" | "rake" => Kind::Ruby,
        "php" => Kind::Php,
        "java" => Kind::Java,
        "kt" | "kts" => Kind::Kotlin,
        "swift" => Kind::Swift,
        "lua" => Kind::Lua,
        "sql" | "db" | "sqlite" | "sqlite3" => Kind::Sql,
        "csv" | "tsv" | "xls" | "xlsx" | "ods" => Kind::Data,
        "txt" | "rst" | "rtf" => Kind::Text,
        "log" => Kind::Log,
        "pdf" => Kind::Pdf,
        "svg" => Kind::Svg,
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "avif" | "bmp" | "ico" | "icns" | "tiff"
        | "tif" => Kind::Image,
        "mp3" | "wav" | "flac" | "ogg" => Kind::Audio,
        "mp4" | "mkv" | "avi" | "mov" | "webm" => Kind::Video,
        "zip" | "tar" | "gz" | "tgz" | "bz2" | "xz" | "7z" | "rar" | "jar" | "war" => Kind::Archive,
        "lock" => Kind::Lock,
        "exe" | "dll" | "so" | "dylib" | "a" | "o" | "bin" => Kind::Binary,
        "wasm" | "wat" | "wast" => Kind::Wasm,
        "ttf" | "otf" | "woff" | "woff2" | "eot" => Kind::Font,
        "ipynb" => Kind::Notebook,
        "vue" => Kind::Vue,
        "svelte" => Kind::Svelte,
        "astro" => Kind::Astro,
        "zig" => Kind::Zig,
        "nix" => Kind::Nix,
        "graphql" | "gql" => Kind::Graphql,
        "prisma" => Kind::Prisma,
        "tf" | "tfvars" | "tfstate" | "hcl" => Kind::Terraform,
        "code-workspace" => Kind::VsCode,
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
        Kind::Astro => "🚀",
        Kind::Json => "🧾",
        Kind::Markdown => "📝",
        Kind::Html => "🌐",
        Kind::Css | Kind::Scss | Kind::PostCss | Kind::Tailwind => "🎨",
        Kind::Config | Kind::Toml | Kind::Yaml => "🔧",
        Kind::Xml => "📰",
        Kind::Shell => "🐚",
        Kind::PowerShell => "💻",
        Kind::C | Kind::Cpp | Kind::ObjC => "🔩",
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
        Kind::Image | Kind::Svg | Kind::Svgo => "📷",
        Kind::Audio => "🎵",
        Kind::Video => "🎬",
        Kind::Archive => "🧳",
        Kind::Lock => "🔒",
        Kind::Binary | Kind::Wasm => "⚡",
        Kind::Font => "🔤",
        Kind::Notebook => "📓",
        Kind::Git => "🙈",
        Kind::Docker => "🐳",
        Kind::Package | Kind::Npm | Kind::Bun => "📦",
        Kind::Build | Kind::Vite | Kind::Webpack | Kind::Babel | Kind::Nextjs => "🔨",
        Kind::Eslint | Kind::Prettier | Kind::Stylelint | Kind::Biome => "🧹",
        Kind::Readme => "📖",
        Kind::License => "📜",
        Kind::EnvKey => "🔑",
        Kind::Zig => "⚡",
        Kind::Nix => "❄",
        Kind::Graphql => "◈",
        Kind::Prisma => "△",
        Kind::Terraform => "💠",
        Kind::Claude => "✳",
        Kind::VsCode => "💻",
        Kind::File => "📄",
    }
}

type Rgb = (u8, u8, u8);

/// Pierre palette (github.com/pierrecomputer/theme). Pierre ships level 400
/// for dark themes and 600 for light; the sidebar can't see the terminal
/// background, so each hue is the 400/600 midpoint, which reads on both.
/// Gray is Pierre's own 500.
const GRAY: Rgb = (0x8e, 0x8e, 0x95);
const RED: Rgb = (0xea, 0x4a, 0x4c);
const VERMILION: Rgb = (0xea, 0x6f, 0x45);
const ORANGE: Rgb = (0xea, 0x8d, 0x41);
const YELLOW: Rgb = (0xea, 0xbf, 0x31);
const GREEN: Rgb = (0x3c, 0xb6, 0x5a);
const TEAL: Rgb = (0x3e, 0xbb, 0xc5);
const CYAN: Rgb = (0x42, 0xb7, 0xdc);
const BLUE: Rgb = (0x42, 0x9b, 0xea);
const INDIGO: Rgb = (0x83, 0x52, 0xe5);
const PURPLE: Rgb = (0xbe, 0x4c, 0xd4);
const PINK: Rgb = (0xe9, 0x48, 0x77);
const BROWN: Rgb = (0xac, 0x81, 0x65);

/// Nerd Font glyph + Pierre color per kind. Colors follow Pierre's
/// "Complete" tier; kinds Pierre has no icon for keep a gray generic glyph
/// (or a brand glyph in the nearest palette hue for languages).
fn pierre(kind: Kind) -> (&'static str, Rgb) {
    match kind {
        Kind::Rust => ("\u{e68b}", ORANGE),                   // seti-rust
        Kind::Python => ("\u{ed1b}", BLUE),                   // fa-python
        Kind::Js => ("\u{f031e}", YELLOW),                    // md-language_javascript
        Kind::Ts => ("\u{f06e6}", BLUE),                      // md-language_typescript
        Kind::React => ("\u{ed46}", CYAN),                    // fa-react
        Kind::Vue => ("\u{e6a0}", GREEN),                     // seti-vue
        Kind::Svelte => ("\u{e697}", RED),                    // seti-svelte
        Kind::Astro => ("\u{e6b3}", PURPLE),                  // custom-astro
        Kind::Json => ("\u{f0169}", GRAY),                    // md-code_braces
        Kind::Markdown | Kind::Readme => ("\u{f0354}", GRAY), // md-language_markdown
        Kind::Html => ("\u{f031d}", ORANGE),                  // md-language_html5
        Kind::Css => ("\u{e749}", INDIGO),                    // dev-css3
        Kind::Scss => ("\u{e603}", PINK),                     // seti-sass
        Kind::Config => ("\u{e615}", GRAY),                   // seti-config
        Kind::Toml => ("\u{e6b2}", GRAY),                     // custom-toml
        Kind::Yaml => ("\u{e8eb}", RED),                      // dev-yaml
        Kind::Xml => ("\u{f022e}", GRAY),                     // md-file_code
        Kind::Shell => ("\u{f018d}", GRAY),                   // md-console
        Kind::PowerShell => ("\u{f0a0a}", BLUE),              // md-powershell
        Kind::C => ("\u{f0671}", BLUE),                       // md-language_c
        Kind::Cpp => ("\u{f0672}", BLUE),                     // md-language_cpp
        Kind::CSharp => ("\u{f031b}", PURPLE),                // md-language_csharp
        Kind::ObjC => ("\u{f0671}", VERMILION),               // md-language_c
        Kind::Go => ("\u{f07d3}", CYAN),                      // md-language_go
        Kind::Ruby => ("\u{f0d2d}", RED),                     // md-language_ruby
        Kind::Php => ("\u{f031f}", INDIGO),                   // md-language_php
        Kind::Java => ("\u{f0f4}", VERMILION),                // fa-coffee
        Kind::Kotlin => ("\u{e634}", PURPLE),                 // seti-kotlin
        Kind::Swift => ("\u{f06e5}", ORANGE),                 // md-language_swift
        Kind::Lua => ("\u{e620}", BLUE),                      // seti-lua
        Kind::Sql => ("\u{f01bc}", GRAY),                     // md-database
        Kind::Data => ("\u{f0c7e}", GRAY),                    // md-file_table
        Kind::Text | Kind::Log | Kind::License => ("\u{f0219}", GRAY), // md-file_document
        Kind::Pdf => ("\u{f1c1}", RED),                       // fa-file_pdf
        Kind::Image => ("\u{f021f}", GRAY),                   // md-file_image
        Kind::Svg => ("\u{f0721}", ORANGE),                   // md-svg
        Kind::Audio => ("\u{f1c7}", GRAY),                    // fa-file_audio
        Kind::Video => ("\u{f1c8}", GRAY),                    // fa-file_video
        Kind::Archive => ("\u{f05c4}", GRAY),                 // md-zip_box
        Kind::Lock => ("\u{f023}", GRAY),                     // fa-lock
        Kind::Binary => ("\u{f471}", GRAY),                   // oct-file_binary
        Kind::Font => ("\u{f06d6}", GRAY),                    // md-format_font
        Kind::Notebook => ("\u{f082e}", ORANGE),              // md-notebook
        Kind::Git => ("\u{e702}", VERMILION),                 // dev-git
        Kind::Docker => ("\u{f308}", BLUE),                   // linux-docker
        Kind::Package => ("\u{f487}", GRAY),                  // oct-package
        Kind::Build => ("\u{f0ad}", GRAY),                    // fa-wrench
        Kind::EnvKey => ("\u{f084}", GRAY),                   // fa-key
        Kind::Zig => ("\u{e6a9}", ORANGE),                    // seti-zig
        Kind::Nix => ("\u{f313}", BLUE),                      // linux-nixos
        Kind::Graphql => ("\u{f0877}", PINK),                 // md-graphql
        Kind::Prisma => ("\u{e684}", TEAL),                   // seti-prisma
        Kind::Terraform => ("\u{e69a}", INDIGO),              // seti-terraform
        Kind::Wasm => ("\u{e6a1}", INDIGO),                   // seti-wasm
        Kind::Npm => ("\u{f06f7}", RED),                      // md-npm
        Kind::Bun => ("\u{e76f}", BROWN),                     // dev-bun
        Kind::Eslint => ("\u{f0c7a}", INDIGO),                // md-eslint
        Kind::Prettier => ("\u{e6b4}", TEAL),                 // custom-prettier
        Kind::Stylelint => ("\u{e695}", GRAY),                // seti-stylelint
        Kind::Biome => ("\u{e8fb}", BLUE),                    // dev-biome
        Kind::Babel => ("\u{f0a25}", YELLOW),                 // md-babel
        Kind::Vite => ("\u{e8d6}", PURPLE),                   // dev-vite
        Kind::Webpack => ("\u{f072b}", BLUE),                 // md-webpack
        Kind::PostCss => ("\u{e86a}", RED),                   // dev-postcss
        Kind::Svgo => ("\u{e947}", GREEN),                    // dev-svgo
        Kind::Tailwind => ("\u{f13ff}", CYAN),                // md-tailwind
        Kind::Nextjs => ("\u{e83e}", GRAY),                   // dev-nextjs
        Kind::Claude => ("\u{ec82}", ORANGE),                 // cod-claude
        Kind::VsCode => ("\u{e8da}", BLUE),                   // dev-vscode
        Kind::File => ("\u{f0214}", GRAY),                    // md-file
    }
}

/// Pierre draws every folder the same: a gray closed/open folder, no
/// per-name tints or brand folders.
fn pierre_folder(expanded: bool) -> Icon {
    let glyph = if expanded {
        "\u{f0770}" // md-folder_open
    } else {
        "\u{f024b}" // md-folder
    };
    Icon {
        glyph,
        rgb: Some(GRAY),
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

    fn pierre(name: &str) -> Icon {
        icon(IconTheme::Pierre, name, false, false)
    }

    #[test]
    fn pierre_theme_tints_glyphs() {
        let rust = pierre("main.rs");
        assert_eq!(rust.glyph, "\u{e68b}");
        assert_eq!(rust.rgb, Some(ORANGE));
        assert!(
            icon(IconTheme::Emoji, "main.rs", false, false)
                .rgb
                .is_none()
        );
    }

    #[test]
    fn pierre_keeps_documents_and_data_gray() {
        for name in [
            "notes.txt",
            "README.md",
            "data.json",
            "table.csv",
            "font.woff2",
            "x.xyzq",
        ] {
            assert_eq!(pierre(name).rgb, Some(GRAY), "{name}");
        }
        assert_eq!(pierre("CNAME").glyph, "\u{f0214}");
    }

    #[test]
    fn pierre_folders_are_plain_gray() {
        for name in ["src", ".github", "node_modules", "misc"] {
            let closed = icon(IconTheme::Pierre, name, true, false);
            assert_eq!(closed.glyph, "\u{f024b}", "{name}");
            assert_eq!(closed.rgb, Some(GRAY), "{name}");
        }
        assert_eq!(
            icon(IconTheme::Pierre, "src", true, true).glyph,
            "\u{f0770}"
        );
        assert_eq!(icon(IconTheme::Emoji, "src", true, false).glyph, "📁");
    }

    #[test]
    fn pierre_tooling_file_names() {
        assert_eq!(pierre("CLAUDE.md").glyph, "\u{ec82}");
        assert_eq!(pierre("package.json").glyph, "\u{f06f7}");
        assert_eq!(pierre("package-lock.json").glyph, "\u{f06f7}");
        assert_eq!(pierre("bun.lock").glyph, "\u{e76f}");
        assert_eq!(pierre("vite.config.ts").glyph, "\u{e8d6}");
        assert_eq!(pierre("eslint.config.mjs").glyph, "\u{f0c7a}");
        assert_eq!(pierre(".prettierrc.json").glyph, "\u{e6b4}");
        assert_eq!(pierre("tailwind.config.js").glyph, "\u{f13ff}");
        assert_eq!(pierre("compose.yaml").glyph, "\u{f308}");
        assert_eq!(pierre("Gemfile").glyph, "\u{f0d2d}");
        assert_eq!(pierre(".zshrc").glyph, "\u{f018d}");
    }

    #[test]
    fn pierre_extension_colors() {
        assert_eq!(pierre("App.vue").rgb, Some(GREEN));
        assert_eq!(pierre("Widget.svelte").rgb, Some(RED));
        assert_eq!(pierre("index.tsx").rgb, Some(CYAN));
        assert_eq!(pierre("theme.scss").rgb, Some(PINK));
        assert_eq!(pierre("theme.less").rgb, Some(INDIGO));
        assert_eq!(pierre("icon.svg").rgb, Some(ORANGE));
        assert_eq!(pierre("module.wasm").glyph, "\u{e6a1}");
        assert_eq!(pierre("schema.prisma").glyph, "\u{e684}");
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
    fn theme_selection_is_always_pierre() {
        assert_eq!(IconTheme::from_env(None), None);
        assert_eq!(IconTheme::from_env(Some("pierre")), Some(IconTheme::Pierre));
        assert_eq!(
            IconTheme::from_env(Some("material")),
            Some(IconTheme::Pierre)
        );
        assert_eq!(
            IconTheme::from_state_name("material"),
            Some(IconTheme::Pierre)
        );
        assert_eq!(IconTheme::Pierre.state_name(), "pierre");
        assert_eq!(
            IconTheme::resolve(Some("emoji"), Some(IconTheme::Emoji)),
            IconTheme::Pierre
        );
        assert_eq!(
            IconTheme::resolve(None, Some(IconTheme::Emoji)),
            IconTheme::Pierre
        );
        assert_eq!(IconTheme::resolve(None, None), IconTheme::Pierre);
    }
}
