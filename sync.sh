#!/bin/bash
# furfolk 動画ギャラリー同期: Drive検出 → コンタクトシート生成 → data.json反映 → commit
#   ./sync.sh              同期して commit まで（push はしない）
#   ./sync.sh --limit N    新規のうち N 本だけ処理（試験用）
#   ./sync.sh --push       commit 済みの変更を push（ユーザー承認後に使う）
# 標準出力は最後の要約だけ。詳細は ~/furfolk_sync/logs/ に残す。
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="${FURFOLK_SYNC_HOME:-$HOME/furfolk_sync}"
LOGDIR="$HOME_DIR/logs"; STATE="$HOME_DIR/state"; WORK="$HOME_DIR/work"; STAGING="$HOME_DIR/staging"
TEAM_DRIVE="0ACcku0eTU5yzUk9PVA"        # 共有ドライブ furfolk
ROOT_FOLDER="1SNkZ2zpAggeFOB4b0I5nUNzMGwu91DYA"   # 99_素材
LIB="$REPO/tools/sync_lib.py"
TODAY=$(TZ=Asia/Tokyo date +%Y-%m-%d)
TS=$(TZ=Asia/Tokyo date +%Y%m%d_%H%M%S)
LOG="$LOGDIR/sync_$TS.log"
HISTORY="$LOGDIR/history.log"
mkdir -p "$LOGDIR" "$STATE" "$WORK" "$STAGING/images"
cd "$REPO" || exit 1

notify() { osascript -e "display notification \"$1\" with title \"furfolk 同期\"" >/dev/null 2>&1 || true; }

if [ "${1:-}" = "--push" ]; then
  BR=$(git rev-parse --abbrev-ref HEAD)
  AHEAD=$(git rev-list --count "origin/$BR..HEAD" 2>/dev/null || git rev-list --count HEAD)
  if [ "$AHEAD" = "0" ]; then echo "PUSH: 未pushのcommitなし"; exit 0; fi
  if git push origin "$BR" >>"$LOGDIR/push_$TS.log" 2>&1; then
    echo "PUSH: OK ($BR, ${AHEAD}commit)"; echo "$TS push ok branch=$BR commits=$AHEAD" >>"$HISTORY"
  else
    echo "PUSH: 失敗 ($LOGDIR/push_$TS.log)"; echo "$TS push FAILED" >>"$HISTORY"; exit 1
  fi
  exit 0
fi

LIMIT=0
[ "${1:-}" = "--limit" ] && LIMIT="${2:-0}"

LOCK="$HOME_DIR/.lock"
if ! mkdir "$LOCK" 2>/dev/null; then echo "SKIP: 別の同期が実行中 ($LOCK)"; exit 1; fi
trap 'rm -rf "$LOCK" "$WORK"/*' EXIT

exec 3>&1 >>"$LOG" 2>&1
echo "== sync start $TS"

REMOTE=$(rclone listremotes 2>/dev/null | grep -i drive | head -1)
if [ -z "$REMOTE" ]; then echo "SYNC: rcloneのDriveリモートなし" >&3; exit 1; fi
RC=(--drive-team-drive "$TEAM_DRIVE")

# 1. 検出
if ! rclone lsjson -R --files-only "$REMOTE" "${RC[@]}" --drive-root-folder-id "$ROOT_FOLDER" >"$WORK/scan.json"; then
  echo "SYNC: Driveの走査に失敗 ($LOG)" >&3; echo "$TS scan FAILED" >>"$HISTORY"; exit 1
fi
QUEUE="$WORK/queue.tsv"; OTHER="$LOGDIR/other_$TS.tsv"
NEW=$(python3 "$LIB" plan "$WORK/scan.json" "$QUEUE" "$OTHER") || { echo "SYNC: plan失敗 ($LOG)" >&3; exit 1; }
echo "new=$NEW"

# 2. 処理（1本ずつ DL → 生成 → 動画削除）
FAILED="$STATE/failed.tsv"; : >"$FAILED.new"
OK=0; NG=0; N=0
while IFS=$'\t' read -r ID NAME SIZE CAT FOLDER; do
  N=$((N+1))
  [ "$LIMIT" -gt 0 ] && [ "$N" -gt "$LIMIT" ] && break
  echo "[$N/$NEW] $CAT $NAME ($ID)"
  if [ -s "$STAGING/images/$ID.jpg" ] && grep -qF "\"$ID\"" "$STAGING/pending.jsonl" 2>/dev/null; then OK=$((OK+1)); continue; fi
  FREE_KB=$(df -k "$WORK" | awk 'NR==2{print $4}')
  if [ $((SIZE / 1024 + 5242880)) -gt "$FREE_KB" ]; then
    REASON="disk_full"
  else
    VIDEO="$WORK/video_$ID.${NAME##*.}"
    if ! rclone backend copyid "$REMOTE" "${RC[@]}" "$ID" "$VIDEO" || [ ! -s "$VIDEO" ]; then
      REASON="download_failed"
    elif ERR=$(bash "$REPO/tools/gen_contact.sh" "$VIDEO" "$STAGING/images/$ID.jpg" 2>&1); then
      python3 "$LIB" add "$ID" "$NAME" "$SIZE" "$CAT" "$FOLDER"; REASON=""
    else
      REASON="capture_failed:${ERR##*$'\n'}"
    fi
    rm -f "$VIDEO"
  fi
  if [ -z "$REASON" ]; then OK=$((OK+1)); echo "  ok"
  else NG=$((NG+1)); echo "  FAIL $REASON"; printf '%s\t%s\t%s\t%s\n' "$ID" "$NAME" "$REASON" "$TS" >>"$FAILED.new"; fi
done <"$QUEUE"
mv "$FAILED.new" "$FAILED"
[ "$NG" -gt 0 ] && cp "$FAILED" "$LOGDIR/failed_$TS.tsv"

# 3. 反映・検証・commit
RESULT=$(python3 "$LIB" apply); RC_APPLY=$?
echo "$RESULT"
if [ $RC_APPLY -ne 0 ]; then
  echo "SYNC: 検証失敗、commitしません: $RESULT ($LOG)" >&3; echo "$TS verify FAILED $RESULT" >>"$HISTORY"; exit 1
fi
ADDED=$(echo "$RESULT" | awk '/^ADDED/{print $2}')
COMMITTED="なし"
if [ "${ADDED:-0}" -gt 0 ]; then
  git add data.json images
  git commit -q -m "Sync: add $ADDED videos ($TODAY)" && COMMITTED="$(git rev-parse --short HEAD)"
fi
REMAIN=$((NEW - OK - NG))
OTHER_N=$(cat "$OTHER" 2>/dev/null | grep -c .)

# 4. 要約（標準出力はここだけ）
{
  echo "SYNC $TODAY: 新規検出 $NEW / 追加 ${ADDED:-0} / 失敗 $NG / 未処理 $REMAIN / commit $COMMITTED"
  echo "$RESULT" | sed -n 's/^ADDED [0-9]* */  内訳: /p' | grep -v '内訳: $'
  echo "$RESULT" | sed -n 's/^TOTAL /  全体: /p'
  [ "$NG" -gt 0 ] && awk -F'\t' '{print "  失敗: "$2" "$3}' "$FAILED" | head -10
  if [ -s "$OTHER" ]; then
    awk -F'\t' '$1=="NEWFOLDER"{print "  新しいフォルダ(未分類): "$2} $1=="OTHER"{print "  カテゴリ外の新着: "$2"本 "$3}' "$OTHER" | head -15
  fi
  BR=$(git rev-parse --abbrev-ref HEAD)
  echo "  未push: $(git rev-list --count "origin/$BR..HEAD" 2>/dev/null || echo '?')commit ($BR)"
} >&3
echo "$TS new=$NEW added=${ADDED:-0} failed=$NG remain=$REMAIN other=$OTHER_N commit=$COMMITTED" >>"$HISTORY"
[ -s "$OTHER" ] || rm -f "$OTHER"
notify "追加 ${ADDED:-0} / 失敗 $NG / カテゴリ外の新着 ${OTHER_N}件"
exit 0
