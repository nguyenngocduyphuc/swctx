#!/bin/bash
# bench/install_nightly.sh — install the com.swctx.benchd LaunchAgent:
# runs bench/nightly.sh at 03:05 local every day (frozen gold-set recall
# ratchet; failures land as bench_alert records in the global ledger).
# Idempotent. Uninstall: launchctl bootout gui/$(id -u)/com.swctx.benchd
# and remove the plist.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$HOME/Library/LaunchAgents/com.swctx.benchd.plist"
LABEL="com.swctx.benchd"
UIDN="$(id -u)"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string>
        <string>$HERE/bench/nightly.sh</string></array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>3</integer>
        <key>Minute</key><integer>5</integer></dict>
  <key>StandardOutPath</key>
  <string>$HERE/bench/nightly/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$HERE/bench/nightly/launchd.err.log</string>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>
</dict></plist>
EOF

launchctl bootout "gui/$UIDN/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UIDN" "$PLIST"
launchctl enable "gui/$UIDN/$LABEL" || true
echo "installed $LABEL → $PLIST (runs 03:05 daily)"
echo "kick now:   launchctl kickstart gui/$UIDN/$LABEL"
echo "status:     launchctl print gui/$UIDN/$LABEL | head"
