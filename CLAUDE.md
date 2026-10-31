# furfolk 動画ギャラリー

- ユーザーが「同期」と伝えたら、`.claude/commands/sync.md`（`/sync`）と同じ手順を実行する。
- push は毎回ユーザーの承認を得てから `./sync.sh --push` で行う。自動 push しない。
- index.html は変更しない。既存の data.json / images/ は再処理しない。
- トークン消費を抑える: 普段はスクリプトの要約だけを見る。ログ（`~/furfolk_sync/logs/`）は必要なときだけ読む。

## 仕組み
- `sync.sh`: 共有ドライブ furfolk の 99_素材 を rclone で再帰走査 → data.json 未登録の動画を1本ずつ DL → `tools/gen_contact.sh` で12コマのコンタクトシート → 動画削除 → data.json 追記・検証 → commit。
- カテゴリ対応: 01_HUGNESS=hugness, 02_monu=monu, 03_furpot=furpot, 04_original figure=original-figure, 05_3D Photo撮影=3d-photo（`tools/sync_lib.py` の CATEGORIES）。
- カテゴリ外フォルダの新着と、99_素材直下の新しいフォルダは、処理せず要約で1回だけ知らせる。
- 状態: `~/furfolk_sync/state/`（failed.tsv＝前回の失敗、known_*＝通知済み）。失敗した動画は未登録のままなので次回自動で再試行される。
- 途中で止まっても、生成済みの画像は `~/furfolk_sync/staging/` に残り、次回にそのまま反映される。
