//! Pure layout decisions: tab adoption, dock ratios, v3→v4 state migrate.
//! No Herdr RPC — same role as `launch.rs` stdin→stdout helpers.

use serde::Serialize;

use crate::herdr_json::{LayoutState, Tab};

// Agent and shell/review (center) share the remaining width equally.
// Sidebar stays 1/6: agent 5/12, center 5/12, sidebar 1/6.
pub const AGENT_RATIO: f64 = 0.416667;
pub const SIDEBAR_RATIO: f64 = 0.166667;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CenterView {
    Shell,
    Review,
    Editor,
    Other,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct DockStep {
    pub pane_role: &'static str,
    pub split: &'static str,
    pub ratio: f64,
    pub swap: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct DockPlan {
    pub view: CenterView,
    pub center_pane_id: String,
    pub steps: Vec<DockStep>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct AdoptedTabs {
    pub shell_tab_id: Option<String>,
    pub review_tab_id: Option<String>,
    pub extra_tab_ids: Vec<String>,
}

pub fn agent_split_ratio(agent: f64) -> f64 {
    round6(1.0 - agent)
}

pub fn sidebar_remainder_ratio(agent: f64, sidebar: f64) -> f64 {
    let rem = if 1.0 - agent <= 0.0 { 1.0 } else { 1.0 - agent };
    round6(sidebar / rem)
}

pub fn sidebar_split_ratio(agent: f64, sidebar: f64) -> f64 {
    round6(1.0 - sidebar_remainder_ratio(agent, sidebar))
}

pub fn agent_move_ratio(agent: f64) -> f64 {
    round6(agent)
}

pub fn sidebar_move_ratio(agent: f64, sidebar: f64) -> f64 {
    sidebar_remainder_ratio(agent, sidebar)
}

fn round6(n: f64) -> f64 {
    (n * 1_000_000.0).round() / 1_000_000.0
}

pub fn is_placeholder_label(label: &str) -> bool {
    matches!(label, "" | "main" | "Main") || label.chars().all(|c| c.is_ascii_digit())
}

pub fn tab_is_editor(tab_id: &str, state: &LayoutState) -> bool {
    state.editors.values().any(|e| e.tab_id == tab_id)
}

fn tab_in_list(tabs: &[Tab], id: &str) -> bool {
    !id.is_empty() && tabs.iter().any(|t| t.tab_id == id)
}

pub fn choose_shell_tab_id(state: &LayoutState, tabs: &[Tab]) -> Option<String> {
    if tab_in_list(tabs, &state.shell_tab_id) {
        return Some(state.shell_tab_id.clone());
    }
    if let Some(tab) = tabs.iter().find(|t| t.label == "Shell") {
        return Some(tab.tab_id.clone());
    }
    tabs.iter()
        .find(|t| !tab_is_editor(&t.tab_id, state))
        .map(|t| t.tab_id.clone())
}

pub fn choose_review_tab_id(state: &LayoutState, tabs: &[Tab], shell_id: &str) -> Option<String> {
    if tab_in_list(tabs, &state.review_tab_id) && state.review_tab_id != shell_id {
        return Some(state.review_tab_id.clone());
    }
    tabs.iter()
        .find(|t| t.tab_id != shell_id && t.label == "Review")
        .map(|t| t.tab_id.clone())
}

pub fn extra_layout_tab_ids(
    tabs: &[Tab],
    shell_id: &str,
    review_id: &str,
    state: &LayoutState,
) -> Vec<String> {
    tabs.iter()
        .filter(|t| t.tab_id != shell_id && t.tab_id != review_id)
        .filter(|t| !tab_is_editor(&t.tab_id, state))
        .filter(|t| t.label == "Shell" || t.label == "Review" || is_placeholder_label(&t.label))
        .map(|t| t.tab_id.clone())
        .collect()
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Geometry {
    pub agent_split: f64,
    pub sidebar_split: f64,
    pub agent_move: f64,
    pub sidebar_move: f64,
}

pub fn geometry(agent: f64, sidebar: f64) -> Geometry {
    Geometry {
        agent_split: agent_split_ratio(agent),
        sidebar_split: sidebar_split_ratio(agent, sidebar),
        agent_move: agent_move_ratio(agent),
        sidebar_move: sidebar_move_ratio(agent, sidebar),
    }
}

pub fn adopt_tabs(state: &LayoutState, tabs: &[Tab]) -> AdoptedTabs {
    adopt_tabs_with_shell(state, tabs, None)
}

pub fn adopt_tabs_with_shell(
    state: &LayoutState,
    tabs: &[Tab],
    shell: Option<&str>,
) -> AdoptedTabs {
    let shell_tab_id = shell
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .or_else(|| choose_shell_tab_id(state, tabs));
    let review_tab_id = shell_tab_id
        .as_deref()
        .and_then(|s| choose_review_tab_id(state, tabs, s));
    let extra_tab_ids = extra_layout_tab_ids(
        tabs,
        shell_tab_id.as_deref().unwrap_or(""),
        review_tab_id.as_deref().unwrap_or(""),
        state,
    );
    AdoptedTabs {
        shell_tab_id,
        review_tab_id,
        extra_tab_ids,
    }
}

fn editor_center_pane(state: &LayoutState, tab_id: &str) -> Option<String> {
    state
        .editors
        .values()
        .find(|e| e.tab_id == tab_id && !e.pane_id.is_empty())
        .map(|e| e.pane_id.clone())
}

fn dock_steps(state: &LayoutState, agent: f64, sidebar: f64) -> Vec<DockStep> {
    let mut steps = Vec::new();
    if !state.agent_pane_id.is_empty() {
        steps.push(DockStep {
            pane_role: "agent",
            split: "right",
            // Left-keep of the full tab, then swap: agent occupies that left slot.
            ratio: agent_move_ratio(agent),
            swap: true,
        });
    }
    if !state.sidebar_pane_id.is_empty() {
        steps.push(DockStep {
            pane_role: "sidebar",
            split: "right",
            // Left-keep of the remaining width: center keeps its equal share,
            // sidebar is the right 1/6 of the tab. Same as pane split.
            ratio: sidebar_split_ratio(agent, sidebar),
            swap: false,
        });
    }
    steps
}

pub fn dock_plan(state: &LayoutState, tab_id: &str, agent: f64, sidebar: f64) -> Option<DockPlan> {
    let (view, center_pane_id) = if tab_id == state.shell_tab_id {
        (CenterView::Shell, state.shell_pane_id.clone())
    } else if tab_id == state.review_tab_id {
        (CenterView::Review, state.review_pane_id.clone())
    } else if let Some(pane) = editor_center_pane(state, tab_id) {
        (CenterView::Editor, pane)
    } else {
        return Some(DockPlan {
            view: CenterView::Other,
            center_pane_id: String::new(),
            steps: Vec::new(),
        });
    };
    if center_pane_id.is_empty() {
        return None;
    }
    Some(DockPlan {
        view,
        center_pane_id,
        steps: dock_steps(state, agent, sidebar),
    })
}

pub fn select_tab_number(tabs: &[Tab], number: u32) -> Option<String> {
    if number == 0 {
        return None;
    }
    tabs.get((number - 1) as usize).map(|t| t.tab_id.clone())
}

pub fn select_tab_relative(tabs: &[Tab], delta: i32) -> Option<String> {
    if tabs.is_empty() {
        return None;
    }
    let cur = tabs.iter().position(|t| t.focused).unwrap_or(0) as i32;
    let len = tabs.len() as i32;
    let idx = ((cur + delta) % len + len) % len;
    Some(tabs[idx as usize].tab_id.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::herdr_json::{EditorEntry, LayoutState, Tab};

    fn empty_state() -> LayoutState {
        LayoutState::init("", "")
    }

    fn tabs(pairs: &[(&str, &str)]) -> Vec<Tab> {
        pairs
            .iter()
            .map(|(id, label)| Tab {
                tab_id: (*id).into(),
                label: (*label).into(),
                focused: false,
            })
            .collect()
    }

    #[test]
    fn review_first_workspace_adopts_tab0_as_shell() {
        let tabs = tabs(&[("w1:t1", "Review"), ("w1:t2", "notes")]);
        assert_eq!(
            choose_shell_tab_id(&empty_state(), &tabs).as_deref(),
            Some("w1:t1")
        );
    }

    #[test]
    fn live_shell_tab_id_wins_when_present() {
        let mut state = empty_state();
        state.shell_tab_id = "w1:t2".into();
        state.review_tab_id = "w1:t1".into();
        let tabs = tabs(&[("w1:t1", "Review"), ("w1:t2", "Shell")]);
        assert_eq!(choose_shell_tab_id(&state, &tabs).as_deref(), Some("w1:t2"));
    }

    #[test]
    fn review_is_the_other_layout_tab() {
        let tabs = tabs(&[("w1:t1", "Review"), ("w1:t2", "Shell")]);
        assert_eq!(
            choose_review_tab_id(&empty_state(), &tabs, "w1:t2").as_deref(),
            Some("w1:t1")
        );
    }

    #[test]
    fn extra_main_placeholder_is_collected() {
        let tabs = tabs(&[
            ("w1:t1", "Shell"),
            ("w1:t2", "Review"),
            ("w1:t3", "main"),
            ("w1:t4", "editor"),
        ]);
        assert_eq!(
            extra_layout_tab_ids(&tabs, "w1:t1", "w1:t2", &empty_state()),
            vec!["w1:t3".to_string()]
        );
    }

    #[test]
    fn leading_numeric_placeholder_is_collected() {
        let tabs = tabs(&[("w1:t0", "1"), ("w1:t1", "Shell"), ("w1:t2", "Review")]);
        assert_eq!(
            extra_layout_tab_ids(&tabs, "w1:t1", "w1:t2", &empty_state()),
            vec!["w1:t0".to_string()]
        );
    }

    #[test]
    fn editor_tabs_are_never_adopted_as_shell() {
        let mut state = empty_state();
        state.editors.insert(
            "/tmp/a.rs".into(),
            EditorEntry {
                tab_id: "w1:t1".into(),
                pane_id: "p1".into(),
            },
        );
        let tabs = tabs(&[("w1:t1", "a.rs"), ("w1:t2", "main")]);
        assert_eq!(choose_shell_tab_id(&state, &tabs).as_deref(), Some("w1:t2"));
    }

    #[test]
    fn dock_ratios_match_split_left_keep() {
        assert!((agent_move_ratio(AGENT_RATIO) - 0.416667).abs() < 1e-6);
        assert!((sidebar_move_ratio(AGENT_RATIO, SIDEBAR_RATIO) - 0.285715).abs() < 1e-6);
        assert!((agent_split_ratio(AGENT_RATIO) - 0.583333).abs() < 1e-6);
        assert!((sidebar_split_ratio(AGENT_RATIO, SIDEBAR_RATIO) - 0.714285).abs() < 1e-6);
    }

    #[test]
    fn dock_plan_agent_then_sidebar_on_shell_tab() {
        let mut state = empty_state();
        state.shell_tab_id = "w1:t1".into();
        state.review_tab_id = "w1:t2".into();
        state.shell_pane_id = "pane-shell".into();
        state.agent_pane_id = "pane-agent".into();
        state.sidebar_pane_id = "pane-sidebar".into();
        let plan = dock_plan(&state, "w1:t1", AGENT_RATIO, SIDEBAR_RATIO).expect("plan");
        assert_eq!(plan.view, CenterView::Shell);
        assert_eq!(plan.center_pane_id, "pane-shell");
        assert_eq!(plan.steps[0].pane_role, "agent");
        assert!(plan.steps[0].swap);
        assert!((plan.steps[0].ratio - 0.416667).abs() < 1e-6);
        assert_eq!(plan.steps[1].pane_role, "sidebar");
        assert!(!plan.steps[1].swap);
        assert!((plan.steps[1].ratio - 0.714285).abs() < 1e-6);
    }

    #[test]
    fn dock_plan_editor_tab_keeps_agent_and_sidebar() {
        let mut state = empty_state();
        state.shell_tab_id = "w1:t1".into();
        state.review_tab_id = "w1:t2".into();
        state.agent_pane_id = "pane-agent".into();
        state.sidebar_pane_id = "pane-sidebar".into();
        state.editors.insert(
            "/tmp/main.rs".into(),
            EditorEntry {
                tab_id: "w1:tE".into(),
                pane_id: "pane-editor".into(),
            },
        );
        let plan = dock_plan(&state, "w1:tE", AGENT_RATIO, SIDEBAR_RATIO).expect("plan");
        assert_eq!(plan.view, CenterView::Editor);
        assert_eq!(plan.center_pane_id, "pane-editor");
        assert_eq!(plan.steps[0].pane_role, "agent");
        assert!(plan.steps[0].swap);
        assert_eq!(plan.steps[1].pane_role, "sidebar");
        assert!(!plan.steps[1].swap);
    }

    #[test]
    fn select_relative_wraps_from_focused_tab() {
        let mut tabs = tabs(&[("w1:t1", "Shell"), ("w1:t2", "Review")]);
        tabs[0].focused = true;
        assert_eq!(select_tab_relative(&tabs, 1).as_deref(), Some("w1:t2"));
        assert_eq!(select_tab_number(&tabs, 1).as_deref(), Some("w1:t1"));
    }
}
