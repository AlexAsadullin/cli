#!/bin/zsh
# Runs one scheduled task. Called by launchd at the scheduled minute.
# Usage: run-task.sh <task-dir>
#   <task-dir>/task.env   FOLDER, SESSION (empty = new session), FIRE_EPOCH, LABEL
#   <task-dir>/prompt.txt the prompt
#   <task-dir>/status     written here: "<state>|<message>|<epoch>"
#   <task-dir>/pane.log   screen of the Claude session ~90s after sending
#   <task-dir>/run.log    timestamped steps of this run
#   <task-dir>/target     tmux pane the prompt goes to

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.claude/local:/usr/bin:/bin:/usr/sbin:/sbin"
export LANG="${LANG:-en_US.UTF-8}"

TASK_DIR="$1"
source "$TASK_DIR/task.env" || exit 1

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S')  $*" >> "$TASK_DIR/run.log"; }
set_status() { print -r -- "$1|$2|$(date +%s)" > "$TASK_DIR/status"; log "[$1] $2"; }

finish() {
  log "Done; removing the launchd job"
  rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
  exit 0
}

# launchd also fires a calendar job on load/wake if it was missed; ignore anything too early.
if (( $(date +%s) < FIRE_EPOCH - 90 )); then exit 0; fi

command -v tmux >/dev/null || { set_status failed "tmux is not installed (brew install tmux)"; finish; }
command -v claude >/dev/null || { set_status failed "claude CLI not found"; finish; }

log "Fired. Folder: $FOLDER, session: ${SESSION:-new}"
set_status running "Starting"

# 1. Find a tmux pane already running this session, or start one.
TARGET=""
if [[ -n "$SESSION" ]]; then
  TARGET=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_start_command}' 2>/dev/null \
           | grep -F -- "$SESSION" | head -1 | cut -d' ' -f1)
fi

if [[ -n "$TARGET" ]]; then
  log "Found tmux pane already running this session: $TARGET"
else
  NAME="cs-${TASK_ID:0:8}"
  if [[ -n "$SESSION" ]]; then
    CMD="claude --resume $SESSION --permission-mode auto"
  else
    CMD="claude --permission-mode auto"
  fi
  tmux new-session -d -s "$NAME" -x 200 -y 50 -c "$FOLDER" "$CMD" \
    || { set_status failed "Could not start tmux session"; finish; }
  TARGET="$NAME"
  log "Started tmux session $NAME: $CMD"
  # Wait for Claude's input box to appear.
  for i in {1..45}; do
    sleep 2
    tmux capture-pane -t "$TARGET" -p 2>/dev/null | grep -q "❯" && break
  done
  sleep 3
  log "Claude is up"
fi
print -r -- "$TARGET" > "$TASK_DIR/target"

# 2. If Claude is already busy with this very prompt (e.g. it auto-resumed after a usage
#    limit), don't send a duplicate.
FIRST_LINE=$(head -1 "$TASK_DIR/prompt.txt" | cut -c1-60)
PANE=$(tmux capture-pane -t "$TARGET" -p -S -300 2>/dev/null)
if print -r -- "$PANE" | grep -q "esc to interrupt" && print -r -- "$PANE" | grep -qF -- "$FIRST_LINE"; then
  set_status working "Claude is already working on this prompt (session $TARGET)"
  finish
fi

# 3. Don't interrupt other work in progress: wait up to 30 min while Claude is busy.
for i in {1..61}; do
  tmux capture-pane -t "$TARGET" -p 2>/dev/null | grep -q "esc to interrupt" || break
  if (( i == 61 )); then set_status failed "Not sent: Claude was still busy after 30 min"; finish; fi
  (( i == 1 )) && set_status running "Waiting for Claude to finish current work"
  sleep 30
done

# 4. Paste the prompt (bracketed, so newlines don't submit early) and press Enter.
tmux load-buffer -b cs-prompt "$TASK_DIR/prompt.txt" \
  && tmux paste-buffer -p -d -b cs-prompt -t "$TARGET" \
  && sleep 1 && tmux send-keys -t "$TARGET" Enter \
  || { set_status failed "Could not send the prompt to tmux"; finish; }

set_status sent "Sent to tmux session $TARGET at $(date +%H:%M)"

# 5. Record what Claude shows shortly after, so the app can tell if it actually started.
log "Waiting 90s to see how Claude reacts"
sleep 90
PANE=$(tmux capture-pane -t "$TARGET" -p -S -200 2>/dev/null)
print -r -- "$PANE" > "$TASK_DIR/pane.log"
if print -r -- "$PANE" | tail -15 | grep -qi "usage limit\|hit your session limit"; then
  set_status limit "Sent, but Claude hit the usage limit"
elif print -r -- "$PANE" | grep -q "esc to interrupt"; then
  set_status working "Claude is working (session $TARGET)"
else
  log "Claude is idle after the prompt (it may have finished already)"
fi

finish
