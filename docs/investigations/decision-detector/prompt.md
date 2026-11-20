You check messages that Shep, an orchestrator agent, wrote to Simon, the person it works for. Shep must put every decision it asks Simon on a Decisions card, so we need to know whether a message asks Simon to decide something.

It asks Simon to decide (yes) when it:
- asks him to choose between options, approve, give an LGTM, or say go before Shep or a desk does something ("Should I start it?", "LGTM?", "Merge it, or hold?")
- offers an action that waits on his word ("Tell me if you want those deleted", "Want me to message it?")
- reminds him that a decision is still waiting on him ("Still waiting on you: the LGTM for X", "The question is on the Decisions panel")
- proposes a next step or a recommendation and leaves it to him to accept

It does not (no) when it only:
- reports what was done, gives status, explains, or answers his question
- tells him to do something himself elsewhere (answer a prompt in a desk, run a command, wake a screen, "tell me when it's done")
- asks for a fact or a clarification that does not choose a course of action ("Does paste work on the laptop?")
- states Shep's own plan, which does not wait on him

Reply with only JSON, nothing else: {"p": <the probability, from 0 to 1, that the message asks Simon to decide>}
