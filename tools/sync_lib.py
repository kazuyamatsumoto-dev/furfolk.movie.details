#!/usr/bin/env python3
"""sync.sh から呼ばれる補助処理（Driveスキャン結果の差分・data.json反映・検証）。

  plan  <scan.json>              新規キュー(queue.tsv)とカテゴリ外の新着レポートを作る
  add   <id> <name> <size> <cat> <folderPathJSON>   pending.jsonl に1件追記
  apply                          pending を data.json / images/ に反映し検証する
"""
import datetime
import json
import os
import shutil
import sys
from collections import Counter
from zoneinfo import ZoneInfo

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(REPO, "data.json")
HOME = os.environ.get("FURFOLK_SYNC_HOME", os.path.expanduser("~/furfolk_sync"))
STATE = os.path.join(HOME, "state")
STAGING = os.path.join(HOME, "staging")
PENDING = os.path.join(STAGING, "pending.jsonl")

ROOT_NAME = "99_素材"
CATEGORIES = {
    "01_HUGNESS": "hugness",
    "02_monu": "monu",
    "03_furpot": "furpot",
    "04_original figure": "original-figure",
    "05_3D Photo撮影": "3d-photo",
}
VIDEO_EXT = {"mp4", "mov", "m4v", "avi", "mts", "m2ts", "mkv"}


def decode(seg):
    # rclone は Drive 名の "/" を全角 "／" に、本物の全角 "／" を "‛／" に置き換える
    return seg.replace("‛／", "\0").replace("／", "/").replace("\0", "／")


def load_data():
    with open(DATA, encoding="utf-8") as f:
        return json.load(f)


def write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def read_lines(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return [l.rstrip("\n") for l in f if l.strip()]


def pending_entries():
    return [json.loads(l) for l in read_lines(PENDING)]


def is_video(x):
    ext = x["Name"].rsplit(".", 1)[-1].lower() if "." in x["Name"] else ""
    return ext in VIDEO_EXT or x.get("MimeType", "").startswith("video/")


def cmd_plan(scan_path, queue_path, other_report):
    with open(scan_path, encoding="utf-8") as f:
        scan = json.load(f)
    known = {e["id"] for e in load_data()} | {e["id"] for e in pending_entries()}

    os.makedirs(STATE, exist_ok=True)
    other_ids_path = os.path.join(STATE, "known_other_ids.txt")
    tops_path = os.path.join(STATE, "known_top_folders.txt")
    first_run = not os.path.exists(other_ids_path)
    other_known = set(read_lines(other_ids_path))
    tops_known = set(read_lines(tops_path))

    queue, other_new, tops = [], [], set()
    for x in scan:
        parts = x["Path"].split("/")
        if len(parts) > 1:
            tops.add(parts[0])
        if not is_video(x) or x["ID"] in known:
            continue
        top = parts[0] if len(parts) > 1 else ""
        if top in CATEGORIES:
            folder = [ROOT_NAME] + [decode(p) for p in parts[:-1]]
            queue.append((x["ID"], decode(parts[-1]), str(x["Size"]), CATEGORIES[top],
                          json.dumps(folder, ensure_ascii=False)))
        elif x["ID"] not in other_known:
            other_new.append(x)

    queue.sort(key=lambda q: (q[4], q[1]))
    with open(queue_path, "w", encoding="utf-8") as f:
        for q in queue:
            f.write("\t".join(q) + "\n")

    new_tops = sorted(tops - tops_known - set(CATEGORIES)) if not first_run else []
    with open(other_report, "w", encoding="utf-8") as f:
        for t in new_tops:
            f.write(f"NEWFOLDER\t{decode(t)}\n")
        if not first_run:
            for k, n in sorted(Counter("/".join(decode(p) for p in x["Path"].split("/")[:-1]) or "(直下)"
                                       for x in other_new).items()):
                f.write(f"OTHER\t{n}\t{k}\n")
    # カテゴリ外の新着は1回だけ知らせる（ログには残る）
    with open(other_ids_path, "a", encoding="utf-8") as f:
        for x in other_new:
            f.write(x["ID"] + "\n")
    with open(tops_path, "w", encoding="utf-8") as f:
        for t in sorted(tops | tops_known):
            f.write(t + "\n")
    print(len(queue))


def cmd_add(vid, name, size, cat, folder_json):
    entry = {
        "id": vid,
        "title": name,
        "category": cat,
        "folderPath": json.loads(folder_json),
        "fileSizeMB": int(size) / 1024 / 1024,
        "processedDate": datetime.datetime.now(ZoneInfo("Asia/Tokyo")).date().isoformat(),
        "frameCount": 12,
        "driveUrl": f"https://drive.google.com/file/d/{vid}/view",
        "img": f"images/{vid}.jpg",
    }
    with open(PENDING, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def cmd_apply():
    data = load_data()
    before = len(data)
    ids = {e["id"] for e in data}
    added = Counter()
    for e in pending_entries():
        src = os.path.join(STAGING, "images", e["id"] + ".jpg")
        if e["id"] in ids or not os.path.exists(src):
            continue
        shutil.copy2(src, os.path.join(REPO, e["img"]))
        data.append(e)
        ids.add(e["id"])
        added[e["category"]] += 1
    if added:
        write_json(DATA, data)

    # 検証: 件数・重複id・画像の存在
    data = load_data()
    errors = []
    if len(data) != before + sum(added.values()):
        errors.append(f"count {len(data)} != {before}+{sum(added.values())}")
    dup = len(data) - len({e["id"] for e in data})
    if dup:
        errors.append(f"duplicate_ids={dup}")
    missing = [e["id"] for e in data if not os.path.exists(os.path.join(REPO, e["img"]))]
    if missing:
        errors.append(f"missing_images={len(missing)}")
    if errors:
        print("VERIFY_FAIL " + " ".join(errors))
        sys.exit(1)

    os.remove(PENDING) if os.path.exists(PENDING) else None
    shutil.rmtree(os.path.join(STAGING, "images"), ignore_errors=True)
    os.makedirs(os.path.join(STAGING, "images"), exist_ok=True)
    total = Counter(e["category"] for e in data)
    print(f"ADDED {sum(added.values())} " + " ".join(f"{k}={v}" for k, v in sorted(added.items())))
    print(f"TOTAL {len(data)} " + " ".join(f"{k}={v}" for k, v in sorted(total.items())))


if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    {"plan": cmd_plan, "add": cmd_add, "apply": cmd_apply}[cmd](*args)
