#!/usr/bin/env bash
set -euo pipefail
APP=/usr/local/bin/bbfs-auto-statistika.sh
LOG=/var/log/bbfs-auto-statistika.log
ENV=/opt/bbfs-shinobi/backend/.env
cat > "$APP" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
ENV=/opt/bbfs-shinobi/backend/.env
LOG=/var/log/bbfs-auto-statistika.log
TOKEN=$(grep '^ADMIN_API_TOKEN=' "$ENV" | cut -d= -f2-)
BASE=http://127.0.0.1:3001
NOW=$(date '+%F %T')
echo "[$NOW] START auto statistika" >> "$LOG"
curl -sS -m 300 -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -X POST "$BASE/api/bbfs/final/generate-all" -d '{"limit":200}' >> "$LOG" || true
echo "" >> "$LOG"
curl -sS -m 300 -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -X POST "$BASE/api/bbfs/final/evaluate" -d '{}' >> "$LOG" || true
echo "" >> "$LOG"
echo "[$(date '+%F %T')] DONE auto statistika" >> "$LOG"
SH
chmod +x "$APP"
cat > /etc/systemd/system/bbfs-auto-statistika.service <<'EOF'
[Unit]
Description=BBFS Auto Statistika Generate and Evaluate
After=bbfs-backend.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/bbfs-auto-statistika.sh
EOF
cat > /etc/systemd/system/bbfs-auto-statistika.timer <<'EOF'
[Unit]
Description=Run BBFS Auto Statistika every 10 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
Unit=bbfs-auto-statistika.service

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now bbfs-auto-statistika.timer
systemctl start bbfs-auto-statistika.service || true
echo "OK: BBFS auto statistika aktif"
echo "LOG: tail -f $LOG"
echo "STATUS: systemctl status bbfs-auto-statistika.timer --no-pager"
