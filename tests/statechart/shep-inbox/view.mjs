// The chart in Simon's words: where the desk's finish is. One region, and edge
// labels under 20 characters, so Pi draws it in an 80-column pane. Each function
// depends only on its arguments; the statechart command calls them once per state
// or step.
const saved = (v, i) => Object.values(v.saved).some((s) => s.includes(i));
const live = (v) => Object.values(v.pc).filter((pc) => pc !== "down" && pc !== "paused").length;

function item(v, i) {
  const loc = v.loc[i];
  if (loc === "none") return null;
  if (loc === "inbox") return "waiting in the inbox";
  if (v.receipt[i]) return "acknowledged";
  if (saved(v, i)) return "saved in Shep's session";
  if (Object.values(v.unsaved).some((s) => s.includes(i))) return "on screen, not saved yet";
  if (Object.values(v.queue).some((q) => q.includes(i))) return "queued for Shep's turn";
  if (v.attempt[i] === 0) {
    const mine = Object.keys(v.pc).some((p) => v.pc[p] !== "down" && v.sess[p] === v.claimer[i]);
    return mine || v.claimer[i] === 0 ? "claimed, not sent yet" : "claimed by a Shep that crashed";
  }
  return "sent, then lost in a crash";
}

export const state = (v) => {
  const e = v.follower === "idle" ? "desk working" : v.follower === "missed" ? "finish missed" : item(v, "E");
  // Only the no-lock plant gets here; OneConsumer breaks in these states.
  const both = live(v) > 1 ? " (two Sheps)" : "";
  if (v.loc.N) return { Event: e + both, Notice: item(v, "N") ?? "none" };
  return e + both;
};

export const step = (action, from, to) => {
  if (action === "Reconcile") return from.loc.N === to.loc.N ? "checks for gaps" : "makes a notice";
  if (action === "Send" && JSON.stringify(from.queue) === JSON.stringify(to.queue)) return "nothing to send";
  if (action === "PiShows") {
    const fresh = Object.keys(to.unsaved).some((s) => to.unsaved[s].length > from.unsaved[s].length);
    return fresh ? "you see it, unsaved" : "you see it, saved";
  }
  return (
    {
      FollowerWritesEvent: "desk finishes",
      FollowerMissesEvent: "follower misses it",
      FollowerWritesSource: "follower marks done",
      ShepStarts: "Shep starts",
      ShepCrashes: "Shep crashes",
      Claim: "Shep claims it",
      Send: "Shep queues it",
      PiEndsTurn: "Shep replies",
    }[action] ?? action
  );
};

export const group = (v) =>
  v.loc.E === "delivered" && v.receipt.E ? "done" : v.follower === "idle" ? "before" : "flight";
export const colors = { before: "blue", flight: "orange", done: "teal" };
export const title = "Shep inbox: one desk finish";
