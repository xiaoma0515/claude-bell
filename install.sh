#!/usr/bin/env bash
# ============================================================================
#  claude-bell — terminal notification sound for Claude Code on headless boxes
#
#  A headless server has no sound card and no DISPLAY, so `paplay` and
#  `notify-send` are both dead ends. What does work: write a BEL byte (\a)
#  into the pts that Claude Code is attached to. SSH carries it back to your
#  local terminal emulator, which plays a sound.
#
#      VPS: bell.sh writes \a ──SSH byte stream──> PC: terminal plays a sound
#           ^ this installer sets up this half     ^ configure once on your PC,
#                                                    applies to every host
#
#  Usage:
#      ./install.sh                   install / upgrade (idempotent)
#      ./install.sh --check           preflight only, touches nothing
#      ./install.sh --uninstall       remove hook and script
#      ./install.sh --quiet-readline  also silence readline's own bell
#
#  Remote one-liner:
#      bash <(curl -fsSL https://raw.githubusercontent.com/xiaoma0515/claude-bell/main/install.sh)
#
#      Use process substitution, not `curl ... | bash`. A piped shell has no
#      controlling terminal, so the post-install self-check will report a
#      false failure (and you won't hear the test beep).
# ============================================================================
set -uo pipefail

VERSION=1.3.0

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOOK_DIR="$CLAUDE_DIR/hooks"
BELL="$HOOK_DIR/bell.sh"
SETTINGS="$CLAUDE_DIR/settings.json"

c_ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
c_warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
c_err()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
hdr()    { printf '\n\033[1m%s\033[0m\n' "$*"; }

MODE=install
QUIET_READLINE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall)      MODE=uninstall ;;
    --check)          MODE=check ;;
    --quiet-readline) QUIET_READLINE=1 ;;
    --version)        echo "claude-bell $VERSION"; exit 0 ;;
    --help|-h)        sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                c_err "unknown argument: $1 (try --help)"; exit 2 ;;
  esac
  shift
done

# Would readline ring an audible bell? Its default is audible, and once you
# have configured your terminal to play a sound on BEL, every readline bell
# becomes audible too: backspace on an empty line, arrow key at the edge of
# the line, tab with no completion. None of that involves this project, but
# it starts being heard the moment you set this up — so we surface it.
readline_bell_audible() {
  local f v
  for f in "$HOME/.inputrc" /etc/inputrc; do
    [ -f "$f" ] || continue
    v=$(grep -iE '^[[:space:]]*set[[:space:]]+bell-style' "$f" | tail -1 | awk '{print $3}')
    if [ -n "$v" ]; then
      [ "$v" = audible ] && return 0 || return 1
    fi
    # A ~/.inputrc that exists but is silent on bell-style still wins: bash
    # does not read /etc/inputrc once ~/.inputrc is present (absent $include).
    [ "$f" = "$HOME/.inputrc" ] && return 0
  done
  return 0  # readline's built-in default
}

apply_quiet_readline() {
  local rc="$HOME/.inputrc"
  if [ -f "$rc" ] && grep -qiE '^[[:space:]]*set[[:space:]]+bell-style[[:space:]]+none' "$rc"; then
    c_ok "~/.inputrc already sets bell-style none"
    return
  fi
  if [ -f "$rc" ]; then
    cp -p "$rc" "$rc.bak.$(date +%Y%m%d%H%M%S)"
  else
    # Creating ~/.inputrc suppresses /etc/inputrc entirely, which would drop
    # the distro's key bindings (Home/End/Delete on many systems). Pull it
    # back in explicitly.
    [ -f /etc/inputrc ] && printf '$include /etc/inputrc\n' > "$rc"
  fi
  cat >> "$rc" <<'RC'

# Silence readline's own bell: empty-line backspace, arrow key at the edge of
# the line, tab with no completion. Unrelated to claude-bell, which writes BEL
# straight to the pts and is unaffected by this.
set bell-style none
RC
  c_ok "added 'set bell-style none' to ~/.inputrc"
  RELOAD_NEEDED=1
}

# readline parses ~/.inputrc once, at shell startup. The shell that ran this
# installer therefore keeps its old setting and keeps beeping — which reads as
# "I ran it and it still beeps". Say so loudly rather than in passing.
warn_reload_needed() {
  [ "${RELOAD_NEEDED:-0}" = 1 ] || return 0
  printf '\n\033[33m┌─ readline: your CURRENT shell is not updated yet ─────────────┐\033[0m\n'
  printf '\033[33m│\033[0m readline reads ~/.inputrc only at startup, so this shell\n'
  printf '\033[33m│\033[0m keeps beeping until you do one of:\n'
  printf '\033[33m│\033[0m\n'
  printf '\033[33m│\033[0m     \033[1mbind -f ~/.inputrc\033[0m      ← applies right now\n'
  printf '\033[33m│\033[0m     reconnect                ← new shells are already fine\n'
  printf '\033[33m│\033[0m\n'
  printf '\033[33m│\033[0m Verify with:  bind -v | grep bell-style\n'
  printf '\033[33m└──────────────────────────────────────────────────────────────┘\033[0m\n'
}

# ------------------------------------------------------------------ preflight
hdr "Preflight"
FATAL=0

if [ -n "${BASH_VERSION:-}" ]; then
  c_ok "bash $BASH_VERSION"
else
  c_err "not running under bash — re-run with: bash install.sh"; FATAL=1
fi

# Hard requirement: procps-style ps. BusyBox ps does not support -o.
if ps -o tty= -p $$ >/dev/null 2>&1 && ps -o ppid= -p $$ >/dev/null 2>&1; then
  c_ok "ps supports -o tty= / -o ppid="
else
  c_err "ps lacks -o tty= (BusyBox?) — install procps"; FATAL=1
fi

if command -v python3 >/dev/null 2>&1; then
  c_ok "python3 (for merging settings.json)"
  JSON_TOOL=python3
elif command -v jq >/dev/null 2>&1; then
  c_ok "jq (for merging settings.json)"
  JSON_TOOL=jq
else
  c_err "need python3 or jq to merge settings.json safely"; FATAL=1; JSON_TOOL=none
fi

if command -v claude >/dev/null 2>&1; then
  c_ok "claude: $(command -v claude)"
else
  c_warn "claude not on PATH — the hook installs fine but nothing will fire it"
fi

# Non-fatal, but each of these silently swallows the bell.
if [ -n "${TMUX:-}" ]; then
  c_warn "inside tmux — it eats BEL by default. Add to ~/.tmux.conf:"
  printf '        set -g bell-action any\n        set -g visual-bell off\n'
fi
if [ -n "${STY:-}" ]; then
  c_warn "inside screen — add to ~/.screenrc:  vbell off"
fi
if [ -z "${SSH_TTY:-}" ] && [ -z "${SSH_CONNECTION:-}" ]; then
  c_warn "doesn't look like an SSH session; this design relies on SSH carrying"
  c_warn "the BEL back to a local terminal emulator"
fi

if readline_bell_audible; then
  if [ "$QUIET_READLINE" = 1 ]; then
    c_ok "readline bell is audible — will silence it (--quiet-readline)"
  else
    c_warn "readline's bell is audible (its default). Once your terminal plays a"
    c_warn "sound on BEL, bash itself will beep on empty-line backspace, on an"
    c_warn "arrow key at the edge of the line, and on tab with no completion."
    c_warn "Those are not Claude Code. Re-run with --quiet-readline to silence"
    c_warn "them; it does not affect this project's beeps."
  fi
else
  c_ok "readline bell already silenced"
fi

[ "$FATAL" = 1 ] && { hdr "Preflight failed, aborting"; exit 1; }
[ "$MODE" = check ] && { hdr "Preflight passed (--check: nothing was modified)"; exit 0; }

# ------------------------------------------------------------------ uninstall
if [ "$MODE" = uninstall ]; then
  hdr "Uninstall"
  if [ -f "$SETTINGS" ] && command -v python3 >/dev/null 2>&1; then
    cp -p "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
    python3 - "$SETTINGS" <<'PY'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
hooks = cfg.get("hooks", {})
for ev in list(hooks):
    groups = []
    for g in hooks[ev]:
        inner = [h for h in g.get("hooks", []) if "bell.sh" not in h.get("command", "")]
        if inner:
            g["hooks"] = inner
            groups.append(g)
    if groups: hooks[ev] = groups
    else:      del hooks[ev]
if not hooks: cfg.pop("hooks", None)
with open(p, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
    c_ok "removed bell.sh hooks from settings.json (backup kept)"
  fi
  rm -f "$BELL" && c_ok "removed $BELL"
  hdr "Done"
  exit 0
fi

# --------------------------------------------------------------- write bell.sh
hdr "Installing bell.sh"
mkdir -p "$HOOK_DIR"
[ -f "$BELL" ] && cp -p "$BELL" "$BELL.bak.$(date +%Y%m%d%H%M%S)"

cat > "$BELL" <<'BELL_EOF'
#!/usr/bin/env bash
# Claude Code notification bell — usage: bell.sh [done|ask|idle|listen]
# Generated by claude-bell's install.sh. Don't edit; reinstalling overwrites it.
#
# Headless box: no sound card, no DISPLAY. Write BEL (\a) into the pts the
# user is on; SSH carries it to the local terminal emulator, which plays a
# sound.
#
# Two meanings, two sounds:
#   done (1 beep)   Stop hook — YOUR session finished its turn.
#                   Suppressed inside subordinate agent sessions (teammates,
#                   sessions spawned by the agents UI/daemon): their Stop
#                   fires after every message exchange, long before the
#                   overall job is done, and used to ring the lead terminal
#                   as a false "done".
#   ask  (2 beeps)  Notification hook — Claude is blocked on YOU: approve a
#                   tool, answer a question, fill an MCP form. Wired via
#                   typed matchers (permission_prompt, elicitation_dialog,
#                   elicitation_url_dialog, agent_needs_input), so noise
#                   types (auth_success, agent_completed, …) never fire it.
#                   NOT suppressed in subordinate sessions: their permission
#                   prompts need you just the same.
#   idle            Notification hook, idle_prompt type. Claude Code fires it
#                   ~60 s after every turn end; right after a done beep that
#                   is pure echo → suppressed, using a per-session timestamp
#                   the done path records. An idle_prompt with NO recent turn
#                   end means a dialog has been sitting unanswered (e.g. a
#                   question you did not hear about any other way) → sounds
#                   like ask.
#   attention       Pre-1.2 alias of ask, kept so an old settings.json still
#                   works with a new script.
#   listen          Not a hook: run it BY HAND in a spare terminal tab to make
#                   that tab the dedicated "Claude needs you" sound. A BEL can
#                   only ever play the one bellSound its terminal profile maps
#                   it to — the timbre cannot be switched per event over SSH.
#                   But terminal profiles each have their OWN bellSound, so a
#                   second tab on a second profile IS a second sound: `listen`
#                   registers the tab's tty, and ask/idle beeps are routed
#                   there instead of the session terminal. Close the tab (or
#                   lose the connection) and everything falls back to the
#                   normal single-sound behavior.
#
# How the script knows it runs inside a subordinate session: spawned agent
# sessions carry env markers (CLAUDE_CODE_SESSION_KIND=bg, CLAUDE_BG_SOURCE,
# CLAUDE_BG_BACKEND, CLAUDE_CODE_SESSION_NAME) and hook commands inherit the
# session process's environment. A session you started yourself has none.
#
# Three strategies for locating the tty:
#   1. /dev/tty — the controlling terminal. Foreground sessions take this.
#   2. Walk up the process tree looking for an ancestor that has a tty.
#   3. The tty owned by a running `claude agents` UI, for the sessions it
#      spawned, which have no tty of their own anywhere in their ancestry.
#   All three failing means there is no terminal to aim at → exit silently.
#
# Why 1 and 2 are not enough: a session launched from the agents UI hangs off
# the background daemon, not off the terminal. Its ancestry is
# session → bg-pty-host → daemon → init, with no tty at any level, so the walk
# in strategy 2 always comes up empty and every agent task finished in silence.
# The UI process itself does own a tty, and that is exactly the screen the user
# is watching while agent work runs — hence strategy 3.
#
# Why there is still deliberately no "fall back to the most recently active
# login pts" strategy (this was tried, and it was a bug): settings.json is
# global, and one machine often runs several Claude sessions at once
# (background agents, other projects' sessions). Every one of them fires its
# own Stop hook. A fallback aims the BEL at whichever pts was most recently
# active — which is the idle window the user happens to be staring at. It
# shows up as "it keeps beeping when nothing is running". Strategy 3 is not
# that fallback: it targets one specific process rather than the liveliest
# terminal, and when the target is ambiguous it stays silent instead of
# guessing. Better to miss a beep than to beep on the wrong terminal.
#
# Gotcha: do NOT test with `[ -w /dev/tty ]`. /dev/tty is mode 0666, so
# access(2) always succeeds, but open() returns ENXIO when the process has no
# controlling terminal. You have to actually try to open it, or strategy 1
# false-positives and strategy 2 never runs.

pattern="${1:-done}"
cfg_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
log="$cfg_dir/hooks/bell.log"
state_dir="$cfg_dir/hooks/bell.state.d"
say() { echo "$(date '+%F %T') [$pattern] $*" >> "$log"; }

# Keep the log from growing without bound.
if [ -f "$log" ] && [ "$(wc -l < "$log" 2>/dev/null || echo 0)" -gt 2000 ]; then
  tail -n 500 "$log" > "$log.tmp" 2>/dev/null && mv "$log.tmp" "$log"
fi

# --- hook payload ---
# Claude Code pipes the event JSON to the hook's stdin. Only read it when
# stdin is not a tty: run by hand, stdin IS the tty and cat would block.
payload=""
if [ ! -t 0 ]; then
  payload=$(head -c 8192 2>/dev/null | tr -d '\n')
fi
jfield() {
  printf '%s' "$payload" \
    | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}
sid=$(jfield session_id)
[ -n "$sid" ] || sid=unknown

# --- subordinate agent session? ---
# See header. Checked marker by marker rather than as a prefix glob, so a
# future variable that merely shares the CLAUDE_ prefix can't silence us.
subordinate=""
if [ "${CLAUDE_CODE_SESSION_KIND:-}" = bg ] || [ -n "${CLAUDE_BG_SOURCE:-}" ] \
   || [ -n "${CLAUDE_BG_BACKEND:-}" ] || [ -n "${CLAUDE_CODE_SESSION_NAME:-}" ]; then
  subordinate=1
fi

# Pre-1.2 settings.json says "attention"; treat it as ask.
[ "$pattern" = attention ] && pattern=ask

# --- listen mode: park this terminal as the dedicated "needs you" sound ---
# Run interactively, never from a hook. Registers pid + tty, then sleeps;
# ask/idle beeps get routed here while the process is alive. The trap also
# fires on HUP, so a dropped SSH connection deregisters cleanly.
if [ "$pattern" = listen ]; then
  reg="$cfg_dir/hooks/bell.tty.ask"
  mytty=$(tty 2>/dev/null)
  case "$mytty" in
    /dev/*) : ;;
    *) echo "bell.sh listen: needs a real terminal (got: ${mytty:-none})" >&2; exit 1 ;;
  esac
  printf '%s %s\n' "$$" "$mytty" > "$reg"
  trap 'rm -f "$reg"' EXIT INT TERM HUP
  say "listener registered on $mytty (pid $$)"
  echo "claude-bell: this terminal is now the 'Claude needs you' sound."
  echo "Its profile's bellSound is what you will hear for permission prompts"
  echo "and questions. Keep the tab open; close it to fall back. Test beep:"
  printf '\a'
  while :; do sleep 86400 & wait $!; done
  exit 0
fi

# --- event logic (before hunting for a tty: skips are cheap) ---
case "$pattern" in
  done)
    if [ -n "$subordinate" ]; then
      say "skip: subordinate agent session (${CLAUDE_CODE_SESSION_NAME:-bg}) turn end, not your task's end"
      exit 0
    fi
    # Remember when this session last finished a turn, so the idle_prompt
    # that follows ~60 s later can be recognized as an echo.
    mkdir -p "$state_dir" 2>/dev/null
    date +%s > "$state_dir/$sid" 2>/dev/null
    find "$state_dir" -type f -mmin +1440 -delete 2>/dev/null
    ;;
  ask)
    : # always worth a beep, from any session
    ;;
  idle)
    if [ -n "$subordinate" ]; then
      say "skip: idle_prompt in subordinate agent session"
      exit 0
    fi
    last=$(cat "$state_dir/$sid" 2>/dev/null || echo 0)
    delta=$(( $(date +%s) - last ))
    if [ "$delta" -le 75 ]; then
      say "skip: idle echo ${delta}s after this session's turn end"
      exit 0
    fi
    say "idle_prompt with no recent turn end - a dialog is likely waiting on you"
    ;;
  *)
    : # unknown pattern: installer self-check; resolves a tty, emits nothing
    ;;
esac

# Genuinely attempt to open for writing. O_TRUNC is a no-op on a char device,
# so this emits nothing.
can_write() { { : > "$1"; } 2>/dev/null; }

tty_dev=""

# --- strategy 0: a dedicated "needs you" terminal, if one is listening ---
# Only for ask/idle: "done" keeps the session terminal's own sound, which is
# the whole point of having two profiles.
if [ "$pattern" = ask ] || [ "$pattern" = idle ]; then
  reg="$cfg_dir/hooks/bell.tty.ask"
  if [ -f "$reg" ]; then
    read -r lpid ltty < "$reg" 2>/dev/null || true
    if [ -n "${lpid:-}" ] && kill -0 "$lpid" 2>/dev/null && can_write "${ltty:-}"; then
      tty_dev="$ltty"
      say "strategy0 listener tty $ltty (pid $lpid)"
    else
      say "stale listener registration ignored"
    fi
  fi
fi

# --- strategy 1: controlling terminal ---
if [ -z "$tty_dev" ] && can_write /dev/tty; then
  tty_dev="/dev/tty"
  say "strategy1 /dev/tty OK"
fi

# --- strategy 2: walk up the process tree ---
if [ -z "$tty_dev" ]; then
  pid=$PPID
  for _ in 1 2 3 4 5 6 7 8; do
    if [ -z "$pid" ] || [ "$pid" = 0 ]; then break; fi
    t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -n "$t" ] && [ "$t" != "?" ] && can_write "/dev/$t"; then
      tty_dev="/dev/$t"
      say "strategy2 walk found $tty_dev"
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
fi

# --- strategy 3: the tty of a running `claude agents` UI ---
# Match against the whole argv and require a real tty, so the daemon — whose
# --spawned-by JSON embeds the literal string "claude agents" — and any shell
# that merely mentions it are both excluded.
if [ -z "$tty_dev" ]; then
  uis=$(ps -eo tty=,args= 2>/dev/null \
        | awk '$1 != "?" && /(^| |\/)claude agents$/ { print $1 }' \
        | sort -u)
  n=$(printf '%s\n' "$uis" | grep -c .)
  if [ "$n" -eq 1 ] && can_write "/dev/$uis"; then
    tty_dev="/dev/$uis"
    say "strategy3 agents UI tty $tty_dev"
  elif [ "$n" -gt 1 ]; then
    # Can't tell which UI owns this session; beeping at all of them, or at an
    # arbitrary one, is the wrong-terminal bug again.
    say "skip: $n agents UIs open, ambiguous target"
    exit 0
  fi
fi

# --- no tty at all: stay silent ---
if [ -z "$tty_dev" ]; then
  say "skip: no controlling tty (background session)"
  exit 0
fi

case "$pattern" in
  done)
    printf '\a' > "$tty_dev" 2>/dev/null
    ;;
  ask|idle)
    printf '\a' > "$tty_dev" 2>/dev/null
    sleep 0.6
    printf '\a' > "$tty_dev" 2>/dev/null
    ;;
  *)
    # Unknown pattern (the installer's self-check uses these): record where we
    # would have written, but emit nothing.
    say "dry-run, no BEL"
    exit 0
    ;;
esac

say "BEL sent to $tty_dev"
exit 0
BELL_EOF

chmod +x "$BELL"
c_ok "wrote $BELL"

# --------------------------------------------------------- merge settings.json
hdr "Configuring hooks"
[ -f "$SETTINGS" ] && cp -p "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)" \
  && c_ok "backed up existing settings.json"

if [ "$JSON_TOOL" = python3 ]; then
  python3 - "$SETTINGS" "$BELL" <<'PY'
import json, os, sys
path, script = sys.argv[1], sys.argv[2]

if os.path.exists(path):
    with open(path) as f:
        raw = f.read().strip()
    try:
        cfg = json.loads(raw) if raw else {}
    except json.JSONDecodeError as e:
        sys.exit(f"settings.json is not valid JSON, refusing to touch it: {e}")
else:
    cfg = {}

hooks = cfg.setdefault("hooks", {})

# Stop → done. Notification is split by typed matcher: prompts that block on
# the user ring "ask"; idle_prompt goes through the script's echo filter as
# "idle"; everything else (auth_success, agent_completed, …) is noise and is
# simply not subscribed.
PLAN = {
    "Stop": [("*", "done")],
    "Notification": [
        ("permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input", "ask"),
        ("idle_prompt", "idle"),
    ],
}

for event, entries in PLAN.items():
    groups = hooks.setdefault(event, [])
    # Drop any pre-existing bell.sh entries first, so reinstalling is
    # idempotent and never stacks up duplicate beeps.
    cleaned = []
    for g in groups:
        inner = [h for h in g.get("hooks", []) if "bell.sh" not in h.get("command", "")]
        if inner:
            g["hooks"] = inner
            cleaned.append(g)
    for matcher, arg in entries:
        cleaned.append({
            "matcher": matcher,
            "hooks": [{"type": "command", "timeout": 5, "command": f"{script} {arg}"}],
        })
    hooks[event] = cleaned

os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
  rc=$?
else
  tmp=$(mktemp)
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  jq --arg s "$BELL" '
    def strip($ev): if .hooks[$ev] then
        .hooks[$ev] |= (map(.hooks |= map(select(.command | contains("bell.sh") | not)))
                        | map(select(.hooks | length > 0)))
      else . end;
    .hooks //= {}
    | strip("Stop") | strip("Notification")
    | .hooks.Stop = ((.hooks.Stop // []) + [{matcher:"*",hooks:[{type:"command",timeout:5,command:($s+" done")}]}])
    | .hooks.Notification = ((.hooks.Notification // []) + [
        {matcher:"permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input",
         hooks:[{type:"command",timeout:5,command:($s+" ask")}]},
        {matcher:"idle_prompt",
         hooks:[{type:"command",timeout:5,command:($s+" idle")}]}])
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  rc=$?
fi

if [ "$rc" != 0 ]; then
  c_err "failed to merge settings.json; original untouched (see backup above)"
  exit 1
fi
c_ok "Stop → bell.sh done (1 beep; your own sessions only, subagents stay silent)"
c_ok "Notification[permission/question/agent-needs-input] → bell.sh ask (2 beeps)"
c_ok "Notification[idle_prompt] → bell.sh idle (the +60s echo after done is filtered)"

if [ "$QUIET_READLINE" = 1 ]; then
  hdr "Silencing readline's bell"
  apply_quiet_readline
fi

# ----------------------------------------------------------------- self-check
hdr "Self-check"

# Pull our own log lines by tag. Several Claude sessions may be running on the
# same box, all appending to this log from their own Stop hooks, so `tail -n1`
# can easily pick up someone else's line.
# Each run writes two lines (where it resolved + a dry-run marker); we want the
# first, hence filtering out dry-run.
grab() {
  grep -F "[$1]" "$HOOK_DIR/bell.log" 2>/dev/null | grep -vF 'dry-run' | tail -n1
}

# --- foreground: should resolve a tty ---
"$BELL" selftest-fg >/dev/null 2>&1
fg_line=$(grab selftest-fg)
if echo "$fg_line" | grep -q "strategy[12]"; then
  c_ok "foreground resolved tty: $(echo "$fg_line" | grep -o '/dev/[a-z0-9/]*' | tail -1)"
else
  c_warn "foreground found no tty — expected if you ran this over a pipe or ssh without -t"
fi

# --- background: should stay silent ---
# setsid only forks when the caller is already a process group leader;
# otherwise it calls setsid() in place and PPID is unchanged, so strategy 2
# happily walks up to the caller's tty and the test fails spuriously. Force
# --fork and have the child sleep first, so it is reparented to init (PPID=1)
# before bell.sh runs. That actually reproduces a background agent's process
# environment.
if ! command -v setsid >/dev/null 2>&1; then
  c_warn "no setsid (util-linux) — skipping background-silence check"
else
  if setsid --fork true 2>/dev/null; then SETSID="setsid --fork"; else SETSID="setsid"; fi
  $SETSID bash -c 'sleep 0.5; exec "$0" selftest-bg' "$BELL" </dev/null >/dev/null 2>&1
  sleep 1.5
  bg_line=$(grab selftest-bg)
  if echo "$bg_line" | grep -q "no controlling tty"; then
    c_ok "background session correctly stays silent"
  elif echo "$bg_line" | grep -q "strategy3 agents UI"; then
    # Not the phantom-beep bug: a `claude agents` UI is open, and routing the
    # beep to the terminal it owns is exactly what strategy 3 is for.
    c_ok "background session routed to the agents UI tty (strategy 3, expected)"
  elif [ -z "$bg_line" ]; then
    c_warn "background check produced no log line (see $HOOK_DIR/bell.log)"
  else
    c_err "background session did NOT stay silent! It resolved: $bg_line"
    c_err "  → this causes phantom beeps; check whether bell.sh grew a fallback strategy"
  fi
fi

# --- subordinate suppression: a spawned agent session must not ring "done" ---
CLAUDE_CODE_SESSION_NAME=selftest-sub "$BELL" done </dev/null >/dev/null 2>&1
sub_line=$(grep -F '(selftest-sub)' "$HOOK_DIR/bell.log" 2>/dev/null | tail -n1)
if echo "$sub_line" | grep -q 'skip: subordinate'; then
  c_ok "subordinate agent session stays silent on Stop"
else
  c_err "subordinate suppression FAILED: ${sub_line:-no log line}"
  c_err "  → subagent/teammate turn ends would ring as false 'done' beeps"
fi

# --- real beeps + idle-echo filter ---
hdr "Two test sounds — first 1 beep = done, then 2 beeps = Claude needs you"
printf '{"session_id":"selfcheck-echo"}' | "$BELL" done
sleep 1.0
# An idle_prompt seconds after that turn end is the echo case: must stay silent.
printf '{"session_id":"selfcheck-echo"}' | "$BELL" idle
idle_line=$(grep -F 'skip: idle echo' "$HOOK_DIR/bell.log" 2>/dev/null | tail -n1)
if [ -n "$idle_line" ]; then
  c_ok "idle_prompt right after a turn end is filtered as echo"
else
  c_warn "idle-echo filter produced no log line (see bell.log)"
fi
sleep 0.4
printf '{"session_id":"selfcheck-ask"}' | "$BELL" ask
sleep 0.8

cat <<EOF

$(printf '\033[1mInstalled\033[0m')

  script    $BELL
  config    $SETTINGS
  log       $HOOK_DIR/bell.log

Want "Claude needs you" to be a genuinely DIFFERENT sound, not just a
different beep count? A BEL can only play the one bellSound its terminal
profile maps it to — but every profile has its own. So:

  1. In your terminal (e.g. Windows Terminal) duplicate your SSH profile and
     give the copy a different bellSound.
  2. Open one tab with that profile, SSH to this box, run:
       ~/.claude/hooks/bell.sh listen
  3. Leave the tab open. Permission prompts and questions now ring THERE with
     that profile's sound; "done" stays on your session terminal. Close the
     tab any time to fall back to single-sound behavior.

Heard nothing? Check in this order:

  1. Your local terminal must be configured to play a sound on BEL.
     This is a PC-side setting, done once, and applies to every host you SSH
     into — it has nothing to do with the server. See the README.

  2. tail $HOOK_DIR/bell.log
       strategy1 / 2 / 3      → located fine, so the problem is PC-side
       no controlling tty     → background session and no agents UI is open;
                                silent by design
       ambiguous target       → several \`claude agents\` UIs are open; close
                                all but the one you actually watch

  3. tmux and screen swallow BEL — see the preflight warnings above.

Beeping when nothing is running? Two usual causes, neither is a hook firing:

  a. bash itself. readline rings the bell on empty-line backspace, on an arrow
     key at the edge of the line, and on tab with no completion. It always
     did; you only hear it now that BEL plays a sound. Fix:
       ./install.sh --quiet-readline

  b. A subordinate agent session asking for permission. Since 1.2 its turn
     ends are silenced (no more false "done" from subagents/teammates), but a
     permission prompt inside one still rings 2 beeps at the agents UI
     terminal — that is a real request waiting for you. Check the log; if
     nothing was appended when you heard the beep, it wasn't this project.
EOF

warn_reload_needed
