#!/bin/bash
# flash.sh の振る舞いテスト。docker とブートローダーのドライブは差し替える。
# 使い方: tests/flash_test.sh

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; failn=0

ok()   { echo "  ok: $1"; pass=$((pass + 1)); }
ng()   { echo "  NG: $1"; failn=$((failn + 1)); }
check() { # 説明, 条件のコマンド...
    local d=$1; shift
    if "$@"; then ok "$d"; else ng "$d"; fi
}

# docker のスタブ。west build のとき -d の先に uf2 を作る
cat > "$TMP/docker" <<'STUB'
#!/bin/bash
case "$1" in
    image) exit 0 ;;
    run)
        args=("$@")
        for i in "${!args[@]}"; do
            if [ "${args[$i]}" = "-d" ]; then
                d="${args[$((i+1))]}"
                mkdir -p "$d/zephyr"
                echo "UF2:$d" > "$d/zephyr/zmk.uf2"
            fi
        done
        echo "$@" >> "$STUB_LOG"
        exit 0 ;;
esac
STUB
chmod +x "$TMP/docker"

# 新しい作業用の clone を作る
setup() {
    rm -rf "$TMP/origin.git" "$TMP/work" "$TMP/other" "$TMP/drive"
    git init -q --bare "$TMP/origin.git"
    git clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
    (cd "$TMP/work" && git config user.email t@t && git config user.name t \
        && echo a > file && cp "$ROOT/flash.sh" . && git add . && git commit -qm init && git push -q origin HEAD 2>/dev/null)
    git clone -q "$TMP/origin.git" "$TMP/other" 2>/dev/null
    (cd "$TMP/other" && git config user.email t@t && git config user.name t)
    : > "$TMP/stub.log"
}

run_flash() { # 引数...
    (cd "$TMP/work" && STUB_LOG="$TMP/stub.log" DOCKER_BIN="$TMP/docker" \
        DRIVE_GLOB="$TMP/drive*" WAIT_SECONDS=3 POLL_INTERVAL=1 ./flash.sh "$@") > "$TMP/out.log" 2>&1
}

echo "[1] 正常: uf2 がドライブに置かれる"
setup
( sleep 1; mkdir "$TMP/drive" ) &
run_flash
rc=$?
wait
check "終了コードが 0" [ "$rc" -eq 0 ]
check "左側の uf2 が置かれた" grep -q "left_dongleless" "$TMP/drive/zmk.uf2"
check "右側はビルドされない" bash -c "! grep -q right_dongleless '$TMP/stub.log'"

echo "[2] --all: 右側もビルドされるが、書き込むのは左側だけ"
setup
( sleep 1; mkdir "$TMP/drive" ) &
run_flash --all
rc=$?
wait
check "終了コードが 0" [ "$rc" -eq 0 ]
check "右側もビルドされた" grep -q "right_dongleless" "$TMP/stub.log"
check "ドライブには左側の uf2" grep -q "left_dongleless" "$TMP/drive/zmk.uf2"

echo "[3] 取り込みが fast-forward できないとき: 止まる"
setup
(cd "$TMP/other" && echo b > file && git commit -qam remote && git push -q origin HEAD 2>/dev/null)
(cd "$TMP/work" && echo c > file2 && git add file2 && git commit -qm local)
run_flash
rc=$?
check "終了コードが 0 以外" [ "$rc" -ne 0 ]
check "ビルドは走っていない" [ ! -s "$TMP/stub.log" ]

echo "[4] 未コミットの変更があるとき: 止まる"
setup
(cd "$TMP/work" && echo dirty > file)
run_flash
rc=$?
check "終了コードが 0 以外" [ "$rc" -ne 0 ]
check "ビルドは走っていない" [ ! -s "$TMP/stub.log" ]
check "手元の変更が残っている" grep -q dirty "$TMP/work/file"

echo "[5] ドライブが現れないとき: 時間切れで終わる"
setup
run_flash
rc=$?
check "終了コードが 0 以外" [ "$rc" -ne 0 ]
check "時間切れが知らされる" grep -q "現れませんでした" "$TMP/out.log"

echo "[6] 不明な引数"
setup
run_flash --nope
rc=$?
check "終了コードが 2" [ "$rc" -eq 2 ]

echo
echo "合計: ok=$pass NG=$failn"
[ "$failn" -eq 0 ]
