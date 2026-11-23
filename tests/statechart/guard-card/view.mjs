// The chart in Simon's words: one guard card, from the worker's start to its
// guard event. The class flipping and a moved fact show only where they change
// what the card does.
const ended = {
  ran: "ran on your Allow",
  "ran-default": "ran by default",
  "ran-optin": "ran with no card",
  denied: "denied: nothing ran",
  expired: "expired: a Deny, nothing ran",
  withdrawn: "closed: nothing ran",
  changed: "changed: nothing ran",
  none: "not run",
};

export const state = (v) => {
  if (v.pc === "dead") return v.runs > 0 ? "ran, then the worker died" : "worker died: nothing runs";
  if (v.pc === "done") return ended[v.event];
  if (v.pc === "guard") return v.optIn ? "asked, repo opts in" : "asked";
  if (v.pc === "classify" || v.pc === "create") return "card going up";
  if (v.pc === "deadline") return v.said === "defaults" ? "deadline: class read again" : "deadline: it waited";
  if (v.answer === "default") return "defaulted to Allow";
  if (v.answer === "allow") return "you allowed it";
  if (v.answer === "deny") return "you denied it";
  if (v.status === "withdrawn") return "you closed it";
  return v.said === "defaults" ? "defaults to Allow at HH:MM" : "waits for you";
};

// The world's own steps (the deadline, a flip, a moved fact) change no state
// the chart shows unless they make the card move; their arrows are labeled.
export const step = (action, from, to) =>
  action === "Pick"
    ? `you ${to.answer === "allow" ? "Allow" : "Deny"}`
    : action === "SeesDeadline" && from.status !== "pending"
      ? "stale read"
      : ({
          GuardDecides: to.pc === "done" ? "reads private" : "to a card",
          Tick: "deadline passes",
          Doze: "sleeps past it",
          Lag: "worker late",
          Watch: "watches it",
          Flip: "class flips",
          Move: "a fact moves",
          YouAllow: "you Allow",
          YouDeny: "you Deny",
          YouClose: "you Close",
          Classify: "reads the class",
          CardUp: "card up",
          SeesWithdrawn: "sees it closed",
          SeesDeny: "sees your Deny",
          SeesAllow: "claims it",
          SeesMoved: "sees it moved",
          SeesDeadline: "deadline passes",
          Default: to.answer === "default" ? "records default" : "you picked first",
          Expire: to.pc === "done" ? "withdraws: a Deny" : "you picked first",
          Claim: to.pc === "check" ? "claims it once" : "already claimed",
          LastCheck: to.pc === "run" ? "last check holds" : "last check fails",
          Run: "runs it once",
          Crash: "worker dies",
        }[action] ?? action);

export const group = (v) => (v.pc === "done" || v.pc === "dead" ? "end" : v.status === "pending" ? "wait" : "act");
export const colors = { wait: "blue", act: "orange", end: "teal" };
export const title = "A guard card";
