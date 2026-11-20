#!/bin/bash

# KobitoKey 反映スクリプト: 取り込み → ビルド → 書き込み を 1 コマンドで行う
# ドングルなし構成。書き込むのは左側（セントラル）だけ。
#
# 使い方:
#   ./flash.sh          左側をビルドして書き込む
#   ./flash.sh --all    右側もビルドする（書き込みは左側だけ。右側の uf2 は build/ に残る）
#
# テスト用に次の環境変数で差し替えられる:
#   DOCKER_BIN     docker コマンド（既定: docker）
#   DRIVE_GLOB     ブートローダーのドライブ（既定: /Volumes/XIAO*）
#   WAIT_SECONDS   ドライブを待つ秒数（既定: 120）
#   POLL_INTERVAL  ドライブを調べる間隔の秒数（既定: 1）

set -e

IMAGE="zmkfirmware/zmk-build-arm:stable"
WORKSPACE="/workspace"
DOCKER_BIN="${DOCKER_BIN:-docker}"
DRIVE_GLOB="${DRIVE_GLOB:-/Volumes/XIAO*}"
WAIT_SECONDS="${WAIT_SECONDS:-120}"
POLL_INTERVAL="${POLL_INTERVAL:-1}"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

BUILD_ALL=0
for arg in "$@"; do
    case "$arg" in
        --all) BUILD_ALL=1 ;;
        -h|--help)
            sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo -e "${RED}不明な引数: $arg${NC}" >&2
            exit 2
            ;;
    esac
done

cd "$(dirname "$0")"

fail() {
    echo -e "${RED}$1${NC}" >&2
    exit 1
}

run_docker() {
    local tty_flag="-i"
    [ -t 0 ] && tty_flag="-it"
    "$DOCKER_BIN" run --rm $tty_flag \
        --user "$(id -u):$(id -g)" \
        -v "$PWD:$WORKSPACE" \
        -w "$WORKSPACE" \
        -e HOME="$WORKSPACE" \
        "$IMAGE" \
        "$@"
}

build_target() {
    local name=$1 dir=$2 shield=$3
    echo -e "${BLUE}ビルド中: ${name}${NC}"
    run_docker west build -s zmk/app -p -d "$dir" -b seeeduino_xiao_ble -- \
        -DZMK_CONFIG="$WORKSPACE/config" \
        -DZephyr_DIR="$WORKSPACE/zephyr/share/zephyr-package/cmake" \
        -DSHIELD="$shield"
    [ -f "$dir/zephyr/zmk.uf2" ] || fail "${name} の uf2 ができていません: $dir/zephyr/zmk.uf2"
    echo -e "${GREEN}✓ ${name} のビルドが完了しました${NC}"
}

find_drive() {
    local d
    for d in $DRIVE_GLOB; do
        [ -d "$d" ] && { echo "$d"; return 0; }
    done
    return 1
}

# 1. 取り込み（fast-forward だけ。衝突や未コミットの変更があれば止まる）
echo -e "${YELLOW}1/4 変更を取り込みます${NC}"
if ! git diff --quiet || ! git diff --cached --quiet; then
    fail "未コミットの変更があります。コミットするか戻してから、もう一度実行してください。"
fi
if ! git pull --ff-only; then
    fail "取り込めませんでした（fast-forward できない、または通信の失敗）。自動では解決しません。手元の状態を確かめてください。"
fi

# 2. ビルド
echo -e "${YELLOW}2/4 ビルドします${NC}"
if ! "$DOCKER_BIN" image inspect "$IMAGE" >/dev/null 2>&1; then
    "$DOCKER_BIN" pull "$IMAGE"
fi
run_docker bash -lc 'mkdir -p "$HOME/.cmake/packages" && west zephyr-export'
build_target "左側キーボード" "build/left_dongleless" "KobitoKey_left rgbled_adapter"
if [ "$BUILD_ALL" -eq 1 ]; then
    build_target "右側キーボード" "build/right_dongleless" "KobitoKey_right rgbled_adapter"
fi

# 3. ブートローダーのドライブを待つ
echo -e "${YELLOW}3/4 左側の XIAO を USB でつなぎ、リセットボタンをダブルタップしてください${NC}"
echo "    ドライブが現れるまで最大 ${WAIT_SECONDS} 秒待ちます。"
drive=""
waited=0
while [ "$waited" -lt "$WAIT_SECONDS" ]; do
    if drive=$(find_drive); then
        break
    fi
    drive=""
    sleep "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))
done
[ -n "$drive" ] || fail "${WAIT_SECONDS} 秒たってもブートローダーのドライブが現れませんでした。ビルドは済んでいます。build/left_dongleless/zephyr/zmk.uf2 を手でコピーするか、もう一度実行してください。"

# 4. 書き込み
echo -e "${YELLOW}4/4 書き込みます: $drive${NC}"
cp "build/left_dongleless/zephyr/zmk.uf2" "$drive/"
sync

# 書き込みが終わると XIAO が再起動し、ドライブが消える
for _ in $(seq 1 10); do
    find_drive >/dev/null || { gone=1; break; }
    sleep "$POLL_INTERVAL"
done
if [ "${gone:-0}" -eq 1 ]; then
    echo -e "${GREEN}✓ 書き込みが完了しました。XIAO が再起動しました${NC}"
else
    echo -e "${YELLOW}コピーはしましたが、ドライブがまだ見えています。数秒待っても消えなければ、つなぎ直してください${NC}"
fi
