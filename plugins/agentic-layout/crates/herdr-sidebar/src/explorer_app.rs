//! TUI state and rendering: a VS Code Explorer-style tree with disclosure arrows,
//! nested indentation, per-file-type icons, and a VS Code-like hide/show command
//! (`b`) when the user wants the columns back.

#[path = "explorer_footer.rs"]
mod explorer_footer;
#[path = "explorer_search.rs"]
mod explorer_search;

use std::path::{Path, PathBuf};

use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, MouseButton, MouseEvent, MouseEventKind};
use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style, Stylize};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, List, ListItem, Paragraph};

use herdr_sidebar::actions::{self, MenuAction, MenuEntry};
use herdr_sidebar::embed::SidebarContext;
use herdr_sidebar::file_search::FileSearch;
use herdr_sidebar::git::Git;
use herdr_sidebar::gitdeco::{Decorations, RepoStatus};
use herdr_sidebar::icons::{IconTheme, icon};
use herdr_sidebar::ipc;
use herdr_sidebar::state::{self as sidebar, Exit, View};
use herdr_sidebar::tree::{Row, Tree};
use herdr_sidebar::ui::{
    TitleAction, activity_icons, draw_scrollbar, gear_icon, hits, sibling_panes_of, status_color,
    title_action_spans, title_actions_visible, title_actions_width, truncate_to, wrap_hints,
};

use herdr_sidebar::sidebar_root;

const MY_VIEW: View = View::Explorer;

/// How often the git status decorations are re-read while the view is idle
/// (issue #19's "live update"). Two cheap `git status` calls per repo; the
/// explorer's own poll is 500ms, so this throttles them down to a quarter of
/// that.
const DECO_REFRESH: std::time::Duration = std::time::Duration::from_secs(2);

/// Handle for resizing our own pane through the herdr socket API.
struct PaneCtl {
    pane_id: String,
}

impl PaneCtl {
    fn from_env() -> Option<Self> {
        let pane_id = std::env::var("HERDR_PANE_ID")
            .ok()
            .filter(|id| !id.is_empty())?;
        Some(Self { pane_id })
    }

    /// Report identity tokens: always our own (so the ensure logic recognizes
    /// this pane even while the cosmetic label is cleared); in merged mode
    /// also the other view's — one Sidebar pane satisfies both plugins'
    /// launchers — otherwise clear the other view's token.
    fn report_tokens(&self, my: View, merged: bool) {
        herdr_sidebar::ipc::report_identity(&self.pane_id, my, merged);
    }

    /// Set or clear the pane label.
    fn set_label(&self, label: Option<&str>) {
        let mut params = serde_json::json!({ "pane_id": self.pane_id });
        if let Some(label) = label {
            params["label"] = serde_json::Value::String(label.to_string());
        }
        let _ = herdr_sidebar::ipc::call_text("pane.rename", params);
    }

    /// Resize our pane to `target` terminal columns over the socket API.
    /// `pane.resize`'s amount is a split-RATIO delta, so the exact amount comes
    /// from the live layout via [`herdr_sidebar::launch::resize_plan`].
    fn resize_to(&self, current: u16, target: u16, dock_right: bool) {
        let Ok(layout) = herdr_sidebar::ipc::call_text(
            "pane.layout",
            serde_json::json!({ "pane_id": self.pane_id }),
        ) else {
            return;
        };
        let Some(step) =
            herdr_sidebar::launch::resize_plan(&layout, &self.pane_id, current, target, dock_right)
        else {
            return;
        };
        let _ = herdr_sidebar::ipc::call_text(
            "pane.resize",
            serde_json::json!({
                "pane_id": self.pane_id,
                "direction": step.direction,
                "amount": step.amount,
            }),
        );
    }

    fn resize_preferred(&self, current: u16, target: u16, dock_right: bool) {
        let Ok(layout) = herdr_sidebar::ipc::call_text(
            "pane.layout",
            serde_json::json!({ "pane_id": self.pane_id }),
        ) else {
            return;
        };
        let Some(step) = herdr_sidebar::launch::preferred_resize_plan(
            &layout,
            &self.pane_id,
            current,
            target,
            dock_right,
        ) else {
            return;
        };
        let _ = herdr_sidebar::ipc::call_text(
            "pane.resize",
            serde_json::json!({
                "pane_id": self.pane_id,
                "direction": step.direction,
                "amount": step.amount,
            }),
        );
    }

    fn layout_width(&self) -> Option<i64> {
        let layout = herdr_sidebar::ipc::call_text(
            "pane.layout",
            serde_json::json!({ "pane_id": self.pane_id }),
        )
        .ok()?;
        herdr_sidebar::launch::layout_width(&layout)
    }
}

/// Where the tree body was drawn last frame, for mouse hit-testing.
#[derive(Clone, Copy, Default)]
struct BodyGeom {
    top: u16,
    height: u16,
    /// Scroll offset of the list at draw time.
    offset: usize,
}

/// What a prompt's input will be used for on Enter.
enum PromptKind {
    NewFile(PathBuf),
    NewFolder(PathBuf),
    Rename(PathBuf),
    /// Re-root the whole sidebar at a typed path (absolute, relative to the
    /// current root, or ~-prefixed).
    ChangeFolder,
}

/// A modal layered over the tree: the context menu, a name prompt, or a
/// delete confirmation. While one is open it owns keyboard and mouse input.
enum Overlay {
    Menu {
        /// Click position the popup anchors to.
        x: u16,
        y: u16,
        /// Target path + is_dir; `None` targets the workspace root.
        target: Option<(PathBuf, bool)>,
        entries: Vec<MenuEntry>,
        selected: usize,
        /// Rendered rect from the last draw, for click hit-testing.
        rect: Rect,
    },
    Prompt {
        title: String,
        input: String,
        kind: PromptKind,
    },
    ConfirmDelete {
        path: PathBuf,
        is_dir: bool,
    },
    /// The ⚙ settings modal: mouse-toggleable panel settings.
    Settings {
        selected: usize,
        rect: Rect,
    },
}

/// One row of the Settings modal.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Setting {
    UnifiedSidebar,
    DockRight,
    SidebarWidth,
    AutoOpen,
    FollowCwd,
    HiddenFiles,
    Hotkeys,
    GitDecorations,
    Folder,
}

/// (setting, label, current value, enabled) — disabled rows render dimmed and
/// don't toggle.
type SettingRow = (Setting, &'static str, String, bool);

pub struct App {
    tree: Tree,
    rows: Vec<Row>,
    /// The user's explicit selection — `None` until they pick something
    /// (no row is highlighted by default; hover stays subtle).
    selected: Option<usize>,
    /// View scroll offset in rows, independent of the selection: the wheel
    /// moves this alone.
    scroll: usize,
    /// Bring the selection into view on the next draw (keyboard nav only).
    snap: bool,
    theme: IconTheme,
    pane_ctl: Option<PaneCtl>,
    /// Pane size from the last draw; sizing decisions and PageUp/PageDown
    /// strides are based on what was actually rendered.
    last_width: u16,
    /// Whole tab area width from the last layout snapshot. A divider drag
    /// changes only this pane; surrounding terminal chrome changes this too.
    last_layout_width: Option<i64>,
    last_height: u16,
    page: usize,
    /// Row index under the mouse cursor, for the hover highlight.
    hovered: Option<usize>,
    body: BodyGeom,
    overlay: Option<Overlay>,
    search: FileSearch,
    /// Transient status/error line shown in the footer until the next action.
    notice: Option<String>,
    ctx: SidebarContext,
    // Merged-sidebar state.
    sidebar_state: sidebar::State,
    other_exe: Option<std::path::PathBuf>,
    activity: ActivityZones,
    /// The ⚙ button's rect from the last draw (activity bar in unified mode,
    /// header row otherwise).
    gear: Rect,
    /// The hover title-bar buttons' click zones from the last draw (empty
    /// while they are hidden).
    title_zones: Vec<(Rect, TitleAction)>,
    /// When the mouse last moved/clicked/scrolled over this pane — the hover
    /// approximation that shows the title-bar buttons (see
    /// [`herdr_sidebar::ui::TITLE_ACTIONS_LINGER`]).
    last_mouse: Option<std::time::Instant>,
    /// Last known mouse position, for the button hover highlight.
    mouse_pos: Option<(u16, u16)>,
    /// Last left-click (row index, when) for double-click detection.
    last_click: Option<(usize, std::time::Instant)>,
    /// Where the most recent preview landed, with its document key — so a
    /// double click pins that exact tab instead of re-opening it.
    last_preview: Option<(String, herdr_sidebar::viewer::PreviewTarget)>,
    /// Last heartbeat stamp, throttling the token refresh.
    last_beat: std::time::Instant,
    /// A native folder picker running on a background thread; its result
    /// arrives here (None = cancelled).
    picking: Option<std::sync::mpsc::Receiver<Option<PathBuf>>>,
    /// Shared across full app rebuilds and unified-view switches so manual
    /// folder precedence is not lost when this view is recreated.
    cwd_follower: std::rc::Rc<std::cell::RefCell<herdr_sidebar::launch::CwdFollower>>,
    /// Every repository the tree can see — the containing one plus child
    /// repos, exactly the set the Source Control view shows.
    repos: Vec<Git>,
    /// Git status decorations for the visible rows (issue #19).
    deco: Decorations,
    /// Last decoration refresh, throttling the git polling.
    last_deco: std::time::Instant,
    /// One background decoration refresh. Keeping at most one receiver avoids
    /// multiplying git processes when a slow repository overlaps the timer.
    deco_rx: Option<std::sync::mpsc::Receiver<Decorations>>,
}

/// How long two clicks on the same row still count as a double click.
const DOUBLE_CLICK: std::time::Duration = std::time::Duration::from_millis(450);

/// Activity-bar click zones from the last draw: the bar's row and the column
/// ranges of the explorer / source-control icons.
#[derive(Clone, Copy)]
struct ActivityZones {
    row: u16,
    explorer: (u16, u16),
    source_control: (u16, u16),
}

impl Default for ActivityZones {
    fn default() -> Self {
        // row = MAX: nothing hit-tests true before the first draw.
        Self {
            row: u16::MAX,
            explorer: (0, 0),
            source_control: (0, 0),
        }
    }
}

impl App {
    pub fn new(
        root: PathBuf,
        cwd_follower: std::rc::Rc<std::cell::RefCell<herdr_sidebar::launch::CwdFollower>>,
        ctx: SidebarContext,
    ) -> Self {
        let mut tree = Tree::new(root);
        // Mirror the tree the user was already looking at: a sidebar docked
        // into a brand-new preview tab starts with the same dirs expanded
        // and the same row selected.
        let saved = sidebar::load_tree_state(&tree.root_path());
        tree.set_expanded(saved.expanded);
        let rows = tree.rows();
        let restored_selection = saved
            .selected
            .and_then(|want| rows.iter().position(|r| r.path == want));
        let theme = IconTheme::resolve(
            std::env::var("HERDR_SIDEBAR_ICONS")
                .or_else(|_| std::env::var("HERDR_AA_FILETREE_ICONS"))
                .ok()
                .as_deref(),
            sidebar::load_state().icons,
        );
        let pane_ctl = PaneCtl::from_env();
        let last_layout_width = pane_ctl.as_ref().and_then(PaneCtl::layout_width);
        // The other view ships in this same binary — always available.
        let other_exe = std::env::current_exe().ok();
        let sidebar_state = sidebar::load_state();
        let repos = if sidebar_state.git_deco {
            Git::discover_all(&tree.root_path())
        } else {
            Vec::new()
        };
        let mut app = Self {
            tree,
            rows,
            selected: restored_selection,
            scroll: 0,
            snap: restored_selection.is_some(),
            theme,
            pane_ctl,
            last_width: sidebar_state.sidebar_width,
            last_layout_width,
            last_height: 24,
            page: 20,
            hovered: None,
            body: BodyGeom::default(),
            overlay: None,
            search: FileSearch::default(),
            notice: None,
            ctx,
            sidebar_state,
            other_exe,
            activity: ActivityZones::default(),
            gear: Rect::default(),
            title_zones: Vec::new(),
            last_mouse: None,
            mouse_pos: None,
            last_click: None,
            last_preview: None,
            last_beat: std::time::Instant::now(),
            picking: None,
            cwd_follower,
            repos,
            deco: Decorations::empty(),
            // Overwritten when the first background refresh is queued below.
            last_deco: std::time::Instant::now(),
            deco_rx: None,
        };
        app.apply_identity();
        app.request_decorations(true);
        app
    }

    pub fn root_path(&self) -> PathBuf {
        self.tree.root_path()
    }

    /// Idle work: keep the git decorations current so changes made outside
    /// the sidebar (an agent editing files, a commit in another pane) show up
    /// on their own. Self-throttling, so the event loop may call it freely.
    pub fn tick(&mut self) {
        self.sync_shared_settings();
        self.collect_decorations();
        if self.last_deco.elapsed() < DECO_REFRESH {
            return;
        }
        self.request_decorations(false);
    }

    /// A separated Source Control pane can change this shared setting while
    /// the Explorer keeps running. Re-read just this field so the tree reacts
    /// without adopting unrelated process-local mode changes.
    fn sync_shared_settings(&mut self) {
        let shared = sidebar::load_state();
        self.sidebar_state.dock_right = shared.dock_right;
        self.sidebar_state.show_hotkeys = shared.show_hotkeys;
        if shared.icons != self.sidebar_state.icons {
            self.sidebar_state.icons = shared.icons;
            self.theme = IconTheme::resolve(
                std::env::var("HERDR_SIDEBAR_ICONS")
                    .or_else(|_| std::env::var("HERDR_AA_FILETREE_ICONS"))
                    .ok()
                    .as_deref(),
                shared.icons,
            );
        }
        if shared.sidebar_width != self.sidebar_state.sidebar_width {
            self.sidebar_state.sidebar_width = shared.sidebar_width;
            if let Some(ctl) = &self.pane_ctl {
                ctl.resize_preferred(self.last_width, shared.sidebar_width, shared.dock_right);
            }
        }
        let enabled = shared.git_deco;
        if enabled == self.sidebar_state.git_deco {
            return;
        }
        self.sidebar_state.git_deco = enabled;
        self.rediscover_repos();
        if !enabled {
            self.deco = Decorations::empty();
        }
    }

    pub fn on_resize(&mut self, width: u16) {
        self.last_width = width;
        if let Some(ctl) = &self.pane_ctl {
            let layout_width = ctl.layout_width();
            let surrounding_changed = self
                .last_layout_width
                .zip(layout_width)
                .is_some_and(|(before, now)| before != now);
            self.last_layout_width = layout_width.or(self.last_layout_width);
            if surrounding_changed {
                ctl.resize_preferred(
                    width,
                    self.sidebar_state.sidebar_width,
                    self.sidebar_state.dock_right,
                );
            }
        }
    }

    /// Queue a status read off the event-loop thread. Preview tabs each carry
    /// a sidebar, so periodic refreshes back off while this pane is not
    /// focused; explicit refresh/stage actions pass `force = true`.
    fn request_decorations(&mut self, force: bool) {
        self.last_deco = std::time::Instant::now();
        if !self.sidebar_state.git_deco {
            self.deco = Decorations::empty();
            self.deco_rx = None;
            return;
        }
        if self.deco_rx.is_some() || (!force && !self.pane_is_focused()) {
            return;
        }
        let repos = self.repos.clone();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let statuses: Vec<RepoStatus> = repos
                .iter()
                .filter_map(|repo| {
                    let status = repo.status().ok()?;
                    Some(RepoStatus {
                        root: repo.root().to_path_buf(),
                        ignored: repo.ignored().unwrap_or_default(),
                        status,
                    })
                })
                .collect();
            let _ = tx.send(Decorations::build(&statuses));
        });
        self.deco_rx = Some(rx);
    }

    fn collect_decorations(&mut self) {
        let Some(rx) = &self.deco_rx else { return };
        match rx.try_recv() {
            Ok(deco) => {
                self.deco = deco;
                self.deco_rx = None;
            }
            Err(std::sync::mpsc::TryRecvError::Disconnected) => self.deco_rx = None,
            Err(std::sync::mpsc::TryRecvError::Empty) => {}
        }
    }

    fn pane_is_focused(&self) -> bool {
        let Some(pane_id) = self.pane_ctl.as_ref().map(|ctl| ctl.pane_id.as_str()) else {
            return true;
        };
        ipc::call_text("pane.list", serde_json::json!({}))
            .ok()
            .is_some_and(|json| pane_focused_in(&json, pane_id))
    }

    /// Rediscover the repositories under the current root — after a re-root,
    /// or an explicit refresh that may have added or removed one.
    fn rediscover_repos(&mut self) {
        self.deco_rx = None;
        self.repos = if self.sidebar_state.git_deco {
            Git::discover_all(&self.tree.root_path())
        } else {
            Vec::new()
        };
    }

    /// The decoration letter for a row, if any (see [`Decorations::letter`]).
    fn row_deco(&self, row: &Row) -> Option<char> {
        self.deco.letter(&row.path, row.is_dir)
    }

    /// Re-stamp the identity tokens so launchers know this pane is alive.
    /// Cheap (two socket round-trips); the event loop calls this every few
    /// seconds.
    pub fn heartbeat(&mut self) {
        if self.last_beat.elapsed() < std::time::Duration::from_secs(5) {
            return;
        }
        self.last_beat = std::time::Instant::now();
        if let Some(ctl) = &self.pane_ctl {
            ctl.report_tokens(MY_VIEW, self.merged());
        }
        self.ensure_embedded_root();
        self.follow_sibling_cwd();
    }

    fn ensure_embedded_root(&mut self) {
        if !self.ctx.embedded() {
            return;
        }
        let Some(workdir) = herdr_sidebar::state::layout_workdir() else {
            return;
        };
        if self
            .notice
            .as_deref()
            .is_some_and(|n| n.contains("-dev.layout"))
        {
            self.notice = None;
        }
        if workdir != self.tree.root_path() {
            self.reroot_at(workdir, false);
        }
    }

    fn follow_sibling_cwd(&mut self) {
        if !self.ctx.follow_cwd(self.sidebar_state.follow_cwd)
            || self.overlay.is_some()
            || self.picking.is_some()
        {
            return;
        }
        let Some(ctl) = &self.pane_ctl else { return };
        let Ok(panes) = herdr_sidebar::ipc::call_text("pane.list", serde_json::json!({})) else {
            return;
        };
        let target = self
            .cwd_follower
            .borrow_mut()
            .next_cwd(&panes, &ctl.pane_id);
        if let Some(target) = target
            && let Some(root) =
                sidebar_root::follow_sibling_target(&target, self.tree.root_path().as_path())
        {
            self.reroot_at(root, false);
        }
    }

    /// The merged sidebar is on and actually usable (other plugin present).
    fn merged(&self) -> bool {
        self.sidebar_state.merged && self.other_exe.is_some()
    }

    /// The label this pane should carry while expanded.
    fn pane_label(&self) -> &'static str {
        if self.merged() {
            sidebar::SIDEBAR_LABEL
        } else {
            herdr_sidebar::launch::PANE_LABEL
        }
    }

    /// Push our label + metadata tokens to herdr for the current mode.
    fn apply_identity(&self) {
        let Some(ctl) = &self.pane_ctl else { return };
        ctl.set_label(Some(self.pane_label()));
        ctl.report_tokens(MY_VIEW, self.merged());
    }

    /// Open a file: in the agentic layout this is a new Herdr tab running the
    /// configured editor (`fresh path`). Standalone sidebar
    /// still uses the in-process preview pane beside the tree.
    fn open_preview(&mut self, path: &Path) {
        if self.ctx.uses_external_editor() {
            match herdr_sidebar::embed::open_file_editor(path) {
                Ok(()) => self.notice = None,
                Err(e) => self.notice = Some(e),
            }
            return;
        }
        let Some(pane_id) = self.pane_ctl.as_ref().map(|c| c.pane_id.clone()) else {
            self.notice = Some("preview needs a herdr pane".into());
            return;
        };
        let payload = herdr_sidebar::viewer::file_request(path);
        let doc_key = herdr_sidebar::viewer::doc_key_for_file(path);
        match herdr_sidebar::viewer::open_in_pane(
            &pane_id,
            &self.tree.root_path(),
            &doc_key,
            &payload,
        ) {
            // Remember where it landed: a double click pins THIS tab rather
            // than re-opening, which would race the viewer's first stamp.
            Ok(target) => self.last_preview = Some((doc_key, target)),
            Err(e) => self.notice = Some(e),
        }
    }

    // ---- Unified-sidebar operations ----

    /// Toggle the unified sidebar. On: adopt this pane as the Sidebar and
    /// close the other panel's standalone pane in this tab. Off: split the
    /// other view back out into its own pane. Deliberately silent — the
    /// layout change is its own feedback.
    fn set_unified(&mut self, on: bool) {
        if on == self.merged() || self.other_exe.is_none() {
            return;
        }
        self.sidebar_state = sidebar::update_state(|state| {
            state.merged = on;
            state.active = MY_VIEW;
        });
        self.apply_identity();
        if on {
            // Mirror the detach growth: absorbing the sibling leaves the
            // survivor at roughly double width — shrink back to one panel.
            let width = self.last_width;
            self.close_other_standalone_pane();
            if let Some(ctl) = &self.pane_ctl {
                ctl.resize_to(
                    width.saturating_mul(2).saturating_add(1),
                    width,
                    self.sidebar_state.dock_right,
                );
            }
        } else {
            self.spawn_other_pane();
        }
    }

    /// Hand the pane to the other view (the supervisor swaps processes).
    fn switch_to(&mut self, view: View) -> Option<Exit> {
        if !self.merged() || view == MY_VIEW {
            return None;
        }
        self.sidebar_state = sidebar::update_state(|state| state.active = view);
        Some(Exit::Switch)
    }

    /// Close the other panel's standalone pane in our tab, if one is open.
    fn close_other_standalone_pane(&self) {
        let Some(ctl) = &self.pane_ctl else { return };
        let Ok(json) = herdr_sidebar::ipc::call_text("pane.list", serde_json::json!({})) else {
            return;
        };
        for id in sibling_panes_of(&json, &ctl.pane_id, MY_VIEW.other()) {
            let _ =
                herdr_sidebar::ipc::call_text("pane.close", serde_json::json!({ "pane_id": id }));
        }
    }

    /// Open the other view in a fresh pane beside this one (detach).
    fn spawn_other_pane(&self) {
        let (Some(ctl), Some(_)) = (&self.pane_ctl, &self.other_exe) else {
            return;
        };
        // Grow to double width FIRST, then split 50/50 — each separated panel
        // keeps the width the unified sidebar had, instead of halving.
        ctl.resize_to(
            self.last_width,
            self.last_width.saturating_mul(2).saturating_add(1),
            self.sidebar_state.dock_right,
        );
        let response = herdr_sidebar::ipc::call_text(
            "pane.split",
            serde_json::json!({
                "target_pane_id": ctl.pane_id,
                "direction": "right",
                "ratio": 0.5,
                "focus": false,
                "cwd": self.tree.root_path().display().to_string(),
                "env": sidebar::spawn_env(),
            }),
        );
        let Some(new_pane) = response
            .ok()
            .and_then(|r| herdr_sidebar::launch::split_pane_id(&r))
        else {
            return;
        };
        let flag = MY_VIEW.other().view_flag();
        let command = format!("{} --view {flag}", sidebar::EXECUTABLE_NAME);
        let _ = herdr_sidebar::ipc::call_text(
            "pane.send_input",
            serde_json::json!({ "pane_id": new_pane, "text": command, "keys": ["Enter"] }),
        );
        let _ = herdr_sidebar::ipc::call_text(
            "pane.rename",
            serde_json::json!({ "pane_id": new_pane, "label": MY_VIEW.other().label() }),
        );
    }

    /// Handle one key press; `Some(exit)` ends the event loop.
    pub fn on_key(&mut self, key: KeyEvent) -> Option<Exit> {
        if key.kind != KeyEventKind::Press {
            return None;
        }
        self.notice = None;
        if self.search.active() {
            return explorer_search::on_search_key(self, key);
        }
        if self.overlay.is_some() {
            self.overlay_key(key);
            return None;
        }
        match key.code {
            KeyCode::Char('q') => return Some(Exit::Quit),
            // Esc never quits the sidebar — it closes the preview instead.
            KeyCode::Esc => self.close_preview(),
            KeyCode::Up | KeyCode::Char('k') => self.move_by(-1),
            KeyCode::Down | KeyCode::Char('j') => self.move_by(1),
            KeyCode::PageUp => self.move_by(-(self.page as isize)),
            KeyCode::PageDown => self.move_by(self.page as isize),
            KeyCode::Home | KeyCode::Char('g') => self.select(0),
            KeyCode::End | KeyCode::Char('G') => self.select(self.rows.len().saturating_sub(1)),
            KeyCode::Right | KeyCode::Char('l') => self.expand_or_enter(),
            KeyCode::Left | KeyCode::Char('h') => self.collapse_or_parent(),
            KeyCode::Enter | KeyCode::Char(' ') => self.toggle(),
            KeyCode::Char('r') => {
                self.refresh_tree();
            }
            KeyCode::Char('.') => {
                self.tree.show_hidden = !self.tree.show_hidden;
                self.rebuild();
            }
            KeyCode::Char('c') => self.change_folder_dialog(),
            KeyCode::Char('m') => self.open_menu_for_selection(),
            KeyCode::Char('s') => self.open_settings(),
            KeyCode::Char('/') => {
                self.search.start();
                explorer_search::apply_search(self);
            }
            KeyCode::Char('v') if self.ctx.uses_external_editor() => {
                if let Err(e) = herdr_sidebar::embed::open_review() {
                    self.notice = Some(e);
                }
            }
            KeyCode::Char('1') => return self.switch_to(View::Explorer),
            KeyCode::Char('2') => return self.switch_to(View::SourceControl),
            _ => {}
        }
        None
    }

    /// `Some(exit)` ends the event loop, mirroring on_key.
    pub fn on_mouse(&mut self, mouse: MouseEvent) -> Option<Exit> {
        // Any mouse activity = "the mouse is over this pane": it shows the
        // hover title-bar buttons until the linger expires.
        self.last_mouse = Some(std::time::Instant::now());
        self.mouse_pos = Some((mouse.column, mouse.row));
        if self.overlay.is_some() {
            self.overlay_mouse(mouse);
            return None;
        }
        match mouse.kind {
            MouseEventKind::Moved => {
                self.hovered = self.row_at(mouse.row);
            }
            MouseEventKind::ScrollUp => self.scroll_view(-3),
            MouseEventKind::ScrollDown => self.scroll_view(3),
            MouseEventKind::Down(MouseButton::Left) => {
                let zones = self.activity;
                if self.merged() && mouse.row == zones.row {
                    if (zones.explorer.0..zones.explorer.1).contains(&mouse.column) {
                        return self.switch_to(View::Explorer);
                    }
                    if (zones.source_control.0..zones.source_control.1).contains(&mouse.column) {
                        return self.switch_to(View::SourceControl);
                    }
                }
                let g = self.gear;
                if mouse.column >= g.x
                    && mouse.column < g.x + g.width
                    && mouse.row >= g.y
                    && mouse.row < g.y + g.height
                {
                    self.open_settings();
                    return None;
                }
                if let Some(&(_, action)) = self
                    .title_zones
                    .iter()
                    .find(|(rect, _)| hits(*rect, mouse.column, mouse.row))
                {
                    self.title_action(action);
                    return None;
                }
                let index = self.row_at(mouse.row)?;
                self.select(index);
                let row = &self.rows[index];
                let (is_dir, path) = (row.is_dir, row.path.clone());
                let on_chevron = is_dir && hits_chevron(mouse.column, row.depth);
                // Double click = second click on the same row inside the window.
                let now = std::time::Instant::now();
                let double = self
                    .last_click
                    .take()
                    .is_some_and(|(i, at)| i == index && now.duration_since(at) < DOUBLE_CLICK);
                self.last_click = Some((index, now));
                if is_dir {
                    // Chevron always toggles; the name toggles on double click.
                    if on_chevron || double {
                        self.toggle();
                    }
                } else if self.ctx.uses_external_editor() {
                    self.open_preview(&path);
                } else if double {
                    // Pin the tab the first click just opened. Re-opening
                    // here would race the viewer's first token stamp and
                    // spawn a second tab for the same file.
                    let doc_key = herdr_sidebar::viewer::doc_key_for_file(&path);
                    match self.last_preview.as_ref() {
                        Some((key, target)) if *key == doc_key => {
                            if !herdr_sidebar::viewer::pin_target(target, &doc_key) {
                                self.notice = Some(
                                    "preview switch blocked; resolve unsaved changes in its tab"
                                        .into(),
                                );
                            }
                        }
                        _ => self.open_preview(&path),
                    }
                } else {
                    self.open_preview(&path);
                }
            }
            MouseEventKind::Down(MouseButton::Right) => {
                self.notice = None;
                self.open_context_menu(mouse.column, mouse.row);
            }
            _ => {}
        }
        None
    }

    /// One of the hover title-bar buttons was clicked.
    fn title_action(&mut self, action: TitleAction) {
        match action {
            TitleAction::NewFile => self.open_create_prompt(false),
            TitleAction::NewFolder => self.open_create_prompt(true),
            TitleAction::Refresh => self.refresh_tree(),
            TitleAction::CollapseAll => {
                self.tree.collapse_all();
                self.scroll = 0;
                self.rebuild();
            }
        }
    }

    /// The title-bar New File / New Folder buttons: prompt for a name,
    /// creating in the VS Code target (see [`create_target_dir`]).
    fn open_create_prompt(&mut self, folder: bool) {
        let dir = create_target_dir(self.selected_row(), self.tree.root_path());
        self.overlay = Some(Overlay::Prompt {
            title: if folder { "New folder" } else { "New file" }.into(),
            input: String::new(),
            kind: if folder {
                PromptKind::NewFolder(dir)
            } else {
                PromptKind::NewFile(dir)
            },
        });
    }

    /// Open the file context menu at the click position, targeting the row
    /// under the cursor (or the workspace root on empty space).
    fn open_context_menu(&mut self, x: u16, y: u16) {
        let target = self.row_at(y).map(|index| {
            self.select(index);
            let row = &self.rows[index];
            (row.path.clone(), row.is_dir)
        });
        self.show_menu(x, y, target);
    }

    /// `m`: the same context menu, opened from the KEYBOARD on the current
    /// selection (issue #18 — mobile herdr clients and terminals that swallow
    /// right-click have no other way in). With nothing selected it targets the
    /// workspace root, exactly like a right-click on empty space.
    fn open_menu_for_selection(&mut self) {
        let target = self
            .selected_row()
            .map(|row| (row.path.clone(), row.is_dir));
        let (x, y) = self.selection_anchor();
        self.show_menu(x, y, target);
    }

    /// Where a keyboard-opened popup anchors: just under the selected row when
    /// it is on screen, else the top of the body.
    fn selection_anchor(&self) -> (u16, u16) {
        let Some(index) = self.selected else {
            return (0, self.body.top);
        };
        let visible =
            index >= self.body.offset && index < self.body.offset + usize::from(self.body.height);
        let y = if visible {
            self.body.top + (index - self.body.offset) as u16
        } else {
            self.body.top
        };
        let depth = self.rows.get(index).map(|r| r.depth).unwrap_or(0);
        let x = ((depth * 2) as u16).min(self.last_width.saturating_sub(1));
        (x, y)
    }

    /// Build and show the menu popup for a resolved target.
    fn show_menu(&mut self, x: u16, y: u16, target: Option<(PathBuf, bool)>) {
        let in_repo = target
            .as_ref()
            .is_some_and(|(path, _)| Git::owner_of(path).is_ok());
        let entries = actions::menu_entries(target.as_ref().map(|(_, is_dir)| *is_dir), in_repo);
        let selected = entries
            .iter()
            .position(|e| matches!(e, MenuEntry::Action(..)))
            .unwrap_or(0);
        self.overlay = Some(Overlay::Menu {
            x,
            y,
            target,
            entries,
            selected,
            rect: Rect::default(),
        });
    }

    fn overlay_key(&mut self, key: KeyEvent) {
        enum Cmd {
            Nothing,
            Close,
            Activate,
            ConfirmPrompt,
            ToggleSetting(usize),
            AdjustWidth(bool),
            DeleteConfirmed(PathBuf, bool),
        }
        let settings = self.settings_rows();
        let row_count = settings.len();
        let cmd = match self.overlay.as_mut() {
            Some(Overlay::Settings { selected, .. }) => match key.code {
                KeyCode::Esc | KeyCode::Char('q') | KeyCode::Char('s') => Cmd::Close,
                KeyCode::Up | KeyCode::Char('k') => {
                    *selected = selected.saturating_sub(1);
                    Cmd::Nothing
                }
                KeyCode::Down | KeyCode::Char('j') => {
                    *selected = (*selected + 1).min(row_count.saturating_sub(1));
                    Cmd::Nothing
                }
                KeyCode::Left | KeyCode::Char('h')
                    if settings.get(*selected).map(|row| row.0) == Some(Setting::SidebarWidth) =>
                {
                    Cmd::AdjustWidth(false)
                }
                KeyCode::Right | KeyCode::Char('l')
                    if settings.get(*selected).map(|row| row.0) == Some(Setting::SidebarWidth) =>
                {
                    Cmd::AdjustWidth(true)
                }
                KeyCode::Enter | KeyCode::Char(' ') => Cmd::ToggleSetting(*selected),
                _ => Cmd::Nothing,
            },
            Some(Overlay::Menu {
                entries, selected, ..
            }) => match key.code {
                KeyCode::Esc => Cmd::Close,
                KeyCode::Up | KeyCode::Char('k') => {
                    *selected = step_menu(entries, *selected, -1);
                    Cmd::Nothing
                }
                KeyCode::Down | KeyCode::Char('j') => {
                    *selected = step_menu(entries, *selected, 1);
                    Cmd::Nothing
                }
                KeyCode::Enter => Cmd::Activate,
                _ => Cmd::Nothing,
            },
            Some(Overlay::Prompt { input, .. }) => match key.code {
                KeyCode::Esc => Cmd::Close,
                KeyCode::Backspace => {
                    input.pop();
                    Cmd::Nothing
                }
                KeyCode::Char(c) => {
                    input.push(c);
                    Cmd::Nothing
                }
                KeyCode::Enter => Cmd::ConfirmPrompt,
                _ => Cmd::Nothing,
            },
            Some(Overlay::ConfirmDelete { path, is_dir }) => match key.code {
                KeyCode::Char('y') | KeyCode::Char('Y') => {
                    Cmd::DeleteConfirmed(path.clone(), *is_dir)
                }
                _ => Cmd::Close,
            },
            None => Cmd::Nothing,
        };
        match cmd {
            Cmd::Nothing => {}
            Cmd::Close => self.overlay = None,
            Cmd::Activate => self.activate_menu_entry(),
            Cmd::ConfirmPrompt => self.confirm_prompt(),
            Cmd::ToggleSetting(index) => self.toggle_setting(index),
            Cmd::AdjustWidth(wider) => self.adjust_sidebar_width(wider),
            Cmd::DeleteConfirmed(path, is_dir) => {
                self.overlay = None;
                match actions::delete(&path, is_dir) {
                    Ok(()) => self.refresh_tree(),
                    Err(err) => self.notice = Some(format!("delete failed: {err}")),
                }
            }
        }
    }

    fn overlay_mouse(&mut self, mouse: MouseEvent) {
        enum Cmd {
            Nothing,
            Close,
            Activate,
            ToggleSetting(usize),
            Reopen(u16, u16),
        }
        let row_count = self.settings_rows().len();
        let cmd = match self.overlay.as_mut() {
            Some(Overlay::Settings { selected, rect }) => {
                // Rows start just inside the top border (the title renders ON
                // the border, not on its own line).
                let row_at = |row: u16, col: u16| -> Option<usize> {
                    (col > rect.x
                        && col < rect.x + rect.width.saturating_sub(1)
                        && row > rect.y
                        && row < rect.y + 1 + row_count as u16)
                        .then(|| usize::from(row - rect.y - 1))
                };
                match mouse.kind {
                    MouseEventKind::Moved => {
                        if let Some(i) = row_at(mouse.row, mouse.column) {
                            *selected = i;
                        }
                        Cmd::Nothing
                    }
                    MouseEventKind::Down(MouseButton::Left) => {
                        match row_at(mouse.row, mouse.column) {
                            Some(i) => {
                                *selected = i;
                                Cmd::ToggleSetting(i)
                            }
                            None if mouse.column >= rect.x
                                && mouse.column < rect.x + rect.width
                                && mouse.row >= rect.y
                                && mouse.row < rect.y + rect.height =>
                            {
                                Cmd::Nothing
                            }
                            None => Cmd::Close,
                        }
                    }
                    _ => Cmd::Nothing,
                }
            }
            Some(Overlay::Menu {
                entries,
                selected,
                rect,
                ..
            }) => {
                let inner = rect.inner(ratatui::layout::Margin::new(1, 1));
                let item_at = |row: u16, col: u16| -> Option<usize> {
                    (col >= inner.x
                        && col < inner.x + inner.width
                        && row >= inner.y
                        && row < inner.y + inner.height)
                        .then(|| usize::from(row - inner.y))
                        .filter(|i| {
                            *i < entries.len() && matches!(entries[*i], MenuEntry::Action(..))
                        })
                };
                match mouse.kind {
                    MouseEventKind::Moved => {
                        if let Some(i) = item_at(mouse.row, mouse.column) {
                            *selected = i;
                        }
                        Cmd::Nothing
                    }
                    MouseEventKind::Down(MouseButton::Left) => {
                        if let Some(i) = item_at(mouse.row, mouse.column) {
                            *selected = i;
                            Cmd::Activate
                        } else {
                            Cmd::Close
                        }
                    }
                    MouseEventKind::Down(MouseButton::Right) => {
                        Cmd::Reopen(mouse.column, mouse.row)
                    }
                    _ => Cmd::Nothing,
                }
            }
            // Prompts/confirms are keyboard-driven; clicks do nothing.
            _ => Cmd::Nothing,
        };
        match cmd {
            Cmd::Nothing => {}
            Cmd::Close => self.overlay = None,
            Cmd::Activate => self.activate_menu_entry(),
            Cmd::ToggleSetting(index) => self.toggle_setting(index),
            Cmd::Reopen(x, y) => {
                self.overlay = None;
                self.open_context_menu(x, y);
            }
        }
    }

    // ---- Settings modal ----

    fn open_settings(&mut self) {
        self.overlay = Some(Overlay::Settings {
            selected: 0,
            rect: Rect::default(),
        });
    }

    /// The modal's rows for the current state.
    fn settings_rows(&self) -> Vec<SettingRow> {
        vec![
            (
                Setting::UnifiedSidebar,
                "Unified sidebar",
                if self.merged() { "on" } else { "off" }.to_string(),
                self.other_exe.is_some(),
            ),
            (
                Setting::DockRight,
                "Dock on the right",
                if self.sidebar_state.dock_right {
                    "on"
                } else {
                    "off"
                }
                .to_string(),
                true,
            ),
            (
                Setting::SidebarWidth,
                "Sidebar width",
                format!("{} cols", self.sidebar_state.sidebar_width),
                true,
            ),
            (
                Setting::HiddenFiles,
                "Hidden files",
                if self.tree.show_hidden {
                    "shown"
                } else {
                    "hidden"
                }
                .to_string(),
                true,
            ),
            (
                Setting::Hotkeys,
                "Footer hotkeys",
                if self.show_hotkeys() {
                    "shown"
                } else {
                    "hidden"
                }
                .to_string(),
                true,
            ),
            (
                Setting::AutoOpen,
                "Auto-open sidebar",
                if self.sidebar_state.auto_open {
                    "on"
                } else {
                    "off"
                }
                .to_string(),
                true,
            ),
            (
                Setting::FollowCwd,
                "Follow pane folder",
                sidebar::follow_cwd_setting_value(self.sidebar_state.follow_cwd),
                true,
            ),
            (
                Setting::GitDecorations,
                "Git decorations",
                if self.sidebar_state.git_deco {
                    "on"
                } else {
                    "off"
                }
                .to_string(),
                true,
            ),
            (
                Setting::Folder,
                "Change folder…",
                self.tree.root_name(),
                true,
            ),
        ]
    }

    fn toggle_setting(&mut self, index: usize) {
        let rows = self.settings_rows();
        let Some(row) = rows.get(index) else { return };
        let (setting, enabled) = (row.0, row.3);
        if !enabled {
            return;
        }
        match setting {
            Setting::UnifiedSidebar => {
                // The pane layout changes underneath the modal; close it.
                self.overlay = None;
                let on = !self.merged();
                self.set_unified(on);
            }
            Setting::DockRight => {
                self.sidebar_state =
                    sidebar::update_state(|state| state.dock_right = !state.dock_right);
            }
            Setting::SidebarWidth => self.adjust_sidebar_width(true),
            Setting::HiddenFiles => {
                self.tree.show_hidden = !self.tree.show_hidden;
                self.rebuild();
            }
            Setting::Hotkeys => {
                self.sidebar_state =
                    sidebar::update_state(|state| state.show_hotkeys = !state.show_hotkeys);
            }
            Setting::AutoOpen => {
                self.sidebar_state =
                    sidebar::update_state(|state| state.auto_open = !state.auto_open);
            }
            Setting::FollowCwd => {
                self.sidebar_state =
                    sidebar::update_state(|state| state.follow_cwd = !state.follow_cwd);
                self.cwd_follower.borrow_mut().reset();
            }
            Setting::GitDecorations => {
                self.sidebar_state =
                    sidebar::update_state(|state| state.git_deco = !state.git_deco);
                self.rediscover_repos();
                self.request_decorations(true);
            }
            Setting::Folder => {
                self.overlay = None;
                self.change_folder_dialog();
            }
        }
    }

    fn adjust_sidebar_width(&mut self, wider: bool) {
        self.sidebar_state = sidebar::update_state(|state| {
            state.sidebar_width = sidebar::step_sidebar_width(state.sidebar_width, wider);
        });
        if let Some(ctl) = &self.pane_ctl {
            ctl.resize_preferred(
                self.last_width,
                self.sidebar_state.sidebar_width,
                self.sidebar_state.dock_right,
            );
        }
    }

    /// Render the centered Settings popup and remember its rect for clicks.
    fn draw_settings(&mut self, frame: &mut Frame) {
        let rows = self.settings_rows();
        let area = frame.area();
        let desired_width = rows
            .iter()
            .map(|(_, label, value, _)| label.chars().count() + value.chars().count() + 5)
            .max()
            .unwrap_or(30)
            .max(30) as u16;
        let width = desired_width.min(area.width);
        // The hotkey reference lives here now; the footer chips are opt-in.
        let hint_lines = wrap_hints(&explorer_footer::hints(self), width.saturating_sub(2), 0);
        let Some(Overlay::Settings { selected, rect }) = self.overlay.as_mut() else {
            return;
        };
        let height = (rows.len() as u16 + 5 + hint_lines.len() as u16).min(area.height);
        let popup = Rect::new(
            (area.width.saturating_sub(width)) / 2,
            (area.height.saturating_sub(height)) / 3,
            width,
            height,
        );
        *rect = popup;

        let inner_w = usize::from(width.saturating_sub(2));
        let mut lines: Vec<Line> = Vec::new();
        for (i, (_, label, value, enabled)) in rows.iter().enumerate() {
            let pad = inner_w.saturating_sub(label.chars().count() + value.chars().count() + 2);
            let text = format!(" {label}{}{value} ", " ".repeat(pad.max(1)));
            let style = if !enabled {
                Style::default().dim()
            } else if i == *selected {
                Style::default()
                    .bg(Color::DarkGray)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default()
            };
            lines.push(Line::styled(text, style));
        }
        lines.push(Line::default());
        lines.push(Line::from(Span::styled(
            " Hotkeys",
            Style::default().bold(),
        )));
        lines.extend(hint_lines);
        lines.push(Line::from(" click/⏎ · ←/→ width · esc".dim()));

        frame.render_widget(Clear, popup);
        frame.render_widget(
            Paragraph::new(lines).block(
                ratatui::widgets::Block::bordered()
                    .title(" Settings ")
                    .border_style(Style::default().dim()),
            ),
            popup,
        );
    }

    fn activate_menu_entry(&mut self) {
        let Some(Overlay::Menu {
            target,
            entries,
            selected,
            ..
        }) = self.overlay.take()
        else {
            return;
        };
        let MenuEntry::Action(action, _) = entries[selected] else {
            return;
        };
        // Creation targets: the folder itself, a file's parent, or the root.
        let create_dir = match &target {
            Some((path, true)) => path.clone(),
            Some((path, false)) => path
                .parent()
                .map(Path::to_path_buf)
                .unwrap_or_else(|| self.tree.root_path()),
            None => self.tree.root_path(),
        };
        match action {
            MenuAction::NewFile => {
                self.overlay = Some(Overlay::Prompt {
                    title: "New file".into(),
                    input: String::new(),
                    kind: PromptKind::NewFile(create_dir),
                });
            }
            MenuAction::NewFolder => {
                self.overlay = Some(Overlay::Prompt {
                    title: "New folder".into(),
                    input: String::new(),
                    kind: PromptKind::NewFolder(create_dir),
                });
            }
            MenuAction::CopyPath | MenuAction::CopyRelativePath => {
                let Some((path, _)) = &target else { return };
                let text = if action == MenuAction::CopyPath {
                    path.display().to_string()
                } else {
                    path.strip_prefix(self.tree.root_path())
                        .unwrap_or(path)
                        .display()
                        .to_string()
                };
                self.notice = Some(match actions::copy_to_clipboard(&text) {
                    Ok(()) => format!("copied: {text}"),
                    Err(err) => format!("copy failed: {err}"),
                });
            }
            MenuAction::Rename => {
                let Some((path, _)) = target else { return };
                let current = path
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default();
                self.overlay = Some(Overlay::Prompt {
                    title: "Rename".into(),
                    input: current,
                    kind: PromptKind::Rename(path),
                });
            }
            MenuAction::Delete => {
                let Some((path, is_dir)) = target else { return };
                self.overlay = Some(Overlay::ConfirmDelete { path, is_dir });
            }
            MenuAction::OpenExternal => {
                let Some((path, _)) = target else { return };
                let name = path
                    .file_name()
                    .unwrap_or(path.as_os_str())
                    .to_string_lossy();
                self.notice = Some(match actions::open_external(&path) {
                    Ok(()) => format!("opened: {name}"),
                    Err(err) => format!("open failed: {err}"),
                });
            }
            MenuAction::Stage => {
                let Some((path, _)) = target else { return };
                self.stage(&path);
            }
            MenuAction::Reveal => {
                let path = target
                    .map(|(p, _)| p)
                    .unwrap_or_else(|| self.tree.root_path());
                actions::reveal(&path);
            }
            MenuAction::ChangeFolder => self.change_folder_dialog(),
            MenuAction::ChangeFolderTyped => self.change_folder_prompt(),
        }
    }

    /// `c` / the context menu: the NATIVE folder picker, on a background
    /// thread so the pane's liveness heartbeat keeps beating while the
    /// dialog is open (a frozen TUI would read as a corpse after 20s).
    #[cfg(any(windows, target_os = "macos"))]
    fn change_folder_dialog(&mut self) {
        if self.picking.is_some() {
            return;
        }
        let (tx, rx) = std::sync::mpsc::channel();
        let start = self.tree.root_path();
        std::thread::spawn(move || {
            let _ = tx.send(actions::pick_folder(&start));
        });
        self.picking = Some(rx);
        self.notice = Some("folder picker open… (check your other windows)".into());
    }

    /// No native dialogs here — fall back to the typed prompt.
    #[cfg(not(any(windows, target_os = "macos")))]
    fn change_folder_dialog(&mut self) {
        self.change_folder_prompt();
    }

    /// Collect a finished folder pick, if any (called from the poll loop).
    pub fn poll_picker(&mut self) {
        let Some(rx) = &self.picking else { return };
        match rx.try_recv() {
            Ok(Some(path)) => {
                self.picking = None;
                let path_str = path.as_os_str().to_str().unwrap_or("");
                match sidebar_root::apply_folder(path_str, self.tree.root_path().as_path(), true) {
                    sidebar_root::FolderApply::Applied(root) => self.reroot_at(root, true),
                    sidebar_root::FolderApply::Rejected { message: Some(msg) } => {
                        self.notice = Some(msg)
                    }
                    sidebar_root::FolderApply::Rejected { message: None } => {}
                }
            }
            Ok(None) => {
                self.picking = None;
                self.notice = None;
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => {}
            Err(_) => self.picking = None,
        }
    }

    /// `c` / the context menu: prompt for a new root folder, prefilled with
    /// the current one so relative tweaks are quick.
    fn change_folder_prompt(&mut self) {
        self.overlay = Some(Overlay::Prompt {
            title: "Folder".into(),
            input: self.tree.root_path().display().to_string(),
            kind: PromptKind::ChangeFolder,
        });
    }

    /// Re-root everything at `target` (also the PROCESS cwd, so the Source
    /// Control view follows on the next view switch).
    fn change_folder(&mut self, raw: &str) {
        self.change_folder_impl(raw, true);
    }

    fn change_folder_impl(&mut self, raw: &str, manual: bool) {
        match sidebar_root::apply_folder(raw, self.tree.root_path().as_path(), manual) {
            sidebar_root::FolderApply::Applied(root) => self.reroot_at(root, manual),
            sidebar_root::FolderApply::Rejected { message: Some(msg) } => self.notice = Some(msg),
            sidebar_root::FolderApply::Rejected { message: None } => {}
        }
    }

    fn reroot_at(&mut self, root: PathBuf, manual: bool) {
        if manual && self.sidebar_state.follow_cwd {
            self.cwd_follower.borrow_mut().mark_manual_folder();
        }
        let cwd_follower = std::rc::Rc::clone(&self.cwd_follower);
        *self = App::new(root, cwd_follower, self.ctx);
        if manual {
            self.notice = Some(format!("folder: {}", self.tree.root_name()));
        }
    }

    fn confirm_prompt(&mut self) {
        let Some(Overlay::Prompt { input, kind, .. }) = self.overlay.take() else {
            return;
        };
        // Folder changes take a full PATH — they skip the name validation.
        if matches!(kind, PromptKind::ChangeFolder) {
            self.change_folder(&input);
            return;
        }
        let Some(name) = actions::validate_name(&input) else {
            self.notice = Some("invalid name".into());
            return;
        };
        let result = match &kind {
            PromptKind::NewFile(dir) => actions::create_file(dir, name),
            PromptKind::NewFolder(dir) => actions::create_folder(dir, name),
            PromptKind::Rename(path) => actions::rename(path, name),
            PromptKind::ChangeFolder => unreachable!("handled above"),
        };
        match result {
            Ok(created) => {
                if let PromptKind::NewFile(dir) | PromptKind::NewFolder(dir) = &kind {
                    self.tree.expand(dir);
                }
                self.refresh_tree();
                if let Some(index) = self.rows.iter().position(|r| r.path == created) {
                    self.select(index);
                }
            }
            Err(err) => self.notice = Some(format!("failed: {err}")),
        }
    }

    /// "Stage Changes" (issue #20): `git add` everything under `path` that
    /// belongs to the repository that OWNS it. The owner is the nearest
    /// enclosing repo, so staging inside a nested checkout stages there — and
    /// staging a parent directory never reaches across the boundary into it
    /// (see [`Git::stage_under`]). Decorations refresh either way, so a failed
    /// stage cannot leave the tree showing something stale; the Source Control
    /// view picks the new index up on its own poll.
    fn stage(&mut self, path: &Path) {
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.display().to_string());
        let result = Git::owner_of(path)
            .and_then(|repo| repo.stage_under(path).map(|done| (done, repo.name())));
        self.notice = Some(match result {
            // A stage that skipped everything needs saying WHY, or the
            // boundary rule reads as a silent no-op.
            Ok((done, _)) if done.count == 0 && done.skipped_nested > 0 => format!(
                "{name}: nothing staged — {} path(s) belong to a nested repo",
                done.skipped_nested
            ),
            Ok((done, _)) if done.count == 0 => format!("nothing to stage in {name}"),
            Ok((done, repo)) if done.count == 1 => format!("staged {name} in {repo}"),
            Ok((done, repo)) => {
                format!("staged {} paths under {name} in {repo}", done.count)
            }
            Err(err) => format!("stage failed: {err}"),
        });
        self.request_decorations(true);
    }

    fn refresh_tree(&mut self) {
        self.tree.refresh();
        self.rediscover_repos();
        self.request_decorations(true);
        self.rebuild();
    }

    /// The visible row index at a pane-local mouse row, if it lands on one.
    fn row_at(&self, mouse_row: u16) -> Option<usize> {
        row_index_at(self.body, self.rows.len(), mouse_row)
    }

    fn selected_row(&self) -> Option<&Row> {
        self.rows.get(self.selected?)
    }

    fn select(&mut self, index: usize) {
        if !self.rows.is_empty() {
            self.selected = Some(index.min(self.rows.len() - 1));
            self.snap = true;
            self.persist_tree();
        }
    }

    /// Record the tree's shape and selection for the NEXT sidebar to start —
    /// a tab opened for a preview comes up mirroring this one. Not a live
    /// sync: already-open tabs are never revisited.
    fn persist_tree(&self) {
        sidebar::save_tree_state(
            &self.tree.root_path(),
            &sidebar::TreeState {
                expanded: self.tree.expanded_paths(),
                selected: self.selected_row().map(|r| r.path.clone()),
            },
        );
    }

    fn move_by(&mut self, delta: isize) {
        if self.rows.is_empty() {
            return;
        }
        // First keyboard step on a selection-less list picks the first row.
        let Some(current) = self.selected else {
            self.select(0);
            return;
        };
        let next = (current as isize + delta).clamp(0, self.rows.len().saturating_sub(1) as isize);
        self.select(next as usize);
    }

    /// Wheel: move the VIEW only — the selection stays where it is.
    fn scroll_view(&mut self, delta: isize) {
        let max = self.rows.len().saturating_sub(1) as isize;
        self.scroll = (self.scroll as isize + delta).clamp(0, max) as usize;
    }

    /// Right/l: expand a collapsed directory, step into an expanded one.
    fn expand_or_enter(&mut self) {
        let Some(row) = self.selected_row() else {
            return;
        };
        if !row.is_dir {
            return;
        }
        if row.expanded {
            // First child, if any, sits directly below at depth + 1.
            let index = self.selected.unwrap_or(0);
            if self
                .rows
                .get(index + 1)
                .is_some_and(|next| next.depth == row.depth + 1)
            {
                self.select(index + 1);
            }
        } else {
            let path = row.path.clone();
            self.tree.expand(&path);
            self.rebuild();
        }
    }

    /// Left/h: collapse an expanded directory, otherwise jump to the parent row.
    fn collapse_or_parent(&mut self) {
        let Some(row) = self.selected_row() else {
            return;
        };
        if row.is_dir && row.expanded {
            let path = row.path.clone();
            self.tree.collapse(&path);
            self.rebuild();
            return;
        }
        let index = self.selected.unwrap_or(0);
        let depth = row.depth;
        if depth == 0 {
            return;
        }
        if let Some(parent) = self.rows[..index]
            .iter()
            .rposition(|r| r.depth == depth - 1)
        {
            self.select(parent);
        }
    }

    fn toggle(&mut self) {
        let Some(row) = self.selected_row() else {
            return;
        };
        let path = row.path.clone();
        if !row.is_dir {
            // Enter on a file opens it, like clicking it.
            self.open_preview(&path);
            return;
        }
        self.tree.toggle(&path);
        self.rebuild();
    }

    /// Recompute visible rows, keeping the selection on the same path when it
    /// still exists (else the nearest valid index).
    fn rebuild(&mut self) {
        self.hovered = None;
        if self.search.active() {
            explorer_search::apply_search(self);
            return;
        }
        let selected_path = self.selected_row().map(|r| r.path.clone());
        self.persist_tree();
        self.rows = self.tree.rows();
        if self.rows.is_empty() {
            self.selected = None;
            self.scroll = 0;
            return;
        }
        // Keep an EXISTING selection on its path (or nearest index); a
        // selection-less list stays selection-less.
        if let Some(path) = selected_path {
            let index = self
                .rows
                .iter()
                .position(|r| r.path == path)
                .unwrap_or_else(|| self.selected.unwrap_or(0).min(self.rows.len() - 1));
            self.selected = Some(index);
        } else if let Some(sel) = self.selected {
            self.selected = Some(sel.min(self.rows.len() - 1));
        }
        self.scroll = self.scroll.min(self.rows.len() - 1);
    }

    pub fn draw(&mut self, frame: &mut Frame) {
        self.last_width = frame.area().width;
        self.last_height = frame.area().height;
        // No own border/title: herdr already frames the pane and titles it with
        // the pane label ("Explorer"/"Files") — a second border read as a
        // double frame.
        let footer_height = explorer_footer::footer_height(self, frame.area().width);
        // A breathing row above and below the icons keeps the activity bar
        // from crowding the pane border.
        let activity_height = if self.merged() { 3 } else { 0 };
        let [activity, header, body, footer] = Layout::vertical([
            Constraint::Length(activity_height),
            Constraint::Length(1),
            Constraint::Min(0),
            Constraint::Length(footer_height),
        ])
        .areas(frame.area());
        self.page = body.height.saturating_sub(1).max(1) as usize;

        if self.merged() {
            self.draw_activity_bar(frame, activity);
        }
        self.draw_header(frame, header);

        if self.rows.is_empty() {
            let msg = if self.search.active() {
                self.search.empty_message()
            } else {
                "  (empty)"
            };
            frame.render_widget(Paragraph::new(msg.dim().italic()), body);
        } else {
            let h = (body.height as usize).max(1);
            self.scroll = self.scroll.min(self.rows.len().saturating_sub(h));
            if self.snap {
                if let Some(sel) = self.selected {
                    if sel < self.scroll {
                        self.scroll = sel;
                    } else if sel >= self.scroll + h {
                        self.scroll = sel + 1 - h;
                    }
                }
                self.snap = false;
            }
            let theme = self.theme;
            let hovered = self.hovered;
            let selected = self.selected;
            let items: Vec<ListItem> = self
                .rows
                .iter()
                .enumerate()
                .skip(self.scroll)
                .take(h)
                .map(|(i, r)| {
                    row_item(
                        r,
                        theme,
                        hovered == Some(i),
                        selected == Some(i),
                        self.row_deco(r),
                        body.width,
                    )
                })
                .collect();
            frame.render_widget(List::new(items), body);
            draw_scrollbar(frame, body, self.rows.len(), h, self.scroll);
        }
        self.body = BodyGeom {
            top: body.y,
            height: body.height,
            offset: self.scroll,
        };

        let footer_lines = explorer_footer::footer_lines(self, footer.width);
        frame.render_widget(Paragraph::new(footer_lines), footer);

        match self.overlay {
            Some(Overlay::Menu { .. }) => self.draw_menu(frame),
            Some(Overlay::Settings { .. }) => self.draw_settings(frame),
            _ => {}
        }
    }

    /// The workspace-name header (the root folder's name, uppercase like VS
    /// Code); standalone mode puts the ⚙ at its right edge (unified mode's ⚙
    /// lives in the activity bar instead), and the hover title-action buttons
    /// sit just left of it.
    fn draw_header(&mut self, frame: &mut Frame, area: Rect) {
        let gear = (!self.merged()).then(|| {
            Span::styled(
                format!("{} ", gear_icon(self.theme)),
                Style::default().dim(),
            )
        });
        let gear_w = gear.as_ref().map(Span::width).unwrap_or(0) as u16;
        self.title_zones.clear();
        let (action_spans, actions_w) = if title_actions_visible(self.last_mouse) {
            let actions = [
                TitleAction::NewFile,
                TitleAction::NewFolder,
                TitleAction::Refresh,
                TitleAction::CollapseAll,
            ];
            let w = title_actions_width(self.theme, &actions);
            let ax = area.x + area.width.saturating_sub(gear_w + w);
            let (spans, zones) =
                title_action_spans(self.theme, &actions, ax, area.y, self.mouse_pos);
            self.title_zones = zones;
            (spans, w)
        } else {
            (Vec::new(), 0)
        };
        // The name yields to the buttons and gear in narrow panes.
        let avail = usize::from(area.width.saturating_sub(gear_w + actions_w));
        let root_label = truncate_to(format!(" {}", self.tree.root_name().to_uppercase()), avail);
        let name = Span::styled(root_label, Style::default().bold().fg(Color::LightBlue));
        let pad = usize::from(area.width)
            .saturating_sub(name.width() + usize::from(actions_w) + usize::from(gear_w));
        let mut spans = vec![name, Span::raw(" ".repeat(pad))];
        spans.extend(action_spans);
        if let Some(gear) = gear {
            let gx = area.x + area.width.saturating_sub(gear_w);
            self.gear = Rect::new(gx, area.y, gear_w, 1);
            spans.push(gear);
        }
        frame.render_widget(Paragraph::new(Line::from(spans)), area);
    }

    /// The persisted "show hotkeys in the footer" setting.
    fn show_hotkeys(&self) -> bool {
        self.sidebar_state.show_hotkeys
    }

    /// Esc: close the preview pane in this tab, if one is open.
    fn close_preview(&mut self) {
        if let Some(pane_id) = self.pane_ctl.as_ref().map(|c| c.pane_id.clone()) {
            herdr_sidebar::viewer::close_in_tab(&pane_id);
        }
    }

    /// The VS Code activity bar: view-switcher icons plus a detach button.
    /// The area is three rows tall; the outer rows stay in the pane
    /// background, and only the ACTIVE icon's highlight chip extends into
    /// them by a half block — a tall button with built-in breathing room,
    /// no strip container.
    fn draw_activity_bar(&mut self, frame: &mut Frame, area: Rect) {
        let outer_top = area.y;
        let outer_bottom = area.y + 2;
        let area = Rect::new(area.x, area.y + 1, area.width, 1);
        let (exp_icon, git_icon) = activity_icons(self.theme);
        let active = |on: bool| {
            if on {
                Style::default()
                    .bg(Color::DarkGray)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().dim()
            }
        };
        // Both FA glyphs (folder, code-fork) render two cells wide in the
        // non-Mono Nerd Font; reserve the second cell in each chip so the
        // highlights are equal-sized with centered icons.
        let slack = if self.theme == IconTheme::Material {
            " "
        } else {
            ""
        };
        let spans = [
            Span::raw(" "),
            Span::styled(format!(" {exp_icon}{slack} "), active(true)),
            Span::raw(" "),
            Span::styled(format!(" {git_icon}{slack} "), active(false)),
        ];
        // Hit zones from the actual span widths (emoji vs nerd-glyph widths differ).
        let mut x = area.x;
        let mut bounds = Vec::new();
        for span in &spans {
            let w = span.width() as u16;
            bounds.push((x, x + w));
            x += w;
        }
        self.activity = ActivityZones {
            row: area.y,
            explorer: bounds[1],
            source_control: bounds[3],
        };
        // Symmetric half-block caps: a 2-cell button with the icon in its
        // vertical center.
        let (chip_start, chip_end) = bounds[1];
        let chip_w = chip_end.saturating_sub(chip_start);
        let cap = |glyph: &str| {
            Paragraph::new(glyph.repeat(usize::from(chip_w)))
                .style(Style::default().fg(Color::DarkGray))
        };
        frame.render_widget(cap("▄"), Rect::new(chip_start, outer_top, chip_w, 1));
        frame.render_widget(cap("▀"), Rect::new(chip_start, outer_bottom, chip_w, 1));
        let gear = Span::styled(
            format!(" {} ", gear_icon(self.theme)),
            Style::default().dim(),
        );
        let gear_w = gear.width() as u16;
        let gear_x = area.x + area.width.saturating_sub(gear_w);
        self.gear = Rect::new(gear_x, area.y, gear_w, 1);

        let pad = usize::from(area.width)
            .saturating_sub(spans.iter().map(Span::width).sum::<usize>() + usize::from(gear_w));
        let mut line = spans.to_vec();
        line.push(Span::raw(" ".repeat(pad)));
        line.push(gear);
        frame.render_widget(Paragraph::new(Line::from(line)), area);
    }

    /// Render the context-menu popup near its anchor, clamped inside the pane,
    /// and remember its rect for mouse hit-testing.
    fn draw_menu(&mut self, frame: &mut Frame) {
        let Some(Overlay::Menu {
            x,
            y,
            entries,
            selected,
            rect,
            ..
        }) = self.overlay.as_mut()
        else {
            return;
        };
        let area = frame.area();
        let label_width = entries
            .iter()
            .map(|e| match e {
                MenuEntry::Action(_, label) => label.chars().count(),
                MenuEntry::Separator => 0,
            })
            .max()
            .unwrap_or(0) as u16;
        let width = (label_width + 4).min(area.width);
        let height = (entries.len() as u16 + 2).min(area.height);
        let px = (*x).min(area.width.saturating_sub(width));
        let py = (*y + 1).min(area.height.saturating_sub(height));
        let popup = Rect::new(px, py, width, height);
        *rect = popup;

        let items: Vec<ListItem> = entries
            .iter()
            .enumerate()
            .map(|(i, entry)| match entry {
                MenuEntry::Separator => {
                    ListItem::new(Line::from("─".repeat(usize::from(width - 2)).dim()))
                }
                MenuEntry::Action(_, label) => {
                    let line = Line::raw(format!(" {label}"));
                    if i == *selected {
                        ListItem::new(line).style(
                            Style::default()
                                .bg(Color::DarkGray)
                                .add_modifier(Modifier::BOLD),
                        )
                    } else {
                        ListItem::new(line)
                    }
                }
            })
            .collect();
        frame.render_widget(Clear, popup);
        frame.render_widget(
            List::new(items)
                .block(ratatui::widgets::Block::bordered().border_style(Style::default().dim())),
            popup,
        );
    }
}

fn pane_focused_in(pane_list_json: &str, pane_id: &str) -> bool {
    let Ok(value) =
        serde_json::from_str::<serde_json::Value>(pane_list_json.trim_start_matches('\u{feff}'))
    else {
        return false;
    };
    value
        .get("result")
        .and_then(|result| result.get("panes"))
        .and_then(|panes| panes.as_array())
        .and_then(|panes| {
            panes
                .iter()
                .find(|pane| pane.get("pane_id").and_then(|id| id.as_str()) == Some(pane_id))
        })
        .and_then(|pane| pane.get("focused"))
        .and_then(|focused| focused.as_bool())
        .unwrap_or(false)
}

/// The right-aligned decoration for a status letter (issue #19): the letter
/// itself for a file, a filled dot for a directory whose DESCENDANTS changed
/// (VS Code's dirty-folder badge), and nothing at all for ignored paths —
/// those are conveyed by the dimmed name instead.
fn deco_marker(letter: char, is_dir: bool) -> Option<String> {
    match letter {
        'I' => None,
        _ if is_dir => Some("●".to_string()),
        c => Some(c.to_string()),
    }
}

/// The name's style for a decoration. Decorations are FOREGROUND-only on
/// purpose: selection and hover own the background, so a decorated row stays
/// readable when it is also the selected one.
fn deco_name_style(letter: Option<char>) -> Style {
    match letter {
        Some('I') => Style::default().dim(),
        Some(c) => Style::default().fg(status_color(c)),
        None => Style::default(),
    }
}

fn row_item(
    row: &Row,
    theme: IconTheme,
    hovered: bool,
    selected: bool,
    deco: Option<char>,
    width: u16,
) -> ListItem<'static> {
    let item = ListItem::new(row_line(row, theme, deco, width));
    match row_bg(hovered, selected) {
        Some(style) => item.style(style),
        None => item,
    }
}

/// The selection / hover BACKGROUND for a row, if any. Kept apart from the
/// content so a git decoration (foreground-only) can never collide with it.
fn row_bg(hovered: bool, selected: bool) -> Option<Style> {
    if selected {
        Some(
            Style::default()
                .bg(Color::DarkGray)
                .add_modifier(Modifier::BOLD),
        )
    } else if hovered {
        // Subtler than the selection bg — hover is a hint, not a choice.
        Some(Style::default().bg(Color::Rgb(48, 52, 60)))
    } else {
        None
    }
}

/// One tree row's content: indent, chevron, icon, name, and the right-aligned
/// git decoration.
fn row_line(row: &Row, theme: IconTheme, deco: Option<char>, width: u16) -> Line<'static> {
    let indent = "  ".repeat(row.depth);
    let arrow = if row.is_dir {
        if row.expanded { "▾ " } else { "▸ " }
    } else {
        "  "
    };
    let icon = icon(theme, &row.name, row.is_dir, row.expanded);
    let icon_style = match icon.rgb {
        Some((r, g, b)) => Style::default().fg(Color::Rgb(r, g, b)),
        None => Style::default(),
    };
    // Folder and file names share the default foreground, like VS Code — the
    // chevron and icon carry the distinction. Accent-on-gray (the old blue
    // names) was hard to read against the selection/hover backgrounds. A git
    // status recolors the name on top of that.
    let mut spans = vec![
        Span::styled(format!("{indent}{arrow}"), Style::default().dim()),
        Span::styled(format!("{} ", icon.glyph), icon_style),
    ];
    let marker = deco.and_then(|letter| deco_marker(letter, row.is_dir));
    // Row anatomy with a marker: [prefix][name][pad][marker][2 trailing]. The
    // two trailing cells keep the marker clear of the overflow scrollbar,
    // which overdraws the very last column; the name yields the 4 cells that
    // leaves (gap + marker + 2), so a narrow pane ellipsizes the NAME instead
    // of losing the status.
    let tail = if marker.is_some() { 4 } else { 0 };
    let used: usize = spans.iter().map(Span::width).sum();
    let avail = usize::from(width).saturating_sub(used + tail);
    let name = truncate_to(row.name.clone(), avail);
    let name_width = Span::raw(name.as_str()).width();
    spans.push(Span::styled(name, deco_name_style(deco)));
    if let Some(marker) = marker {
        let pad = usize::from(width).saturating_sub(used + name_width + 3);
        spans.push(Span::raw(" ".repeat(pad)));
        spans.push(Span::styled(
            marker,
            Style::default()
                .fg(status_color(deco.unwrap_or(' ')))
                .add_modifier(Modifier::BOLD),
        ));
        spans.push(Span::raw("  "));
    }
    Line::from(spans)
}

/// Next selectable (non-separator) menu index in `direction`, staying put at
/// the ends.
fn step_menu(entries: &[MenuEntry], from: usize, direction: isize) -> usize {
    let mut index = from as isize;
    loop {
        index += direction;
        if index < 0 || index >= entries.len() as isize {
            return from;
        }
        if matches!(entries[index as usize], MenuEntry::Action(..)) {
            return index as usize;
        }
    }
}

/// VS Code's creation target for the title-bar New File / New Folder buttons:
/// a selected folder itself, a selected file's parent, or the workspace root
/// when nothing is selected.
fn create_target_dir(selected: Option<&Row>, root: PathBuf) -> PathBuf {
    match selected {
        Some(row) if row.is_dir => row.path.clone(),
        Some(row) => row.path.parent().map(Path::to_path_buf).unwrap_or(root),
        None => root,
    }
}

/// True when a click at pane-local `column` lands on a row's disclosure
/// chevron (the two cells right after the depth indent).
fn hits_chevron(column: u16, depth: usize) -> bool {
    let start = (depth * 2) as u16;
    (start..start + 2).contains(&column)
}

/// The row index at a pane-local mouse row given the last-drawn body
/// geometry, if it lands on an actual row.
fn row_index_at(body: BodyGeom, row_count: usize, mouse_row: u16) -> Option<usize> {
    if mouse_row < body.top || mouse_row >= body.top + body.height {
        return None;
    }
    let index = body.offset + usize::from(mouse_row - body.top);
    (index < row_count).then_some(index)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn menu_navigation_skips_separators_and_clamps() {
        let entries = actions::menu_entries(Some(false), true);
        // First entry is an action; stepping up from it stays put.
        assert_eq!(step_menu(&entries, 0, -1), 0);
        // Stepping down over a separator lands on the next action.
        let sep = entries
            .iter()
            .position(|e| matches!(e, MenuEntry::Separator))
            .unwrap();
        assert_eq!(step_menu(&entries, sep - 1, 1), sep + 1);
        let last = entries.len() - 1;
        assert_eq!(step_menu(&entries, last, 1), last);
    }

    #[test]
    fn chevron_hit_region_follows_indent_depth() {
        assert!(hits_chevron(0, 0));
        assert!(hits_chevron(1, 0));
        assert!(!hits_chevron(2, 0), "icon cell");
        assert!(hits_chevron(2, 1));
        assert!(hits_chevron(3, 1));
        assert!(!hits_chevron(0, 1), "indent cell");
    }

    #[test]
    fn create_target_matches_vscode_semantics() {
        let root = PathBuf::from("C:\\ws");
        let dir = Row {
            path: root.join("src"),
            name: "src".into(),
            is_dir: true,
            depth: 0,
            expanded: false,
        };
        let file = Row {
            path: root.join("src").join("main.rs"),
            name: "main.rs".into(),
            is_dir: false,
            depth: 1,
            expanded: false,
        };
        assert_eq!(
            create_target_dir(Some(&dir), root.clone()),
            root.join("src")
        );
        assert_eq!(
            create_target_dir(Some(&file), root.clone()),
            root.join("src")
        );
        assert_eq!(create_target_dir(None, root.clone()), root);
    }

    #[test]
    fn focused_pane_detection_is_scoped_to_our_pane_id() {
        let panes = r#"{"result":{"panes":[
            {"pane_id":"w1:p1","focused":false},
            {"pane_id":"w1:p2","focused":true}
        ]}}"#;
        assert!(!pane_focused_in(panes, "w1:p1"));
        assert!(pane_focused_in(panes, "w1:p2"));
        assert!(!pane_focused_in("garbage", "w1:p2"));
    }

    /// The rendered text of a row, decorations included.
    fn rendered(row: &Row, deco: Option<char>, width: u16) -> String {
        row_line(row, IconTheme::Emoji, deco, width)
            .spans
            .iter()
            .map(|s| s.content.as_ref())
            .collect()
    }

    fn file_row(name: &str) -> Row {
        Row {
            path: PathBuf::from("C:\\ws").join(name),
            name: name.into(),
            is_dir: false,
            depth: 0,
            expanded: false,
        }
    }

    fn dir_row(name: &str) -> Row {
        Row {
            path: PathBuf::from("C:\\ws").join(name),
            name: name.into(),
            is_dir: true,
            depth: 0,
            expanded: false,
        }
    }

    #[test]
    fn files_render_their_status_letter_and_dirs_a_dirty_dot() {
        assert!(rendered(&file_row("app.rs"), Some('M'), 30).ends_with("M  "));
        assert!(rendered(&file_row("new.rs"), Some('A'), 30).ends_with("A  "));
        assert!(rendered(&file_row("gone.rs"), Some('D'), 30).ends_with("D  "));
        assert!(rendered(&file_row("notes.md"), Some('U'), 30).ends_with("U  "));
        assert!(rendered(&file_row("merge.rs"), Some('!'), 30).ends_with("!  "));
        // A directory shows the aggregate as a dot, never a letter.
        let dir = rendered(&dir_row("src"), Some('M'), 30);
        assert!(dir.ends_with("●  "), "{dir}");
        assert!(!dir.contains('M'));
    }

    #[test]
    fn undecorated_and_ignored_rows_carry_no_marker() {
        let plain = rendered(&file_row("app.rs"), None, 30);
        assert!(plain.trim_end().ends_with("app.rs"), "{plain}");
        // Ignored is conveyed by the dimmed name alone — no trailing marker.
        let ignored = rendered(&file_row("build.log"), Some('I'), 30);
        assert!(ignored.trim_end().ends_with("build.log"), "{ignored}");
    }

    #[test]
    fn decorations_are_foreground_only_so_selection_stays_visible() {
        // Selection owns the BACKGROUND; a decoration must only recolor the
        // name, or a selected changed row would be unreadable.
        assert_eq!(
            row_bg(false, true).and_then(|s| s.bg),
            Some(Color::DarkGray)
        );
        assert_eq!(
            row_bg(true, false).and_then(|s| s.bg),
            Some(Color::Rgb(48, 52, 60))
        );
        assert_eq!(row_bg(false, false), None);
        // The decoration itself only ever sets a foreground.
        let name_spans = row_line(&file_row("app.rs"), IconTheme::Emoji, Some('M'), 30);
        assert!(name_spans.spans.iter().all(|s| s.style.bg.is_none()));
        assert_eq!(deco_name_style(Some('M')).fg, Some(status_color('M')));
        assert_eq!(deco_name_style(Some('M')).bg, None);
        assert_eq!(deco_name_style(None).fg, None);
        assert!(
            deco_name_style(Some('I'))
                .add_modifier
                .contains(Modifier::DIM)
        );
    }

    #[test]
    fn a_decorated_name_is_truncated_to_keep_the_marker_visible() {
        let long = file_row("a-very-long-file-name-that-will-not-fit.rs");
        let text = rendered(&long, Some('M'), 20);
        assert!(
            text.ends_with("M  "),
            "marker survives a narrow pane: {text}"
        );
        assert_eq!(
            Span::raw(text.as_str()).width(),
            20,
            "and the row still fills exactly the pane width"
        );
    }

    #[test]
    fn deco_markers_follow_the_row_kind() {
        assert_eq!(deco_marker('M', false).as_deref(), Some("M"));
        assert_eq!(deco_marker('M', true).as_deref(), Some("●"));
        assert_eq!(deco_marker('!', true).as_deref(), Some("●"));
        assert_eq!(deco_marker('I', false), None);
        assert_eq!(deco_marker('I', true), None);
    }

    #[test]
    fn row_index_accounts_for_header_and_scroll() {
        let body = BodyGeom {
            top: 1,
            height: 10,
            offset: 5,
        };
        assert_eq!(row_index_at(body, 100, 0), None, "header row");
        assert_eq!(row_index_at(body, 100, 1), Some(5));
        assert_eq!(row_index_at(body, 100, 10), Some(14));
        assert_eq!(row_index_at(body, 100, 11), None, "footer row");
        assert_eq!(row_index_at(body, 6, 2), None, "past the last row");
    }
}
