# Verification: worker folder-trust pre-registration

Active empirical facts behind `bin/fm-worker-trust.sh`, which pre-registers grok and codex folder trust before `bin/fm-spawn.sh` launches a ship or scout worker into a fresh task worktree.
The per-harness operating facts live in [`references/harness/grok.md`](../../.agents/skills/harness-adapters/references/harness/grok.md) and [`references/harness/codex.md`](../../.agents/skills/harness-adapters/references/harness/codex.md); this record owns how the store keying was established.
Claude and agy have their own helpers and records (`bin/fm-claude-trust.sh`, [`agy.md`](agy.md)).

## Subject

| Field | Value |
|---|---|
| Verified | 2026-10-31 |
| grok | `grok 1.0.13 (5e9a58528b76)` |
| codex | `codex-cli 0.153.4` |
| Platform | Linux x64 (Kali, kernel 6.12.38) |
| Backend | A private tmux server (`tmux -L <name>`), never the fleet's own sessions |

## Method

Each probe ran the real binary in a detached tmux pane whose cwd was a fresh linked worktree of a throwaway repository, under a throwaway store: `HOME=<scratch>/home` (grok, holding copies of only `auth.json`, `config.toml`, and `agent_id`) or `CODEX_HOME=<scratch>/ch` (codex, holding a copy of only `auth.json` plus `check_for_update_on_startup = false`).
The operator's real `~/.grok` and `~/.codex` stores were never read for content or written.
A probe captured the pane after 8 to 10 seconds and recorded whether `Do you trust the contents of this directory?` was on screen.
`<scratch>/main` is the primary checkout and `<scratch>/wt`, `<scratch>/wt2` are linked worktrees created with `git worktree add --detach`.

## grok

grok shows the dialog only when the repository carries a trust-gated resource; a bare repository reached the composer with no dialog, and one committed `.grok/hooks/t.json` made the dialog render.
In a linked worktree the dialog prints the PRIMARY CHECKOUT path, not the worktree:

```
Do you trust the contents of this directory?
<scratch>/main
Grok Build may run or modify contents in this directory,
posing security risks.
Yes, proceed                 y
No, quit                     n
```

Answering `y` wrote exactly this to `<scratch>/home/.grok/trusted_folders.toml` (mode `0600`):

```
[folders."<scratch>/main"]
trusted = true
decided_at = 1793498349
```

Store written ahead of launch, then probed:

| Store entry | Pane cwd | Result |
|---|---|---|
| `<scratch>/wt` only | `<scratch>/wt` | DIALOG |
| `<scratch>/main` only | fresh `<scratch>/wt2` | no dialog |
| `<scratch>/main` only | symlink to `<scratch>/wt2` | no dialog |
| none | `<scratch>/wt2` | DIALOG |
| `<scratch>/wt2` only | `<scratch>/wt2` | DIALOG |
| `<scratch>/main` only, in `GROK_HOME=<scratch>/gh` | `<scratch>/wt2` | no dialog |

So grok keys the decision on the resolved git root, an entry for the worktree path is ignored, and `GROK_HOME` relocates the store.
`bin/fm-worker-trust.sh` therefore records the primary checkout, which is the same entry answering the dialog writes.
The binary also refuses to record an over-broad root (home, filesystem root, or a relative path), which the helper's own scope test mirrors.

## codex

The dialog rendered for every launch posture firstmate uses (`--dangerously-bypass-approvals-and-sandbox`, `--approve-for-me`, and `--sandbox workspace-write --ask-for-approval on-request`, each with `--disable hooks`):

```
Do you trust the contents of this directory? Working with untrusted contents comes with higher risk of prompt injection. Trusting the directory allows
project-local config, hooks, and exec policies to load.
› 1. Yes, continue
  2. No, quit
```

Answering `1` appended this to `<scratch>/ch/config.toml`:

```
[projects."<scratch>/main"]
trust_level = "trusted"
```

Answering `2` wrote nothing.

| Store entry | Pane cwd | Result |
|---|---|---|
| `<scratch>/main` trusted | fresh `<scratch>/wt2` | no dialog |
| `<scratch>/main` trusted | symlink to `<scratch>/wt2` | no dialog |
| `<scratch>/wt2` trusted only | `<scratch>/wt2` | no dialog |
| `<scratch>/wt2` trusted only | symlink to `<scratch>/wt2` | no dialog |
| `<scratch>/main` untrusted, `<scratch>/wt2` trusted | `<scratch>/wt2` | no dialog |
| none | `<scratch>/wt2` | DIALOG |

codex honours an entry for the worktree itself, so the helper records only that narrowest path.
The last row is why the helper refuses when the primary checkout already records a non-`trusted` level: a worktree entry silently overrides it.

## Harnesses with no pre-registration

| Harness | Finding |
|---|---|
| kimi | The store is scriptable in shape (`~/.kimi-code/workspace-trust/wd_<slug>_<sha256-12>` holding `{"root","trustedAt"}`, Kimi Code 2.1.1), but trusting also starts project MCP servers, which spawn deliberately refuses to answer for; the dialog stays answered live. |
| pi | Not pre-registered: trusting the folder loads the project's `.pi/extensions/` into the worker, which in this repository are the primary-supervision extensions, so that trust stays an operator decision. |
| muse, cursor, commandcode, cortex, devin, gemini | A launch flag or environment variable already suppresses the dialog. |
| opencode, omp, rovo, polytoken, kiro | No launch-time folder-trust dialog. |

## Regression

`tests/fm-worker-trust.test.sh` pins the helper's keys, scope refusals, decline refusals, store preservation, and the spawn wiring against throwaway stores.
It cannot prove the vendor keying; rerun the probes above after a grok or codex upgrade before trusting this record.
