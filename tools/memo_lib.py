#!/usr/bin/env python3
"""auto_memo.sh から呼ばれる補助処理（メモ未記入の抽出・一覧シート作成・memos.json への追記）。

  count                         メモ未記入の本数を出す
  prepare <workdir> <limit>     未記入のうち先頭 limit 本の一覧シートと index.json を作る
                                 → 標準出力に「今回の本数 未記入の総数」
  apply <workdir> <reply.txt>   Claude の返答（n|場所|動き|内容|写り|注意）を検証して memos.json に追記
                                 → 標準出力に「added=N skipped=M」

対象カテゴリは環境変数 MEMO_CATEGORIES（カンマ区切り、既定は hugness）。
MEMO_DRY=1 のときは apply で memos.json を書き換えない（試験用）。
"""
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(REPO, "data.json")
MEMOS = os.path.join(REPO, "memos.json")
CATEGORIES = [c.strip() for c in os.environ.get("MEMO_CATEGORIES", "hugness").split(",") if c.strip()]
MOVES = {"少", "中", "多", "—"}
COLS, ROWS, W, H, LABEL = 5, 3, 317, 420, 22


def load_memos():
    if not os.path.exists(MEMOS):
        return {}
    with open(MEMOS, encoding="utf-8") as f:
        return json.load(f)


def pending():
    with open(DATA, encoding="utf-8") as f:
        data = json.load(f)
    memos = load_memos()
    items = [i for i in data if i["category"] in CATEGORIES and i["id"] not in memos]
    items.sort(key=lambda i: ("/".join(i["folderPath"]), i["title"]))
    return items


def write_memos(memos):
    """1行1動画の形を保って書き出す（grep で1件ずつ拾えるようにするため）。"""
    lines = [json.dumps(k, ensure_ascii=False) + ": " + json.dumps(v, ensure_ascii=False) for k, v in memos.items()]
    tmp = MEMOS + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("{\n" + ",\n".join(lines) + "\n}\n")
    with open(tmp, encoding="utf-8") as f:
        assert len(json.load(f)) == len(memos)
    os.replace(tmp, MEMOS)


def cmd_prepare(workdir, limit):
    from PIL import Image, ImageDraw, ImageFont

    items = pending()
    chosen = items[:limit] if limit > 0 else items
    sheets = os.path.join(workdir, "sheets")
    os.makedirs(sheets, exist_ok=True)
    index = [
        {"n": n, "id": i["id"], "title": i["title"], "folder": "/".join(i["folderPath"][1:]), "img": i["img"]}
        for n, i in enumerate(chosen)
    ]
    with open(os.path.join(workdir, "index.json"), "w", encoding="utf-8") as f:
        json.dump(index, f, ensure_ascii=False)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 18)
    except OSError:
        font = ImageFont.load_default()
    per = COLS * ROWS
    for s in range(0, len(index), per):
        sheet = Image.new("RGB", (COLS * W, ROWS * (H + LABEL)), "white")
        draw = ImageDraw.Draw(sheet)
        for k, it in enumerate(index[s:s + per]):
            x, y = (k % COLS) * W, (k // COLS) * (H + LABEL)
            draw.rectangle([x, y, x + W, y + LABEL], fill="black")
            draw.text((x + 4, y + 2), "#%d %s" % (it["n"], it["title"][:22]), fill="yellow", font=font)
            try:
                thumb = Image.open(os.path.join(REPO, it["img"])).convert("RGB").resize((W, H))
                sheet.paste(thumb, (x, y + LABEL))
            except Exception:
                draw.text((x + 10, y + 60), "NO IMG", fill="red", font=font)
        sheet.save(os.path.join(sheets, "s%03d.jpg" % (s // per)), quality=80)
    print(len(chosen), len(items))


def cmd_apply(workdir, reply_path):
    with open(os.path.join(workdir, "index.json"), encoding="utf-8") as f:
        index = {i["n"]: i for i in json.load(f)}
    memos = load_memos()
    added, seen = 0, set()
    with open(reply_path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^\s*#?(\d+)\|(.*)$", line.rstrip("\n"))
            if not m:
                continue
            n, rest = int(m.group(1)), [c.strip() for c in m.group(2).split("|")]
            if n not in index or n in seen or len(rest) != 5:
                continue
            place, move, what, shot, note = rest
            if move not in MOVES or not place or not what:
                continue
            it = index[n]
            if it["id"] in memos:
                continue
            entry = {"title": it["title"], "folder": it["folder"], "場所": place, "動き": move, "内容": what, "写り": shot}
            if note:
                entry["注意"] = note
            memos[it["id"]] = entry
            seen.add(n)
            added += 1
    if added and os.environ.get("MEMO_DRY") != "1":
        write_memos(memos)
    print("added=%d skipped=%d" % (added, len(index) - added))


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "count":
        print(len(pending()))
    elif cmd == "prepare":
        cmd_prepare(sys.argv[2], int(sys.argv[3]))
    elif cmd == "apply":
        cmd_apply(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
