#!/usr/bin/env bats
# The bercail-pane header: bercail's copy of Herdr's pane mod, with focus follows the
# mouse from jankeesvw/herdr-focus-to-hover's follow.js, vendored at a commit
# (bercail/mods/bercail-pane/UPSTREAM.md), behind [layout] focus_follows_mouse.
# Deploy and doctor are in tests/herdr_app_deploy.bats and tests/doctor_herdr_update.bats.

setup() {
  load test_helper
  isolate
  MOD="$ROOT/bercail/mods/bercail-pane"
}

# A copy of the mod that loads in Node: stubbed herdr and gpui modules, where each
# element records its handlers and children. The case on stdin runs after it.
mod_case() {
  need node
  local d="$BATS_TEST_TMPDIR/mod"
  mkdir -p "$d"
  cat >"$d/herdr.mjs" <<'EOF'
const h = () => globalThis.herdr;
export const panes = () => h().panes;
export const props = () => ({ pane: "p1" });
export const run = (name, args) => h().calls.push([name, args]);
export const theme = () => ({});
export const home = () => "/h";
export const layout = () => ({});
export const readTextFile = async (path) => {
  if (!(path in h().files)) throw new Error("no file");
  return h().files[path];
};
EOF
  cat >"$d/gpui.mjs" <<'EOF'
function el(kind) {
  const node = { kind, on: {}, kids: [] };
  const self = new Proxy(node, {
    get(t, k) {
      if (k in t) return t[k];
      return (...a) => {
        if (k === "child") t.kids.push(a[0]);
        else if (k === "when") { if (a[0]) a[1](self); }
        else if (/^on_/.test(k)) t.on[k] = a[a.length - 1];
        return self;
      };
    },
  });
  return self;
}
export class View {}
export const div = () => el("div");
export const svg = () => el("svg");
export const image = () => el("image");
export const h_flex = () => el("h_flex");
EOF
  local f
  for f in main.js follow.js; do
    sed -e 's|from "herdr"|from "./herdr.mjs"|' -e 's|from "gpui-kit"|from "./gpui.mjs"|' \
      -e 's|from "gpui-base"|from "./gpui.mjs"|' -e 's|from "./follow.js"|from "./follow.mjs"|' \
      "$MOD/$f" >"$d/${f%.js}.mjs"
  done
  cat >"$d/prelude.mjs" <<'EOF'
import Pane, { followsMouse } from "./main.mjs";
const fail = (msg) => { console.error(`FAIL: ${msg}`); process.exit(1); };
// The header of pane p1 once it has read config.toml (absent: null), in a window
// that is active or not.
async function header(config, { active = true, focused = false } = {}) {
  globalThis.window = { is_window_active: () => active };
  globalThis.herdr = {
    calls: [],
    panes: [{ pane: "p1", terminal: "t1", focused, program: null, status: null }],
    files: config === null ? {} : { "/h/.config/bercail/config.toml": config },
  };
  const p = new Pane();
  const tasks = [];
  p.init({}, { spawn: (fn) => tasks.push(fn({ notify() {} })) });
  await Promise.all(tasks);
  return p;
}
const calls = () => globalThis.herdr.calls;
// The pointer moves over the pane's body, where only follow's layer hears it.
function move(tree) {
  const layer = tree.kids.find((k) => k.on.on_mouse_move);
  if (!layer) return false;
  layer.on.on_hover(true);
  layer.on.on_mouse_move({}, { timer: { after: () => fail("no delay is set: the pane gets the keyboard at once") } });
  return true;
}
EOF
  cat "$d/prelude.mjs" - >"$d/test.mjs"
  node "$d/test.mjs"
}

@test "focus follows the mouse exactly when bercail's TOML reader reads [layout] focus_follows_mouse = true" {
  local f cli js want
  # shellcheck source=/dev/null
  source "$ROOT/lib/toml.sh"
  # Each fixture as written (LF) and with CRLF line ends: lib/toml.sh reads both alike.
  export FIXTURES="$BATS_TEST_TMPDIR/fixtures"
  mkdir -p "$FIXTURES"
  for f in "$ROOT"/tests/fixtures/focus-follows-mouse/*.toml; do
    cp "$f" "$FIXTURES/"
    sed 's/$/\r/' "$f" >"$FIXTURES/crlf-$(basename "$f")"
  done
  for f in "$FIXTURES"/*.toml; do
    want=false
    [[ "$(toml_get "$f" layout focus_follows_mouse 2>/dev/null)" != true ]] || want=true
    cli+="$(basename "$f") $want"$'\n'
  done
  js="$(mod_case <<'EOF'
import { readdirSync, readFileSync } from "node:fs";
const dir = process.env.FIXTURES;
for (const f of readdirSync(dir).filter((n) => n.endsWith(".toml")).sort()) {
  console.log(`${f} ${followsMouse(readFileSync(`${dir}/${f}`, "utf8"))}`);
}
EOF
)"
  [[ "$js"$'\n' == "$cli" ]] || fail "the pane header and lib/toml.sh disagree:"$'\n'"$(diff <(printf '%s' "$cli") <(printf '%s\n' "$js"))"
  grep -q '^crlf-.* true$' <<<"$cli" && grep -q '^crlf-.* false$' <<<"$cli" || fail "the fixtures must hold both answers, in both line ends"
}

@test "the pane, desk and Shep mods share one reader of config.toml" {
  local mod pane
  # The text of one exported function in a mod's main.js.
  body() { awk -v fn="export function $2(" 'index($0, fn) == 1 { on = 1 } on { print } on && /^}$/ { exit }' "$ROOT/bercail/mods/$1/main.js"; }
  pane="$(body bercail-pane tomlLines)"
  [[ -n "$pane" ]] || fail "bercail-pane has no tomlLines"
  for mod in bercail-desk bercail-shep; do
    [[ "$(body "$mod" tomlLines)" == "$pane" ]] || fail "$mod's tomlLines differs from bercail-pane's: copy it whole"
  done
  [[ "$(body bercail-shep followsMouse)" == "$(body bercail-pane followsMouse)" ]] || fail "bercail-shep's followsMouse differs from bercail-pane's"
}

@test "off, the header is Herdr's: no layer over the pane and no focus on a move" {
  mod_case <<'EOF'
for (const config of [null, "[layout]\nfocus_follows_mouse = false\n"]) {
  const p = await header(config);
  const tree = p.render({});
  if (tree.kind !== "h_flex") fail(`${JSON.stringify(config)}: the header is wrapped in a ${tree.kind}`);
  if (move(tree)) fail(`${JSON.stringify(config)}: a layer listens for the pointer`);
  if (calls().length) fail(`${JSON.stringify(config)}: ran ${JSON.stringify(calls())}`);
}
EOF
}

@test "on, a move over an unfocused pane gives it the keyboard and runs nothing else" {
  mod_case <<'EOF'
const on = "[layout]\nfocus_follows_mouse = true\n";
let p = await header(on);
let tree = p.render({});
if (!tree.kids.some((k) => k.kind === "h_flex")) fail("the layer must keep Herdr's header");
if (!move(tree)) fail("no layer hears the pointer over the pane");
if (JSON.stringify(calls()) !== '[["pane.focus",{"pane":"p1"}]]') fail(`a move ran ${JSON.stringify(calls())}`);

p = await header(on, { focused: true });
move(p.render({}));
if (calls().length) fail(`the focused pane ran ${JSON.stringify(calls())}`);

p = await header(on, { active: false });
move(p.render({}));
if (calls().length) fail(`with another app active, a move ran ${JSON.stringify(calls())}`);
EOF
}

@test "the vendored follow.js is the commit lib/deps.json and UPSTREAM.md record, byte for byte, with both licenses" {
  local known sum
  known="$(jq -r '.[] | select(.name == "herdr-focus-to-hover") | .known' "$ROOT/lib/deps.json")"
  [[ "$known" =~ ^[0-9a-f]{40}$ ]] || fail "lib/deps.json knows no herdr-focus-to-hover commit: $known"
  grep -q "^- Commit: $known " "$MOD/UPSTREAM.md" || fail "UPSTREAM.md names another commit than lib/deps.json ($known)"
  sum="$(sed -n 's/^- follow.js sha256: //p' "$MOD/UPSTREAM.md")"
  [[ "$(sha256sum "$MOD/follow.js" | cut -d' ' -f1)" == "$sum" ]] \
    || fail "follow.js is not the copy UPSTREAM.md records (sha256 $sum); copy upstream's in whole"
  grep -q '^MIT License$' "$MOD/LICENSE" && grep -q 'Copyright (c) 2026 Jankees van Woezik' "$MOD/LICENSE" \
    || fail "upstream's MIT license must ship with follow.js"
  cmp -s "$MOD/LICENSE-APACHE" "$ROOT/bercail/herdr-keys/LICENSE" || fail "Herdr's Apache license must ship with its pane header"
}

@test "the vendored follow.js imports only an element and pane focus, and runs nothing but pane.focus" {
  local imports runs
  imports="$(grep -E '^[[:space:]]*import\b' "$MOD/follow.js")"
  [[ "$imports" == $'import { div } from "gpui-kit";\nimport { panes, run } from "herdr";' ]] \
    || fail "a new commit imports more; read it before shipping: $imports"
  runs="$(grep -oE '\brun\([^,)]*' "$MOD/follow.js" | sort -u)"
  [[ "$runs" == 'run("pane.focus"' ]] || fail "follow.js runs another command: $runs"
  if grep -nE '\b(exec|hc|fetch|readTextFile|writeTextFile|openOverlay|send)\b|import\(' "$MOD/follow.js"; then
    fail "a new commit reaches past focus (a command, the network, a file, input): check it"
  fi
}

@test "the shipped layout frames its panes with the bercail-pane header" {
  jq -e '[.. | objects | select(.content?.tab == "active") | .content.pane.header.content.mod] == ["bercail-pane"]' \
    "$ROOT/bercail/layouts/bercail.json" >/dev/null || fail "the tab block's pane header is not bercail-pane"
}
