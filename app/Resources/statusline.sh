#!/bin/zsh
# Claude Code statusLine command, installed by Claude Scheduler.
# Claude Code pipes session JSON to it after each reply. It saves the subscription usage
# limits (rate_limits) for the app to show, and prints them as the status line.
#
# Several Claude accounts can share this Mac (terminal, VS Code, desktop app), and all of
# them run this script, so limits are saved per account: limits/<account-uuid>.json.
DIR="$HOME/Library/Application Support/ClaudeScheduler/limits"
input=$(cat)
get() { print -r -- "$input" | plutil -extract "$1" raw -o - - 2>/dev/null; }

# Which account is this session using?
if [[ -n "$CLAUDE_CODE_ACCOUNT_UUID" ]]; then
  account="$CLAUDE_CODE_ACCOUNT_UUID"                  # set by the desktop app
elif [[ -n "$CLAUDE_CODE_OAUTH_TOKEN$ANTHROPIC_API_KEY$ANTHROPIC_AUTH_TOKEN" ]]; then
  account="other"                                      # login passed in from elsewhere
else
  config="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"    # the login of this config dir
  account=$(plutil -extract oauthAccount.accountUuid raw -o - "$config" 2>/dev/null) || account="other"
fi

if limits=$(print -r -- "$input" | plutil -extract rate_limits json -o - - 2>/dev/null); then
  mkdir -p "$DIR"
  print -r -- "$limits" > "$DIR/$account.json.tmp" && mv "$DIR/$account.json.tmp" "$DIR/$account.json"
fi

line="$(get model.display_name)"
for spec in "five_hour:5h:%H:%M" "seven_day:week:%a %H:%M"; do
  key=${spec%%:*}; rest=${spec#*:}; label=${rest%%:*}; fmt=${rest#*:}
  pct=$(get rate_limits.$key.used_percentage) || continue
  reset=$(get rate_limits.$key.resets_at)
  line+=" · $label $(printf %.0f "$pct")% (resets $(date -r ${reset%.*} "+$fmt"))"
done
print -r -- "$line"
