#!/bin/bash

# KobitoKey ファームウェア Docker 初期化スクリプト
# Docker イメージのダウンロードと West ワークスペースの初期化を行います

set -e  # エラーが発生したら即座に終了

# 設定
IMAGE="zmkfirmware/zmk-build-arm:stable"
WORKSPACE="/workspace"

# 色付き出力
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# ヘルパー関数: Docker を実行
run_docker() {
    # TTYが利用可能かチェック
    if [ -t 0 ]; then
        local TTY_FLAG="-it"
    else
        local TTY_FLAG="-i"
    fi

    docker run --rm $TTY_FLAG \
        --user $(id -u):$(id -g) \
        -v "$PWD:$WORKSPACE" \
        -w "$WORKSPACE" \
        -e HOME="$WORKSPACE" \
        -e ZEPHYR_BASE="$WORKSPACE/zephyr" \
        "$IMAGE" \
        "$@"
}

# 依存モジュール更新（詳細ログ＋失敗時診断付き）
update_modules() {
    echo -e "${BLUE}[3/4] 依存モジュールを更新中...${NC}"
    echo -e "${YELLOW}この処理には数分かかる場合があります${NC}"

    # west の詳細ログを有効化して試行
    echo -e "${YELLOW}west の詳細ログを有効化して更新しています...${NC}"
    set +e
    run_docker env WEST_LOGGER_LEVEL=DEBUG west -v update
    local status=$?
    set -e

    if [ $status -ne 0 ]; then
        echo -e "${RED}west update が失敗しました。詳細診断を開始します...${NC}"

        echo -e "${YELLOW}west のキャッシュ情報と設定を表示します${NC}"
        set +e
        run_docker west config --list
        run_docker west list
        run_docker west manifest --path
        # tinycrypt は Zephyr の project imports で解決されるため配置は modules/crypto/tinycrypt
        run_docker git --no-pager -C modules/crypto/tinycrypt status || true
        run_docker git --no-pager -C modules/crypto/tinycrypt remote -v || true
        run_docker git --no-pager -C modules/crypto/tinycrypt rev-parse HEAD || true
        set -e

        echo -e "${YELLOW}tinycrypt ディレクトリを初期化して、plain 'west update' で再取得を試みます${NC}"
        set +e
        run_docker rm -rf modules/crypto/tinycrypt
        # 個別更新は project imports では拒否されるため、必ず plain update を使用
        run_docker env WEST_LOGGER_LEVEL=DEBUG west -v update
        local re_status=$?
        set -e

        if [ $re_status -ne 0 ]; then
            echo -e "${RED}再試行の west update も失敗しました。ログを確認して対応してください。${NC}"
            return 1
        fi
    fi

    echo -e "${GREEN}✓ 依存モジュールの更新が完了しました${NC}"
}

# メイン処理
main() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}KobitoKey ビルド環境の初期化${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""

    # ステップ 1: Docker イメージのダウンロード
    echo -e "${BLUE}[1/4] Docker イメージをダウンロード中...${NC}"
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
        echo -e "${YELLOW}既に Docker イメージが存在します。最新版を確認中...${NC}"
        docker pull "$IMAGE"
    else
        docker pull "$IMAGE"
    fi
    echo -e "${GREEN}✓ Docker イメージの準備が完了しました${NC}"
    echo ""

    # ステップ 2: West ワークスペースの初期化
    echo -e "${BLUE}[2/4] West ワークスペースを初期化中...${NC}"
    if [ -d ".west" ]; then
        echo -e "${YELLOW}.west ディレクトリが既に存在します。スキップします。${NC}"
    else
        run_docker west init -l config
        echo -e "${GREEN}✓ West ワークスペースの初期化が完了しました${NC}"
    fi
    echo ""

    # ステップ 3: 依存モジュールの更新（詳細ログ＆診断付）
    update_modules || error_handler_for_update
    echo ""

    # ステップ 4: Zephyr のエクスポート
    echo -e "${BLUE}[4/4] Zephyr をエクスポート中...${NC}"
    set +e
    # HOME と ZEPHYR_BASE を明示して実行（コンテナ内でも再確認）
    run_docker env HOME="$WORKSPACE" ZEPHYR_BASE="$WORKSPACE/zephyr" WEST_LOGGER_LEVEL=DEBUG west zephyr-export
    ZE_STATUS=$?
    set -e

    if [ ${ZE_STATUS} -ne 0 ]; then
        echo -e "${RED}west zephyr-export が失敗しました。追加診断を実施します...${NC}"
        echo -e "${YELLOW}ZEPHYR_BASE とエクスポート CMake スクリプトの存在を確認します${NC}"
        run_docker sh -lc 'echo "HOME=$HOME"; echo "ZEPHYR_BASE=$ZEPHYR_BASE"; ls -la /workspace/zephyr/share/zephyr-package/cmake/ || true; ls -la ~/.cmake/packages || true'

        echo -e "${YELLOW}CMake スクリプトを直接トレース付きで実行して詳細を表示します${NC}"
        set +e
        run_docker cmake -Wdev --trace-expand -P /workspace/zephyr/share/zephyr-package/cmake/zephyr_export.cmake
        CM_STATUS=$?
        set -e

        if [ ${CM_STATUS} -ne 0 ]; then
            echo -e "${RED}CMake 直接実行でも失敗しました。出力ログを参照してください。${NC}"
            error_handler_for_update
        fi
    fi

    echo -e "${GREEN}✓ Zephyr のエクスポートが完了しました${NC}"
    echo ""

    # 完了メッセージ
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}初期化が完了しました！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${YELLOW}次のステップ:${NC}"
    echo -e "  1. キーマップを編集: ${BLUE}config/KobitoKey.keymap${NC}"
    echo -e "  2. ファームウェアをビルド: ${BLUE}./docker-build.sh${NC}"
    echo ""
    echo -e "${YELLOW}参考ドキュメント:${NC}"
    echo -e "  - Docker ビルドガイド: ${BLUE}DOCKER_BUILD_SETUP.md${NC}"
    echo ""
}

# エラーハンドラー（一般）
error_handler() {
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}エラーが発生しました${NC}"
    echo -e "${RED}========================================${NC}"
    echo ""
    echo -e "${YELLOW}トラブルシューティング:${NC}"
    echo -e "  1. Docker Desktop が起動していることを確認してください"
    echo -e "     コマンド: ${BLUE}docker --version${NC}"
    echo ""
    echo -e "  2. インターネット接続を確認してください"
    echo ""
    echo -e "  3. .west ディレクトリがある場合は削除して再試行してください"
    echo -e "     コマンド: ${BLUE}rm -rf .west zmk modules${NC}"
    echo ""
    echo -e "  4. 詳細は DOCKER_BUILD_SETUP.md を参照してください"
    echo ""
    exit 1
}

# west update 専用のエラーハンドラー（詳細ログ後に終了）
error_handler_for_update() {
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}依存モジュールの更新に失敗しました${NC}"
    echo -e "${RED}========================================${NC}"
    echo ""
    echo -e "${YELLOW}追加の対処:${NC}"
    echo -e "  - 必要なら ${BLUE}rm -rf modules/crypto/tinycrypt${NC} の後に再実行"
    echo -e "  - ネットワークや GitHub へのアクセス状況を確認"
    echo -e "  - west の manifest や config の整合性確認"
    exit 1
}

trap error_handler ERR

# 確認メッセージ
if [ -d ".west" ] || [ -d "zmk" ]; then
    echo -e "${YELLOW}警告: .west または zmk ディレクトリが既に存在します。${NC}"
    echo -e "${YELLOW}既存の設定を保持したまま、必要な更新のみを行います。${NC}"
    echo ""
    read -p "続行しますか? [Y/n] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]] && [[ ! -z $REPLY ]]; then
        echo -e "${YELLOW}中止しました${NC}"
        exit 0
    fi
fi

# スクリプト実行
main "$@"
