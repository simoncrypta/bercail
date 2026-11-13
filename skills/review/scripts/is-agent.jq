# A tuicr comment an agent wrote, by its author name. Humans default to "user".
def is_agent:
  ((.author // .username // "user") | ascii_downcase) as $a
  | $a == "pi" or $a == "agent"
    or $a == "claude" or $a == "gpt" or $a == "grok" or $a == "copilot"
    or ($a | startswith("claude"));
