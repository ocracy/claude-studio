#!/bin/zsh -l
#
# What ttyd runs for every terminal the phone opens.
#
# Invoked as: cs-attach.sh <tmux-session> <project-path> [tab-name] [claude-session-id]
# ttyd passes those from the URL (`--url-arg`), so this script validates them
# before they reach tmux — the arguments arrive from the network.
#
# Three flags are deliberately absent or present:
#
#   * no -D  — do NOT detach other clients. tmux 3.2+ sizes a window from the
#              most recent client (`window-size latest`), so the Mac and the
#              phone can both stay attached; the Mac's tab keeps drawing.
#   * no -x/-y — the size comes from the attaching client's pty. Passing one
#              makes tmux paint a frame at the wrong geometry and the TUI stays
#              garbled until something resizes it.
#   * -e CS_* — present so Claude Code's hook reports this tab's state and its
#              session_id. Without them a session started from the phone would
#              never show a working/waiting badge and could never be resumed.

emulate -L zsh
setopt extended_glob
set -u

# A shebang carries only one argument, so `-i` cannot be requested there — and
# a login-only zsh reads .zprofile but not .zshrc, which is where PATH actually
# lives. Recover it the same way Shell.userPath does, but only when needed: the
# tmux server inherits this environment, and `claude` has to be findable in it.
if ! command -v claude >/dev/null 2>&1; then
  recovered="$(/bin/zsh -l -i -c 'print -rn -- $PATH' 2>/dev/null)"
  [[ -n "$recovered" ]] && export PATH="$recovered"
fi

session="${1:-}"
project="${2:-}"
tab_name="${3:-Claude}"
claude_sid="${4:-}"

# Only our own naming scheme, and only a directory that exists. Everything else
# is refused rather than handed to a shell.
[[ "$session" == cs-[A-Za-z0-9_-]##  ]] || { print -u2 "cs-attach: bad session name"; exit 1 }
[[ -d "$project" ]] || { print -u2 "cs-attach: no such project directory"; exit 1 }

socket="/tmp/claude-studio-${UID}.sock"
conf="$HOME/Library/Application Support/Claude Studio/tmux.conf"

tmux_bin=""
for candidate in /opt/homebrew/bin/tmux /usr/local/bin/tmux /opt/local/bin/tmux /usr/bin/tmux; do
  [[ -x "$candidate" ]] && { tmux_bin="$candidate"; break }
done
[[ -n "$tmux_bin" ]] || tmux_bin="$(command -v tmux)"
[[ -n "$tmux_bin" ]] || { print -u2 "cs-attach: tmux not found"; exit 1 }

project_name="${project:t}"

# Build the flag as an array. `${conf:+-f "$conf"}` would hand tmux the whole
# string "-f /path/to/tmux.conf" as ONE argument, which it then reads as a file
# name and fails on.
conf_args=()
if [[ -f "$conf" ]]; then
  conf_args=(-f "$conf")
  # `-f` is honoured only when this call starts the server. If one is already
  # running, load the config explicitly — otherwise a server someone else
  # started keeps tmux's defaults and its status bar eats a screen line.
  "$tmux_bin" -S "$socket" list-sessions >/dev/null 2>&1 &&
    "$tmux_bin" -S "$socket" source-file "$conf" >/dev/null 2>&1
fi

# Continue the conversation where it left off, exactly as the app does.
#
# `--resume` is only passed when the transcript is actually on disk and not
# empty: Claude prints "No session found" and exits immediately otherwise, and
# the phone would be staring at a dead terminal. Claude encodes a project path
# by replacing separators with dashes; the dot variant is checked too because
# the scheme is not certain for paths containing dots, and looking in two places
# is cheaper than silently losing a resumable conversation.
claude_command="claude"
if [[ -n "$claude_sid" ]]; then
  slashes="${project//\//-}"
  for encoded in "$slashes" "${slashes//./-}"; do
    transcript="$HOME/.claude/projects/$encoded/$claude_sid.jsonl"
    if [[ -s "$transcript" ]]; then
      claude_command="claude --resume ${(q)claude_sid}"
      break
    fi
  done
fi

# `new-session -A`: attach if it exists, create it otherwise. One call covers
# both "show me the tab running on the Mac" and "start the one I just tapped".
# On creation the session is born at the phone's size.
exec "$tmux_bin" -S "$socket" "${conf_args[@]}" \
  new-session -A -s "$session" \
  -e "CS_PROJECT=$project_name" \
  -e "CS_TAB_ID=session:$session" \
  -e "CS_TAB_NAME=$tab_name" \
  "cd ${(q)project} && exec $claude_command"
