#!/bin/bash
# 動画1本から12コマ(4x3)のコンタクトシートを生成する。
# ~/gen_capture.sh と同じ見た目(324x572タイル・秒数ラベル・648x858/q30)で、
# convert/montage を magick に置き換えたもの。
# 使い方: gen_contact.sh <動画> <出力jpg>
# 終了コード 0=成功 / 1=失敗(理由をstderrに1行)
V="$1"
OUT="$2"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/furfolk_cap.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

D=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$V" </dev/null 2>/dev/null)
if [ -z "$D" ] || [ "$D" = "N/A" ]; then echo "no_duration" >&2; exit 1; fi

FONT_ARG=()
for f in /System/Library/Fonts/Supplemental/Arial.ttf /System/Library/Fonts/Helvetica.ttc \
         /System/Library/Fonts/SFNS.ttf /System/Library/Fonts/Menlo.ttc; do
  if [ -f "$f" ]; then FONT_ARG=(-font "$f"); break; fi
done

TILES=()
for i in 0 1 2 3 4 5 6 7 8 9 10 11; do
  read -r T LBL < <(awk -v d="$D" -v i="$i" 'BEGIN{t=d*i/11; m=d-0.08; if(t>m)t=m; if(t<0)t=0; printf "%f %d\n", t, int(d*i/11+0.5)}')
  ffmpeg -nostdin -y -loglevel error -ss "$T" -i "$V" -vframes 1 -q:v 2 "$WORK/raw_$i.jpg" </dev/null
  if [ ! -f "$WORK/raw_$i.jpg" ]; then echo "extract_failed:frame$i" >&2; exit 1; fi
  ffmpeg -nostdin -y -loglevel error -i "$WORK/raw_$i.jpg" \
    -vf "crop=min(iw\,ih*324/572):min(ih\,iw*572/324),scale=324:572" -q:v 2 "$WORK/crop_$i.jpg" </dev/null
  magick "$WORK/crop_$i.jpg" -gravity northwest -pointsize 44 -fill white -stroke black -strokewidth 3 \
    "${FONT_ARG[@]}" -annotate +10+8 "${LBL}s" "$WORK/tile_$i.jpg" 2>/dev/null \
    || cp "$WORK/crop_$i.jpg" "$WORK/tile_$i.jpg"
  if [ ! -f "$WORK/tile_$i.jpg" ]; then echo "tile_failed:frame$i" >&2; exit 1; fi
  TILES+=("$WORK/tile_$i.jpg")
done

magick montage "${FONT_ARG[@]}" "${TILES[@]}" -tile 4x3 -geometry 324x572+0+0 -background black "$WORK/sheet.jpg" </dev/null >"$WORK/m.err" 2>&1 \
  || { echo "montage_failed:$(tail -1 "$WORK/m.err")" >&2; exit 1; }
magick "$WORK/sheet.jpg" -resize 648x858 -strip -sampling-factor 4:2:0 -quality 30 "$OUT" </dev/null \
  || { echo "resize_failed" >&2; exit 1; }
[ -s "$OUT" ] || { echo "output_missing" >&2; exit 1; }
