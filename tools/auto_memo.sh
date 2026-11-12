#!/bin/bash
# メモ未記入の動画に、Claude（コマンド版）で一言メモを付けて commit する。push はしない。
#   tools/auto_memo.sh            未記入があれば最大 MEMO_LIMIT 本（既定60）にメモを付ける
#   MEMO_DRY=1 tools/auto_memo.sh  memos.json を書き換えず、commit もしない（試験用）
#   MEMO_CATEGORIES=hugness,monu   対象カテゴリ（既定は hugness のみ）
# 標準出力は最後の要約1行だけ。詳細は ~/furfolk_sync/logs/memo_*.log。
# 失敗しても同期は止めない: 付けられなかった動画は未記入のまま残り、次回また対象になる。
set -uo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOME_DIR="${FURFOLK_SYNC_HOME:-$HOME/furfolk_sync}"
LOGDIR="$HOME_DIR/logs"; WORKDIR="$HOME_DIR/memo_work"
PY=/usr/bin/python3            # Pillow が入っている python
LIB="$REPO/tools/memo_lib.py"
LIMIT="${MEMO_LIMIT:-60}"
MODEL="${MEMO_MODEL:-sonnet}"
TIMEOUT="${MEMO_TIMEOUT:-1200}"
TODAY=$(TZ=Asia/Tokyo date +%Y-%m-%d)
TS=$(TZ=Asia/Tokyo date +%Y%m%d_%H%M%S)
LOG="$LOGDIR/memo_$TS.log"
mkdir -p "$LOGDIR"
cd "$REPO" || exit 1

TOTAL=$("$PY" "$LIB" count 2>>"$LOG") || { echo "MEMO: 未記入の確認に失敗 ($LOG)"; exit 1; }
if [ "$TOTAL" = "0" ]; then echo "MEMO: 未記入なし"; exit 0; fi
if ! command -v claude >/dev/null 2>&1; then echo "MEMO: 未記入 ${TOTAL}本（claude コマンドが見つからず未処理）"; exit 1; fi

rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"
read -r N _ < <("$PY" "$LIB" prepare "$WORKDIR" "$LIMIT" 2>>"$LOG")
if [ -z "${N:-}" ] || [ "$N" = "0" ]; then echo "MEMO: 一覧シートの作成に失敗 ($LOG)"; exit 1; fi

SHEETS=$(ls "$WORKDIR"/sheets/*.jpg)
LIST=$("$PY" -c "
import json,sys
for i in json.load(open(sys.argv[1])): print('#%d %s （%s）' % (i['n'], i['title'], i['folder']))
" "$WORKDIR/index.json")

PROMPT="犬用ハーネスの撮影素材に、検索用の一言メモを付けてください。

次の画像を Read で開いてください。1枚に最大15本の動画が並び、各動画は黒い帯の #番号 とファイル名の下に、時間順の12コマ（左上が最初）で表示されています。
$SHEETS

動画の一覧（番号 ファイル名（撮影フォルダ））:
$LIST

全部で ${N} 本です。各動画につき1行、次の形だけを出力してください。前置き・後書き・コードブロックは不要です。
番号|場所|動き|内容|写り|注意

- 場所: 例「スタジオ・白背景」「屋外・公園の芝生」「屋内・フローリング」「車内」
- 動き: 少・中・多 のどれか1文字。映像がない（真っ黒など）場合は —
- 内容: 誰が何をしているか。ハーネスが見えるなら色も書く（例「緑のハーネスのイタグレが歩く」）。着せる場面は「着せる」と書く
- 写り: 寄り／中／引き、正面／横／後ろ、ローアングル／俯瞰、固定 など
- 注意: 使うときの注意点や向いている用途（例「長尺」「逆光で暗い」「犬は小さい」「商品が見やすい」「着せシーン」「犬なし」）。なければ空欄
- メモは選別ではなく説明です。動きが少ない動画や使いにくい動画も必ず1行書き、良し悪しの判定は書かないでください
- 区切りの | は項目の中で使わないでください。1項目は40字以内を目安に、日本語で書いてください"

echo "== memo start $TS total=$TOTAL batch=$N model=$MODEL" >>"$LOG"
( cd "$WORKDIR" && perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" \
    claude -p "$PROMPT" --allowedTools "Read" --model "$MODEL" </dev/null >"$WORKDIR/reply.txt" 2>>"$LOG" )
RC=$?
cat "$WORKDIR/reply.txt" >>"$LOG" 2>/dev/null
if grep -qi "authenticate\|OAuth\|/login" "$WORKDIR/reply.txt" "$LOG" 2>/dev/null && [ "$RC" != "0" ]; then
  echo "MEMO: 未記入 ${TOTAL}本（Claude のログイン切れ。ターミナルで claude を開いて /login してください）"; exit 1
fi
if [ "$RC" != "0" ]; then echo "MEMO: 未記入 ${TOTAL}本（Claude の呼び出しに失敗 rc=$RC, $LOG）"; exit 1; fi

RESULT=$("$PY" "$LIB" apply "$WORKDIR" "$WORKDIR/reply.txt" 2>>"$LOG") || { echo "MEMO: 反映に失敗 ($LOG)"; exit 1; }
ADDED=$(echo "$RESULT" | sed -n 's/.*added=\([0-9]*\).*/\1/p')
echo "$RESULT" >>"$LOG"
LEFT=$((TOTAL - ${ADDED:-0}))

if [ "${MEMO_DRY:-}" = "1" ]; then echo "MEMO(試験): ${ADDED:-0}/${N}本を読み取り（書き込みなし）"; exit 0; fi
if [ "${ADDED:-0}" = "0" ]; then echo "MEMO: 未記入 ${TOTAL}本（メモを読み取れず, $LOG）"; exit 1; fi

git add memos.json >>"$LOG" 2>&1
if git commit -q -m "Memo: add $ADDED clips ($TODAY)" >>"$LOG" 2>&1; then
  echo "$TS memo ok added=$ADDED left=$LEFT" >>"$LOGDIR/history.log"
  echo "MEMO: 追加 ${ADDED}本 / 未記入の残り ${LEFT}本"
else
  echo "MEMO: commit に失敗 ($LOG)"; exit 1
fi
