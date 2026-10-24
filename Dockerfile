FROM opensandbox/code-interpreter:latest

USER root

# 環境変数設定
ENV DEBIAN_FRONTEND=noninteractive \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH \
    OPENCODE_CONFIG=/root/.config/opencode/opencode.json

# 1. ビルドヘッダー、エージェント支援ツール、Xvfb、jq のインストール
RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config \
    libssl-dev \
    libreadline-dev \
    ripgrep \
    xvfb \
    xauth \
    jq \
    && rm -rf /var/lib/apt/lists/*

# 2. Rust, Cargo, Clippy, rustfmt (最新安定版)
RUN mkdir -p /usr/local/rustup /usr/local/cargo && \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
        --default-toolchain stable \
        --profile minimal \
        --no-modify-path && \
    /usr/local/cargo/bin/rustup component add clippy rustfmt && \
    chmod -R a+w /usr/local/rustup /usr/local/cargo

    # 3. Lua (最新安定版動的ビルド)
RUN LUA_TARBALL=$(curl -fsSL https://www.lua.org/ftp/ | grep -oE 'lua-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' | sort -V | tail -n 1) && \
    echo "Building Lua: ${LUA_TARBALL}" && \
    curl -fsSL "https://www.lua.org/ftp/${LUA_TARBALL}" -o /tmp/lua.tar.gz && \
    mkdir -p /tmp/lua && \
    tar -xzf /tmp/lua.tar.gz -C /tmp/lua --strip-components=1 && \
    cd /tmp/lua && \
    make all test && \
    make install INSTALL_TOP=/usr/local && \
    rm -rf /tmp/lua*

# 4. LuaJIT (最新安定ブランチ v2.1)
RUN git clone --depth 1 --branch v2.1 https://github.com/LuaJIT/LuaJIT.git /tmp/luajit && \
    cd /tmp/luajit && \
    make && \
    make install PREFIX=/usr/local && \
    ln -sf /usr/local/bin/luajit-* /usr/local/bin/luajit && \
    rm -rf /tmp/luajit

# 5. LuaRocks (GitHub releases/latest のリダイレクトURLより動的ビルド)
RUN LUAROCKS_VER=$(curl -fsSL -o /dev/null -w "%{url_effective}" https://github.com/luarocks/luarocks/releases/latest | sed 's|.*/v\?||') && \
    echo "Building LuaRocks: ${LUAROCKS_VER}" && \
    curl -fsSL "https://luarocks.org/releases/luarocks-${LUAROCKS_VER}.tar.gz" -o /tmp/luarocks.tar.gz && \
    mkdir -p /tmp/luarocks && \
    tar -xzf /tmp/luarocks.tar.gz -C /tmp/luarocks --strip-components=1 && \
    cd /tmp/luarocks && \
    ./configure --prefix=/usr/local --with-lua=/usr/local && \
    make && \
    make install && \
    rm -rf /tmp/luarocks*

# 共有ライブラリのパス更新
RUN ldconfig /usr/local/lib

# 6. 動的に解決された Lua バージョンから LUA_PATH / LUA_CPATH を構成
RUN LUA_MAJOR_MINOR=$(lua -e 'print(_VERSION:match("%d+%.%d+"))') && \
    LUA_PATH_VAL="/usr/local/share/lua/${LUA_MAJOR_MINOR}/?.lua;/usr/local/share/lua/${LUA_MAJOR_MINOR}/?/init.lua;;" && \
    LUA_CPATH_VAL="/usr/local/lib/lua/${LUA_MAJOR_MINOR}/?.so;;" && \
    echo "LUA_PATH=\"${LUA_PATH_VAL}\"" >> /etc/environment && \
    echo "LUA_CPATH=\"${LUA_CPATH_VAL}\"" >> /etc/environment && \
    mkdir -p /etc/profile.d && \
    echo "export LUA_PATH=\"${LUA_PATH_VAL}\"" > /etc/profile.d/lua.sh && \
    echo "export LUA_CPATH=\"${LUA_CPATH_VAL}\"" >> /etc/profile.d/lua.sh && \
    chmod +x /etc/profile.d/lua.sh

# 7. OpenCode (最新バイナリを /usr/local/bin に配置)
RUN curl -fsSL https://raw.githubusercontent.com/anomalyco/opencode/main/install.sh | bash -s -- --dir /usr/local/bin

# 8. 全 Python バージョンへのパッケージ群のインストール
RUN set -euo pipefail && \
    packages=(browser-use semgrep open-code-review codebase-memory-mcp playwright) && \
    for py_bin in /opt/python/versions/cpython-*/bin/python3; do \
        echo "Installing tools for: $py_bin" && \
        uv pip install --python "$py_bin" "${packages[@]}" || echo "Skipping package install for $py_bin due to compatibility"; \
    done

# 各ツールの CLI バイナリをシステム共通の /usr/local/bin にリンク
RUN DEFAULT_PY_BIN=$(ls -d /opt/python/versions/cpython-3.12*/bin | head -n 1) && \
    for tool in semgrep open-code-review ocr codebase-memory-mcp browser-use playwright; do \
        if [ -f "${DEFAULT_PY_BIN}/${tool}" ]; then \
            ln -sf "${DEFAULT_PY_BIN}/${tool}" "/usr/local/bin/${tool}"; \
        fi \
    done

# 9. Browser Use 用 Chromium & 依存システムライブラリのインストール
# （システム領域と /root/.cache/ms-playwright に配置されるため全バージョンで共有可能）
RUN playwright install-deps chromium && \
    playwright install chromium

# 10. OpenCode の初期設定テンプレート (MCP サーバー定義)
RUN mkdir -p /root/.config/opencode && \
    cat <<'EOF' > /root/.config/opencode/opencode.json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "codebase-memory": {
      "type": "local",
      "command": "codebase-memory-mcp"
    },
    "semgrep": {
      "type": "remote",
      "url": "http://127.0.0.1:8000/mcp"
    }
  }
}
EOF

# 11. 統合起動エントリポイントスクリプト (Vault前提: ダミートークンで設定構成)
RUN cat <<'EOF' > /usr/local/bin/custom-entrypoint.sh
#!/bin/bash
set -e

# 固定のダミーキー (本物の鍵は OpenSandbox Egress Sidecar 側で差し替える)
DUMMY_KEY="vault-managed-key"

# 1. OpenCode 設定 (モデル名とURLのみ注入、キーはダミー固定)
OPENCODE_CFG="/root/.config/opencode/opencode.json"
mkdir -p "$(dirname "${OPENCODE_CFG}")"

if [ -n "${OPENCODE_BASE_URL}" ] || [ -n "${OPENCODE_MODEL}" ] || [ -n "${LLM_BASE_URL}" ]; then
    BASE_URL="${OPENCODE_BASE_URL:-${LLM_BASE_URL}}"
    MODEL_NAME="${OPENCODE_MODEL:-${LLM_MODEL:-default-model}}"
    PROVIDER_ID="${OPENCODE_PROVIDER:-selfhosted}"

    TMP_JSON=$(mktemp)
    jq \
      --arg provider "${PROVIDER_ID}" \
      --arg url "${BASE_URL}" \
      --arg model "${MODEL_NAME}" \
      --arg key "${DUMMY_KEY}" \
      '
      .model = ($provider + "/" + $model) |
      .providers[$provider] = {
        "type": "openai",
        "baseURL": $url,
        "apiKey": $key,
        "models": [$model]
      }
      ' "${OPENCODE_CFG}" > "${TMP_JSON}" && mv "${TMP_JSON}" "${OPENCODE_CFG}"
fi

# 2. OpenCodeReview 設定 (モデル名とURLのみ注入、キーはダミー固定)
OCR_CFG_DIR="/root/.opencodereview"
OCR_CFG="${OCR_CFG_DIR}/config.json"
mkdir -p "${OCR_CFG_DIR}"

if [ ! -f "${OCR_CFG}" ]; then
    echo "{}" > "${OCR_CFG}"
fi

if [ -n "${OCR_BASE_URL}" ] || [ -n "${LLM_BASE_URL}" ]; then
    OCR_URL="${OCR_BASE_URL:-${LLM_BASE_URL}}"
    OCR_MDL="${OCR_MODEL:-${LLM_MODEL:-default-model}}"
    OCR_PRV="${OCR_PROVIDER:-custom-selfhosted}"

    TMP_OCR=$(mktemp)
    jq \
      --arg provider "${OCR_PRV}" \
      --arg url "${OCR_URL}" \
      --arg model "${OCR_MDL}" \
      --arg key "${DUMMY_KEY}" \
      '
      .provider = $provider |
      .model = $model |
      .custom_providers[$provider] = {
        "protocol": "openai",
        "endpoint": $url,
        "api_key": $key,
        "models": [$model]
      }
      ' "${OCR_CFG}" > "${TMP_OCR}" && mv "${TMP_OCR}" "${OCR_CFG}"
fi

# 3. Semgrep MCP サーバーの起動 (streamable-http)
if command -v semgrep >/dev/null 2>&1; then
    semgrep mcp --transport streamable-http --port 8000 &
fi

# 4. OpenCode serve の起動 (ポート 4096)
if command -v opencode >/dev/null 2>&1; then
    opencode serve --port 4096 --hostname 0.0.0.0 &
fi

# 5. Code Interpreter 元のエントリポイント実行
exec /opt/code-interpreter/code-interpreter.sh "$@"
EOF

RUN chmod +x /usr/local/bin/custom-entrypoint.sh

EXPOSE 4096 8000

ENTRYPOINT ["/usr/local/bin/custom-entrypoint.sh"]
