//! agentic-dev.layout integration: embedded sidebar in the layout-owned pane.
//!
//! `herdr plugin action invoke` replaces the process environment, so the file
//! path cannot travel in `AGENTIC_OPEN_PATH`. Call `layout.sh open-editor`
//! with the path on argv instead.

use std::path::{Path, PathBuf};
use std::process::Command;

pub fn is_embedded() -> bool {
    std::env::var("AGENTIC_LAYOUT_EMBEDDED").is_ok()
        || std::env::var("AGENTIC_LAYOUT_PLUGIN_ID").is_ok()
        || std::env::args().any(|arg| arg == "--embedded")
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SidebarContext {
    embedded: bool,
}

impl SidebarContext {
    pub fn detect() -> Self {
        Self {
            embedded: is_embedded(),
        }
    }

    pub fn embedded(&self) -> bool {
        self.embedded
    }

    pub fn follow_cwd(&self, user_enabled: bool) -> bool {
        !self.embedded && user_enabled
    }

    pub fn git_actions(&self) -> bool {
        !self.embedded
    }

    pub fn uses_external_editor(&self) -> bool {
        self.embedded
    }
}

fn herdr_bin() -> String {
    std::env::var("HERDR_BIN_PATH").unwrap_or_else(|_| "herdr".to_string())
}

/// Walk up from `start` looking for `layout.sh` (release binary lives at
/// `<plugin>/target/release/herdr-sidebar`).
pub fn plugin_root_from(start: &Path) -> Option<PathBuf> {
    let mut dir = if start.is_file() {
        start.parent()?
    } else {
        start
    };
    for _ in 0..8 {
        if dir.join("layout.sh").is_file() {
            return Some(dir.to_path_buf());
        }
        dir = dir.parent()?;
    }
    None
}

pub fn resolve_plugin_root() -> Option<PathBuf> {
    if let Ok(root) = std::env::var("HERDR_PLUGIN_ROOT") {
        let p = PathBuf::from(root);
        if p.join("layout.sh").is_file() {
            return Some(p);
        }
    }
    std::env::current_exe()
        .ok()
        .and_then(|exe| plugin_root_from(&exe))
}

fn invoke_layout(action: &str, extra: &[String]) -> Result<(), String> {
    let plugin_root =
        resolve_plugin_root().ok_or_else(|| "agentic-layout plugin root not found".to_string())?;
    let layout = plugin_root.join("layout.sh");
    let mut cmd = Command::new("bash");
    cmd.arg(&layout);
    cmd.arg(action);
    cmd.args(extra);
    cmd.env("HERDR_PLUGIN_ROOT", &plugin_root);
    cmd.env("HERDR_BIN_PATH", herdr_bin());
    if let Ok(ws) = std::env::var("HERDR_WORKSPACE_ID")
        && !ws.is_empty()
    {
        cmd.env("HERDR_WORKSPACE_ID", ws);
    }
    let status = cmd.status().map_err(|e| e.to_string())?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("{action} failed"))
    }
}

pub fn open_file_editor(path: &Path) -> Result<(), String> {
    invoke_layout("open-editor", &[path.display().to_string()])
        .map_err(|_| format!("open-editor failed for {}", path.display()))
}

pub fn open_review() -> Result<(), String> {
    invoke_layout("select-review", &[])
}

pub fn open_worktree_review() -> Result<(), String> {
    invoke_layout("select-review-worktree", &[])
}

pub fn refresh_review() -> Result<(), String> {
    invoke_layout("refresh-review", &[])
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn plugin_root_walks_up_from_release_binary() {
        let tmp = std::env::temp_dir().join(format!("agentic-embed-{}", std::process::id()));
        let bin = tmp.join("target/release/herdr-sidebar");
        fs::create_dir_all(bin.parent().unwrap()).unwrap();
        fs::write(tmp.join("layout.sh"), "#!/bin/bash\n").unwrap();
        fs::write(&bin, "").unwrap();
        assert_eq!(plugin_root_from(&bin).as_deref(), Some(tmp.as_path()));
        let _ = fs::remove_dir_all(&tmp);
    }
}
