// The chart in Simon's words: one routine's run, seen from one run of it (run
// 1). A second run of the same routine and other routines' runs show only where
// they change what run 1 does: the overlap and load skips.
const outcome = { emitted: "Emitted", quiet: "Skipped", skipped: "Skipped", failed: "Failed" };

export const state = (v) => {
  const pc = v.pc[1];
  if (pc === "idle") return v.paused.a ? "Paused" : "Scheduled";
  if (pc === "due" || pc === "locked") return "Due";
  if (pc === "running") return "Running";
  return outcome[pc];
};

// A crash (a reboot, kill -9) can end a run in any state; the chart hides
// those steps. full.cfg checks them.
export const step = (action, from, to) => {
  if (action === "Crash") return null;
  if (action === "QueryEnds") return to.pc[1] === "emitted" ? "new findings" : "nothing new";
  if (action === "Finish") {
    if (from.pc[1] === "failed" && to.paused.a && !from.paused.a) return "3rd failure";
    return from.pc[1] === "emitted" ? "event, run logged" : "run logged";
  }
  return (
    {
      Start: "it comes due",
      SkipPaused: "it is paused",
      SkipOverlap: "already running",
      SkipLoad: "no free slot",
      TakeSlot: "takes its locks",
      QueryFails: "fails or times out",
      YouPause: "you pause it",
      YouResume: "you resume it",
    }[action] ?? action
  );
};

export const group = (v) => (v.paused.a ? "paused" : v.pc[1] === "idle" ? "rest" : "run");
export const colors = { rest: "blue", run: "orange", paused: "pink" };
export const title = "A routine run";
