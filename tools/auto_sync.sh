#!/bin/bash
# LaunchAgent から呼ばれる自動同期（Claude を使わない）。
# sync.sh と auto_memo.sh（メモ付け）を実行し、未push の commit があれば macOS のダイアログで push の可否を聞く。
# 「push する」が押されたときだけ push。応答がなければ push せず、次回また聞く。
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1

git pull -q --ff-only origin "$(git rev-parse --abbrev-ref HEAD)" >/dev/null 2>&1
SUMMARY=$("$REPO/sync.sh" 2>&1)
# メモ未記入の動画があれば Claude で一言メモを付ける（失敗しても同期は続ける）
MEMO=$("$REPO/tools/auto_memo.sh" 2>&1 | tail -1)
[ -n "$MEMO" ] && SUMMARY=$(printf '%s\n%s' "$SUMMARY" "$MEMO")

BR=$(git rev-parse --abbrev-ref HEAD)
AHEAD=$(git rev-list --count "origin/$BR..HEAD" 2>/dev/null || echo 0)
[ "$AHEAD" -gt 0 ] || exit 0

MSG=$(printf '%s\n\n未push: %s commit。公開ページに反映（push）しますか？' "$SUMMARY" "$AHEAD" | sed 's/\\/\\\\/g; s/"/\\"/g')
ANSWER=$(osascript -e "display dialog \"$MSG\" with title \"furfolk 同期\" buttons {\"あとで\", \"push する\"} default button \"あとで\" giving up after 3600" 2>&1)
# ダイアログの結果を残す（押されたボタン / 時間切れ / 表示エラー）
echo "$(TZ=Asia/Tokyo date +%Y%m%d_%H%M%S) dialog: $(echo "$ANSWER" | tr '\n' ' ')" >>"$HOME/furfolk_sync/logs/history.log"
case "$ANSWER" in
  *"push する"*)
    RESULT=$("$REPO/sync.sh" --push 2>&1)
    osascript -e "display notification \"$RESULT\" with title \"furfolk 同期\"" >/dev/null 2>&1 ;;
esac
