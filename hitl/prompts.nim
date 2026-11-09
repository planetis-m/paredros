## The two model prompts, exactly as brief.py words them (SPLIT and PROMPT).
## The names in braces are filled in by briefs.fill.

const
  SplitPrompt* = """
You sort the material of a Claude Code session into work items, for a human who
reviews the work. A work item is one piece of work they may want to review or
decide on: a bug fixed, a module or file ported, a feature, a design change.

Below are the existing items, then material not yet sorted (or grown since).
Each line starts with a handle. Answer with "items" (each: an existing item's
id, or 0 for a new item with a title; and the handles of its sources) and
"housekeeping" (the handles you leave out as housekeeping).

Rules:
- Put material in an existing item (its id) when it continues that work: a
  review of it, a redo, a follow-up commit. Otherwise start a new item (id 0)
  with a title: at most 10 plain words naming the thing, sentence case, no
  numbers or handles.
- An agent (A) or a commit (C) goes to at most one item. A commit marked "by A2"
  goes where A2 goes. A turn (T) may go to several items, or to none.
- Leave out housekeeping: it is no piece of work. Housekeeping is status
  checks, tooling chatter, filing or updating bug reports, editing notes,
  ledgers or prompts, and combining reviewed branches for upstream. List each
  agent (A) or commit (C) you leave out as housekeeping under "housekeeping";
  every other agent and commit goes into an item.

{existing}

{material}
"""

  BriefPrompt* = """
You write a decision brief about one work item from a Claude Code session, for
{reader}, who must make the decisions themselves, from facts, without being
overloaded.

Below are the sources: what the human and the session said, the final reports
of the agents that worked on it, and the diff of its current code (it may be
cut short; the files are in the repository). The repository is your working
directory; you may read files in it, but do not run anything and do not
change anything. {spec_line}

Answer in the JSON schema you were given. "summary" is one sentence on the
outcome: what the current code does and what is left; never restate the title.

Rules:
- Every text at most 25 words. Plain words, no hype. Code in backticks.
- Write every item, in every list, for a reader who has NOT read the agents'
  reports. Say what would behave differently for {users}. Never use the
  agents' private names: scratch, test, review or case file names (say "the
  example" or "a new test" instead), internal numbering, or internal function
  names unless the function is itself the point. If an item cannot be said
  that way, leave it out.
- Describe the current code only. An earlier attempt is not the current code;
  if it matters, say so in one plain needs_review item.
- Only what the sources support. "source" is one short plain phrase that
  reads after "From", in lower case, naming the evidence: who said it and,
  if the spec, which part. Examples: "the session and the first review";
  "the agent's report; spec: Ref types (read directly)"; "the current code".
  Write "(read directly)" when you read the spec yourself. Never a time or
  date, no file paths except a source file when it is the point.
- open_decisions is the most important list and must be short. A question
  belongs there only if BOTH hold:
  1. Nothing settles it: not the spec, not the repository's conventions, not
     the instructions and skills the agents follow (CLAUDE.md, .claude/skills/),
     not the evidence in the sources. If any of these settles it, it is NOT
     open: put it under decisions_made with that rule or evidence as "why".
  2. It changes what {users} see or can do, or the project's design.
     Questions about test files, message counts, code style, an internal
     helper, or keeping a small change consistent are never open decisions.
  Write each question so someone who has not read the reports understands it.
  "recommended" is the index (from 0) of the option you recommend, or -1 if
  none of them; "reason" is the one reason, without restating the option.
  {spec_rule}
  Never write "I checked"; put that in source. If the session asked the human
  a question that meets both tests, include it; leave out questions about
  other items, tooling and housekeeping.
- Never mention logistics anywhere: PRs, pushing, branches, CI, commit hashes.
  Say "the current code" and "an earlier attempt" instead.
- needs_review: code that changed after its last review, review findings not
  addressed, claims nobody verified.
- spec_conflicts: {conflict_rule}
- bug_risks: regressions found, cases the change may break, side findings.
- The human's opinion is guidance, not the answer: report it as a source,
  never as the decision.
- Empty lists are fine. List every item that meets the bar, the most
  important first.
- open_decisions: at most 3 options, each under 10 words.

{sources}
"""
