export const title = "Original-session transport, not job completion";
export const state = (v) => `${v.phase}${v.bound ? "" : ", new session"}`;
export const step = (action) =>
  ({
    Accept: "Follow-up",
    ChangeSession: "Session changed",
    Submit: "Submit DATA",
    Uncertain: "Send uncertain",
    Refuse: "Reject stale",
    Retry: "Unsafe replay",
    Idle: "No change",
  })[action] ?? action;
