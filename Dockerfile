FROM opensandbox/code-interpreter:latest

USER root

# 環境変数設定
ENV DEBIAN_FRONTEND=noninteractive \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH \
    OPENCODE_CONFIG=/root/.config/opencode/opencode.json \
    PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium

# 1. ビルドヘッダー、エージェント支援ツール、Xvfb、jq、Chromium 本体のインストール
RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config \
    libssl-dev \
    libreadline-dev \
    ripgrep \
    xvfb \
    xauth \
    jq \
    chromium \
    fonts-liberation \
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

# 4. LuaJIT (デフォルトブランチ動的ビルド)
RUN git clone --depth 1 https://github.com/LuaJIT/LuaJIT.git /tmp/luajit && \
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

# 8. OpenCodeReview (全 Node.js バージョンへの動的グローバルインストール)
RUN set -euo pipefail && \
    for node_dir in /opt/node/v*; do \
        if [ -d "${node_dir}/bin" ]; then \
            echo "Installing open-code-review for $(basename "${node_dir}")" && \
            PATH="${node_dir}/bin:${PATH}" "${node_dir}/bin/npm" install -g open-code-review || echo "Skipping $(basename "${node_dir}") due to compatibility"; \
        fi \
    done && \
    # 最新バージョンの Node.js から /usr/local/bin へ CLI をリンク
    latest_dir=$(ls -d /opt/node/v* | sort -V | tail -n 1) && \
    node_bin_dir="${latest_dir}/bin" && \
    for bin in ocr open-code-review; do \
        if [ -e "${node_bin_dir}/${bin}" ]; then \
            ln -sf "${node_bin_dir}/${bin}" "/usr/local/bin/${bin}"; \
        fi \
    done

# 9. 全 Python バージョンへのパッケージ群のインストール (open-code-review を除外)
RUN set -euo pipefail && \
    packages=(browser-use semgrep codebase-memory-mcp playwright) && \
    for py_bin in /opt/python/versions/cpython-*/bin/python3; do \
        echo "Installing tools for: $py_bin" && \
        uv pip install --python "$py_bin" "${packages[@]}" || echo "Skipping package install for $py_bin due to compatibility"; \
    done

# 10. 各ツールの CLI バイナリを /usr/local/bin に確実にリンク (最新バージョンを動的選択)
RUN LATEST_PY_BIN_DIR=$(ls -d /opt/python/versions/cpython-*/bin | sort -V | tail -n 1) && \
    echo "Linking Python CLI tools from latest version: ${LATEST_PY_BIN_DIR}" && \
    for tool in semgrep codebase-memory-mcp browser-use playwright; do \
        if [ -x "${LATEST_PY_BIN_DIR}/${tool}" ]; then \
            ln -sf "${LATEST_PY_BIN_DIR}/${tool}" "/usr/local/bin/${tool}"; \
        fi \
    done

# 11. Browser Use / Playwright 用のブラウザ確認
RUN /usr/bin/chromium --version || echo "Chromium installed successfully"

# 12. OpenCode の初期設定テンプレート (MCP サーバー定義)
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

# 13. 統合起動エントリポイントスクリプト
RUN cat <<'EOF' > /usr/local/bin/custom-entrypoint.sh
#!/bin/bash
set -e

DUMMY_KEY="vault-managed-key"

# 13.1. OpenCode 設定 (モデル名とURLのみ注入、キーはダミー固定)
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

# 13.2. OpenCodeReview 設定
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

# 13.3. Semgrep MCP サーバーの起動 (streamable-http)
if command -v semgrep >/dev/null 2>&1; then
    semgrep mcp --transport streamable-http --port 8000 &
fi

# 13.4. OpenCode serve の起動 (ポート 4096)
if command -v opencode >/dev/null 2>&1; then
    opencode serve --port 4096 --hostname 0.0.0.0 &
fi

# 13.5. Code Interpreter 元のエントリポイント実行
exec /opt/code-interpreter/code-interpreter.sh "$@"
EOF

RUN chmod +x /usr/local/bin/custom-entrypoint.sh

EXPOSE 4096 8000

ENTRYPOINT ["/usr/local/bin/custom-entrypoint.sh"]
