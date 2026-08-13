# claude-bell

Terminal notification sound for [Claude Code](https://claude.com/claude-code) running on a **headless server**.

You SSH into a box, kick off a long task, and go read something else. This makes the box beep when Claude finishes or needs your attention — without a sound card, without a desktop, without any daemon.

[中文说明](README.zh-CN.md)

---

## Why not just play a sound?

On a headless VPS there is nothing to play it with. No PCM device (`/dev/snd` has only `seq` and `timer`), so `paplay`/`aplay` are useless. No `DISPLAY`, so `notify-send` goes nowhere.

What *does* work is the oldest trick in the terminal: write a **BEL byte** (`\a`, `0x07`) into the pts that Claude Code is attached to. SSH carries it back over the existing connection, and your local terminal emulator plays a sound.

```
   ┌─────────────────── VPS ────────────────────┐      ┌──────── your PC ─────────┐
   │                                            │      │                          │
   │  Claude Code                               │      │                          │
   │      │ Stop / Notification hook            │      │                          │
   │      ▼                                     │      │                          │
   │  bell.sh ──── writes \a into /dev/pts/N ───┼─SSH──┼──> terminal emulator     │
   │                                            │      │        plays a sound     │
   └────────────────────────────────────────────┘      └──────────────────────────┘
        ^ this repo installs this half                   ^ configure once, applies
                                                           to every host you SSH to
```

The split matters: **the server side is per-machine, the sound is entirely PC-side.** Install this on as many VPSes as you like; you configure your terminal exactly once.

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xiaoma0515/claude-bell/main/install.sh)
```

> Use process substitution, **not** `curl ... | bash`. A piped shell has no controlling terminal, so the post-install self-check reports a false failure and you won't hear the test beep. Same reason you want `ssh -t` if you're driving this remotely.

Or clone it:

```bash
git clone https://github.com/xiaoma0515/claude-bell.git
cd claude-bell && ./install.sh
```

The installer is **idempotent** — re-run it any time to upgrade. It merges into an existing `~/.claude/settings.json` rather than overwriting, strips its own previous entries so beeps never stack up, and backs up anything it touches.

That's the **server half**. There is an optional **PC half**, `install-windows.ps1`, if you want "Claude needs you" to sound genuinely different rather than just beep twice — see [A truly different sound](#a-truly-different-sound-for-claude-needs-you).

```
./install.sh                   install / upgrade
./install.sh --check           preflight only, touches nothing
./install.sh --uninstall       remove the hook and the script
./install.sh --quiet-readline  also silence readline's own bell (see below)
```

## Configure your terminal (the PC half)

Your terminal has to actually make noise when it receives BEL. Once per machine, not per host.

**Windows Terminal** — in `settings.json`, on the profile you use for SSH:

```json
{
  "bellStyle": "audible",
  "bellSound": "C:/Users/you/sounds/ding.wav"
}
```

`bellSound` accepts a path or an array of paths (one is picked at random). Requires Windows Terminal 1.15+. Note it's a *terminal-level* setting — it can't be scoped to Claude Code alone, so anything that rings the bell will play it.

**Others** — the setting is usually called "audible bell":

| Terminal | Where |
|---|---|
| iTerm2 | Settings → Profiles → Terminal → uncheck *Silence bell* |
| macOS Terminal.app | Settings → Profiles → Advanced → *Audible bell* |
| GNOME Terminal | Preferences → your profile → Sound → *Terminal bell* |
| kitty | `enable_audio_bell yes` (`bell_path` for a custom sound) |
| WezTerm | `audible_bell = "SystemBeep"` |
| Alacritty | no built-in sound; use the `bell.command` hook to run a player |

## What triggers it

Two sounds, two meanings:

| Sound | Meaning | Wiring |
|---|---|---|
| **1 beep** | *Your* session finished its turn | `Stop` hook |
| **2 beeps** | Claude is blocked on you: a tool permission, a question, an MCP form, a background agent waiting for input | `Notification` hook, matchers `permission_prompt` / `elicitation_dialog` / `elicitation_url_dialog` / `agent_needs_input` |

And three things that used to beep but no longer do (since 1.2):

- **Subagents and teammates finishing.** A session spawned as a subordinate agent (agent teams, sessions started from the `claude agents` UI) fires `Stop` after *every* message exchange — long before the job you actually care about is done, which made it ring false "done" beeps on your terminal. Spawned sessions carry env markers (`CLAUDE_CODE_SESSION_KIND=bg`, `CLAUDE_BG_SOURCE`, `CLAUDE_CODE_SESSION_NAME`, …) that hooks inherit, so `bell.sh` recognizes where it's running and keeps "done" silent there. Their **permission prompts still ring 2 beeps** — those genuinely need you.
- **The idle echo.** Claude Code fires an `idle_prompt` notification ~60 s after every turn end. Coming right after a "done" beep, that is a duplicate: `bell.sh` records each session's last turn-end time and swallows any `idle_prompt` within 75 s of it. An `idle_prompt` with *no* recent turn end means a dialog has been sitting unanswered — that one rings 2 beeps.
- **Noise notification types.** `auth_success`, `agent_completed`, `elicitation_complete`, … are simply never subscribed.

## A truly different sound for "Claude needs you"

Beep count is one axis; timbre is the other — and over SSH the timbre looks locked, because a BEL can only ever play the one `bellSound` its terminal profile maps it to. The escape hatch: *profiles each have their own* `bellSound`. A second tab on a second profile **is** a second sound.

**Windows Terminal — one command, on your PC:**

```powershell
.\install-windows.ps1
```

It synthesizes a short beep-beep wav (no download), adds a profile that plays it on BEL, and points that profile's command line straight at `bell.sh listen` — so opening the tab *is* the setup, with nothing to type. It reuses your existing SSH profile's command line, backs up `settings.json`, and is safe to re-run. `-Uninstall` removes it again.

```powershell
.\install-windows.ps1 -SshCommand "ssh myserver"   # if auto-detection can't pick
.\install-windows.ps1 -Uninstall
```

**Any other terminal — the same thing by hand:**

1. Duplicate your SSH profile and give the copy a different bell sound (iTerm2, kitty, WezTerm and GNOME Terminal all scope this per profile).
2. Open one tab with that profile, SSH to the box, and run `~/.claude/hooks/bell.sh listen`.

Either way: leave the tab open — it beeps once on connect so you hear what you signed up for. Permission prompts and questions now ring **there**, with that profile's sound; "done" keeps ringing on your session terminal with the original one.

With a listener active, ask/idle drop to a **single** BEL: the timbre now carries the meaning, so the second beep is redundant — and a short "beep-beep" wav gets heard as itself rather than doubled. Without a listener, the two-beep pattern stays, since that's the only signal left.

`listen` registers the tab's pid and tty in `~/.claude/hooks/bell.tty.ask`. The ask/idle paths check it first (strategy 0 below) and fall back to the normal strategies when the listener is gone: closing the tab or losing the SSH connection deregisters it via a trap, and a stale file is ignored after a liveness check. One listener at a time — the most recent `listen` wins.

## "It started beeping at random after I installed this"

Almost certainly **bash**, not Claude Code.

Turning on a bell sound is a *terminal-level* switch. It cannot be scoped to one program, so it applies to every BEL byte the terminal receives — and readline has been quietly emitting them all along. It rings whenever a key can't do anything:

- backspace on an empty line
- left arrow at the start of the line, right arrow at the end
- tab with no completion candidates
- reverse-i-search with no match

This behaviour predates the install by decades. What changed is that you configured your terminal to make BEL audible, so you started *hearing* it. Installing this project is what prompts that, which is why it feels caused by it.

Silence readline without touching this project's beeps:

```bash
./install.sh --quiet-readline
```

That writes `set bell-style none` to `~/.inputrc`. It's safe: `bell.sh` writes BEL straight to the pts device, so readline isn't in that path and the notification beeps still work. If `~/.inputrc` didn't exist, the installer also adds `$include /etc/inputrc` first — creating that file otherwise suppresses your distro's key bindings.

> **The shell you ran it from will keep beeping.** readline parses `~/.inputrc`
> once, at startup, so the session you installed from still holds the old
> setting. Either run `bind -f ~/.inputrc` to apply it immediately, or
> reconnect — new shells are already correct. Check with
> `bind -v | grep bell-style`.

**Not sure whether a beep came from this project?** `bell.sh` logs every invocation. If nothing was appended to `~/.claude/hooks/bell.log` at the moment you heard it, the hook never ran and the sound came from somewhere else.

## Which terminal gets the beep

If you use background agents, other terminals, or several projects at once, **every one of those sessions is a full Claude Code session firing the same global hooks**, because `~/.claude/settings.json` is global. Aiming the BEL is therefore the whole game.

`bell.sh` resolves a target in four steps, and if all fail it stays silent:

0. A registered `listen` terminal — ask/idle only, see the section above.
1. `/dev/tty` — the controlling terminal. Foreground sessions take this.
2. Walk up the process tree for an ancestor that has a tty.
3. The tty owned by a running `claude agents` UI — for permission prompts from sessions that UI spawned, which have no tty anywhere in their ancestry.

There is deliberately **no** "most recently active pts" fallback. An earlier version tried it: the most recently active pts is the window you're currently looking at, so a background session finishing work in some unrelated project rang the bell on your idle foreground terminal. It read as *"it keeps beeping when nothing is running."* When the target is ambiguous (several agents UIs open), `bell.sh` also stays silent rather than guessing. Better to miss a beep than to beep on the wrong terminal.

Diagnosing is easy, because `bell.sh` logs every decision:

```
$ tail ~/.claude/hooks/bell.log
2026-08-13 10:38:19 [done] strategy2 walk found /dev/pts/5      ← your session, rings
2026-08-13 10:38:19 [done] skip: subordinate agent session …    ← teammate turn end, silent
2026-08-13 10:38:20 [idle] skip: idle echo 1s after …           ← duplicate of done, silent
2026-08-13 10:38:20 [ask]  BEL sent to /dev/pts/5               ← needs you, rings
```

## Troubleshooting

| Symptom | Check |
|---|---|
| Beeps when nothing is running | Almost always readline, not a hook — see the section above. `--quiet-readline` fixes it. |
| No sound at all | `tail ~/.claude/hooks/bell.log`. If you see `strategy1`/`strategy2`, the server side worked and the problem is your terminal config. |
| Log says `no controlling tty` | That session is a background agent. Silent by design — see above. |
| A subagent/teammate finishing still rings "done" | `tail bell.log` — a real fix shows `skip: subordinate agent session`. If instead you see `BEL sent`, that spawned session carries none of the known env markers; open an issue with `tr '\0' '\n' < /proc/<pid>/environ \| grep CLAUDE`. |
| Two beeps a minute after every "done" | That's the `idle_prompt` echo the filter should eat — check the log for `skip: idle echo`. If it rings, the state dir `~/.claude/hooks/bell.state.d/` isn't writable. |
| Nothing in the log | The hook isn't wired. Re-run `./install.sh`, and check `~/.claude/settings.json`. |
| Silent inside tmux | tmux swallows BEL: `set -g bell-action any` + `set -g visual-bell off` |
| Silent inside screen | `vbell off` in `~/.screenrc` |
| Beeps but no custom sound | Terminal is falling back to the system beep — check the `bellSound` path exists and is a `.wav`. |
| Works locally, silent over a jump host | Nested SSH forwards the byte stream fine; make sure every hop allocates a tty (`ssh -t`). |

## Requirements

- bash
- `ps` from procps (BusyBox `ps` lacks `-o tty=`; on Alpine: `apk add procps`)
- python3 *or* jq, for safely merging `settings.json`
- Claude Code ≥ 2.1.198 for the `agent_needs_input` notification matcher; older versions ignore unknown matchers, so everything else still works
- an SSH session — this design has nothing to say about local consoles or the web/IDE clients, where there's no pts and it stays silent

## License

MIT
