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

| Hook | When | Sound |
|---|---|---|
| `Stop` | Claude finishes a turn | one beep |
| `Notification` | Claude wants your attention (permission prompt, idle) | two beeps |

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

## Background agents stay silent — on purpose

If you use background agents, other terminals, or several projects at once, **every one of those sessions is a full Claude Code session firing its own `Stop` hook**, because `~/.claude/settings.json` is global.

An earlier version had a third fallback strategy: if a session has no controlling terminal (which is exactly the case for background agents, since they're children of a detached daemon), aim the BEL at "the most recently active login pts". That sounds reasonable and is a bug. The most recently active pts is *the window you're currently looking at* — so a background agent finishing work in some unrelated project rings the bell on your idle foreground terminal. It reads as **"it keeps beeping when nothing is running."**

So `bell.sh` has exactly two strategies, and no fallback:

1. `/dev/tty` — the controlling terminal.
2. Walk up the process tree for an ancestor that has a tty.

Both failing means there is no terminal that legitimately belongs to this session, and it exits silently. The trade-off is real and deliberate: background work finishes quietly, and you check on it yourself. Better than beeping on the wrong terminal.

Diagnosing is easy, because `bell.sh` logs which strategy won:

```
$ tail ~/.claude/hooks/bell.log
2026-07-18 09:19:11 [done] strategy2 walk found /dev/pts/5    ← foreground, correct
2026-07-18 09:11:25 [done] skip: no controlling tty           ← background, silent
```

## Troubleshooting

| Symptom | Check |
|---|---|
| Beeps when nothing is running | Almost always readline, not a hook — see the section above. `--quiet-readline` fixes it. |
| No sound at all | `tail ~/.claude/hooks/bell.log`. If you see `strategy1`/`strategy2`, the server side worked and the problem is your terminal config. |
| Log says `no controlling tty` | That session is a background agent. Silent by design — see above. |
| Nothing in the log | The hook isn't wired. Re-run `./install.sh`, and check `~/.claude/settings.json`. |
| Silent inside tmux | tmux swallows BEL: `set -g bell-action any` + `set -g visual-bell off` |
| Silent inside screen | `vbell off` in `~/.screenrc` |
| Beeps but no custom sound | Terminal is falling back to the system beep — check the `bellSound` path exists and is a `.wav`. |
| Works locally, silent over a jump host | Nested SSH forwards the byte stream fine; make sure every hop allocates a tty (`ssh -t`). |

## Requirements

- bash
- `ps` from procps (BusyBox `ps` lacks `-o tty=`; on Alpine: `apk add procps`)
- python3 *or* jq, for safely merging `settings.json`
- an SSH session — this design has nothing to say about local consoles or the web/IDE clients, where there's no pts and it stays silent

## License

MIT
