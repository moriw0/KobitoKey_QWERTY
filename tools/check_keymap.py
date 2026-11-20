#!/usr/bin/env python3
"""keymap のコンボを検査する。

  check_keymap.py [keymap]           コンボと、ベースレイヤーの刻印を一覧する。重なりがあれば終了コード 1
  check_keymap.py [keymap] --has 名前  その名前のコンボが定義されているか（なければ終了コード 1）

重なりとは、2 つのコンボの key-positions が同じ集合、または一方がもう一方を含むこと
（含むと、押している途中で小さい方が先に出てしまう）。
"""
import os
import re
import sys

DEFAULT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "config", "KobitoKey.keymap")


def parse(text):
    combos = []
    m = re.search(r"combos\s*\{(.*?)\n    \};", text, re.S)
    body = m.group(1) if m else ""
    for cm in re.finditer(r"(\w+)\s*\{(.*?)\};", body, re.S):
        name, blk = cm.group(1), cm.group(2)
        pos = re.search(r"key-positions\s*=\s*<([^>]*)>", blk)
        if not pos:
            continue
        layers = re.search(r"layers\s*=\s*<([^>]*)>", blk)
        binding = re.search(r"bindings\s*=\s*<([^>]*)>", blk)
        combos.append({
            "name": name,
            "positions": sorted(int(x) for x in pos.group(1).split()),
            "layers": [int(x) for x in layers.group(1).split()] if layers else None,
            "binding": binding.group(1).strip() if binding else "",
        })
    return combos


def base_legend(text):
    m = re.search(r"default_layer\s*\{.*?bindings\s*=\s*<(.*?)>;", text, re.S)
    if not m:
        return []
    toks = re.split(r"\s*&", m.group(1).strip())
    keys = []
    for t in toks:
        t = t.strip()
        if not t:
            continue
        keys.append(re.sub(r"^(kp|lt|mt)\s+", "", t))
    return keys


def layers_overlap(a, b):
    return a is None or b is None or bool(set(a) & set(b))


def main():
    args = sys.argv[1:]
    path = DEFAULT
    has = None
    i = 0
    while i < len(args):
        if args[i] == "--has":
            has = args[i + 1]
            i += 2
        else:
            path = args[i]
            i += 1
    text = open(path, encoding="utf-8").read()
    combos = parse(text)

    if has is not None:
        if any(c["name"] == has for c in combos):
            print(f"ok: {has} は定義されています")
            return 0
        print(f"NG: {has} が見つかりません")
        return 1

    legend = base_legend(text)
    print("ベースレイヤーの刻印（位置: 刻印）")
    for r in range(4):
        row = [f"{r * 10 + c}:{legend[r * 10 + c]}" if len(legend) > r * 10 + c else "?" for c in range(10)]
        print("  " + "  ".join(row))
    print("\nコンボ")
    for c in combos:
        keys = "+".join(legend[p] if p < len(legend) else str(p) for p in c["positions"])
        lay = "全レイヤー" if c["layers"] is None else f"layers={c['layers']}"
        print(f"  {c['name']}: 位置{c['positions']} ({keys}) -> {c['binding']} [{lay}]")

    bad = []
    for i, a in enumerate(combos):
        for b in combos[i + 1:]:
            sa, sb = set(a["positions"]), set(b["positions"])
            if (sa <= sb or sb <= sa) and layers_overlap(a["layers"], b["layers"]):
                bad.append((a["name"], b["name"]))
    if bad:
        print("\nNG: 位置が重なるコンボがあります")
        for a, b in bad:
            print(f"  {a} と {b}")
        return 1
    print("\nok: 位置が重なるコンボはありません")
    return 0


if __name__ == "__main__":
    sys.exit(main())
