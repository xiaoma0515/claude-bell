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
| **1 beep** | A session finished its turn — yours on its own terminal, one you launched from the `claude agents` UI on the terminal that UI runs in | `Stop` hook |
| **2 beeps** | Claude is blocked on you: a tool permission, a question, an MCP form, a background agent waiting for input | `Notification` hook, matchers `permission_prompt` / `elicitation_dialog` / `elicitation_url_dialog` / `agent_needs_input` — plus a `PreToolUse` hook on `AskUserQuestion`, so a question rings the moment it is asked rather than ~7 s later when its notification arrives |

And two things that used to beep but no longer do (since 1.2):

- **The idle echo.** Claude Code fires an `idle_prompt` notification ~60 s after every turn end. Coming right after a "done" beep, that is a duplicate: `bell.sh` records each session's last turn-end time and swallows any `idle_prompt` within 75 s of it. An `idle_prompt` with *no* recent turn end means a dialog has been sitting unanswered — that one rings 2 beeps.
- **Noise notification types.** `auth_success`, `agent_completed`, `elicitation_complete`, … are simply never subscribed.

And two more since 1.4:

- **Stop while background work is in flight.** Claude fires `Stop` every time the main agent yields — including "said something, now waiting for a background subagent". On a long task that rang "done" at every wake-up. The Stop payload carries `background_tasks`; while any of them is running, pending or backgrounded, `bell.sh` treats that Stop as a pause and stays silent. The finish still rings, with the later Stop that has nothing in flight.
- **The second ring of a question.** An `AskUserQuestion` fires `PreToolUse` immediately and a `permission_prompt` notification for the same dialog several seconds later. Both are wired to `ask` — the hook so you hear it at once, the notification as a safety net — and `bell.sh` rings at most once per session per 15 s.

And one thing that rings again since 1.5:

- **Sessions you launch from the `claude agents` UI.** 1.2–1.4 silenced their "done" as *subordinate* sessions, on the theory that a spawned session's turn end is not the end of the job you care about. That fits subagents and teammates; it does not fit an agent you launched yourself, whose turn end is precisely the finish you are waiting for — and the env markers meant to identify spawned sessions (`CLAUDE_CODE_SESSION_KIND=bg`, …) stopped reaching hook processes around Claude Code 2.1.233 anyway. The false "done" that check was written for — a Stop that only pauses for background work — is what the `background_tasks` filter catches. So since 1.5 an agents-UI session rings "done" and "ask" like any other, at the terminal the UI runs in. What it took to make that audible is under [Which terminal gets the beep](#which-terminal-gets-the-beep).

## A truly different sound for "Claude needs you"

Beep count is one axis; timbre is the other — and over SSH the timbre looks locked, because a BEL can only ever play the one `bellSound` its terminal profile maps it to. The escape hatch: *profiles each have their own* `bellSound`. A second tab on a second profile **is** a second sound.

**Windows Terminal — one command, on your PC:**

```powershell
powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
```

(Plain `.\install-windows.ps1` works too *if* your execution policy already allows local scripts. Windows ships as `Restricted`, where running a `.ps1` fails with "running scripts is disabled on this system" — the `-ExecutionPolicy Bypass` form sidesteps that for this one run without changing any machine setting.)

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

Each alert also prints one line in that tab, so it doubles as a log of what wanted you:

```
[10:32:49] myproject · AskUserQuestion · Which IP is right?
[10:41:07] myproject · permission_prompt · Claude needs your permission to use Bash
```

Wiring `listen` into a profile by hand: keep every argument your normal SSH profile uses (a non-default `-p` port included) and add `-t` — ssh gives a command no tty otherwise, and without one the listener cannot ring; it says so and waits 30 s before exiting, so the tab doesn't just flash. A path relative to the remote home sidesteps the different `~` quoting rules of cmd, PowerShell and bash:

```
ssh -t -p 22 you@host .claude/hooks/bell.sh listen
```

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
3. The tty owned by a running `claude agents` UI — for the sessions that UI launched. The background daemon hosts each of them on a pty of its own (session → `claude bg-pty-host` → `claude daemon run`). That pty is the session's controlling terminal, so it satisfies steps 1 and 2 — but nothing is attached to it, and a BEL written there is never heard. `bell.sh` therefore looks for the daemon host in its ancestry *before* steps 1 and 2 and, on finding it, skips straight here (log: `daemon-hosted session …`).

There is deliberately **no** "most recently active pts" fallback. An earlier version tried it: the most recently active pts is the window you're currently looking at, so a background session finishing work in some unrelated project rang the bell on your idle foreground terminal. It read as *"it keeps beeping when nothing is running."* When the target is ambiguous (several agents UIs open), `bell.sh` also stays silent rather than guessing. Better to miss a beep than to beep on the wrong terminal.

Diagnosing is easy, because `bell.sh` logs every decision:

```
$ tail ~/.claude/hooks/bell.log
2026-09-08 12:11:39 [done] strategy2 walk found /dev/pts/5        ← your session, rings
2026-09-08 12:12:44 [done] skip: 1 background task(s) in flight …  ← only a pause, silent
2026-09-08 12:13:44 [idle] skip: idle echo 60s after …             ← duplicate of done, silent
2026-09-08 12:15:02 [done] daemon-hosted session (ancestor pid 3903217: claude bg-pty-host), …
2026-09-08 12:15:02 [done] strategy3 agents UI tty /dev/pts/0      ← agents-UI session finished, rings where the UI is
2026-09-08 12:15:20 [ask]  BEL sent to /dev/pts/5                  ← needs you, rings
```

## Troubleshooting

| Symptom | Check |
|---|---|
| Beeps when nothing is running | Almost always readline, not a hook — see the section above. `--quiet-readline` fixes it. |
| No sound at all | `tail ~/.claude/hooks/bell.log`. If you see `strategy1`/`strategy2`/`strategy3` followed by `BEL sent`, the server side worked and the problem is your terminal config. |
| Log says `no controlling tty` | A background session with nowhere to ring: no terminal in its ancestry and no `claude agents` UI open. Silent by design — see above. |
| An agents-UI session finishing is silent | `tail bell.log`. Since 1.5 you should see `daemon-hosted session …` followed by `strategy3 agents UI tty`. `strategy2 walk found` instead means the daemon's host process no longer says `bg-pty-host` / `bg-spare` in its argv — open an issue with `ps -o pid,ppid,tty,args -p <session pid>` and the same for its parent. `no controlling tty` means no agents UI was open. |
| Two beeps a minute after every "done" | That's the `idle_prompt` echo the filter should eat — check the log for `skip: idle echo`. If it rings, the state dir `~/.claude/hooks/bell.state.d/` isn't writable. |
| Nothing in the log | The hook isn't wired. Re-run `./install.sh`, and check `~/.claude/settings.json`. |
| Silent inside tmux | tmux swallows BEL: `set -g bell-action any` + `set -g visual-bell off` |
| Silent inside screen | `vbell off` in `~/.screenrc` |
| Beeps but no custom sound | Terminal is falling back to the system beep — check the `bellSound` path exists and is a `.wav`. |
| Works locally, silent over a jump host | Nested SSH forwards the byte stream fine; make sure every hop allocates a tty (`ssh -t`). |
| The alerts tab says "no terminal attached" and closes | Its command line lacks `-t`: `ssh host <cmd>` allocates no tty, `ssh -t host <cmd>` does. |
| The alerts tab times out while your session tab connects fine | The box's sshd is on a non-default port and the alerts command line dropped the `-p`. Copy the session profile's full ssh arguments. |
| "done" rings again and again during one long task | Each ring is a Stop while a background subagent runs. Since 1.4 the log shows `skip: … in flight`; if it still rings, your Claude Code predates the `background_tasks` field in the Stop payload. |

## Requirements

- bash
- `ps` from procps (BusyBox `ps` lacks `-o tty=`; on Alpine: `apk add procps`)
- python3 *or* jq, for safely merging `settings.json`
- python3 at runtime is optional: with it the listener line carries the question text and the in-flight check parses the payload; without it both degrade gracefully
- Claude Code ≥ 2.1.198 for the `agent_needs_input` notification matcher; older versions ignore unknown matchers, so everything else still works
- an SSH session — this design has nothing to say about local consoles or the web/IDE clients, where there's no pts and it stays silent

## License

MIT
