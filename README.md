# opensandbox-code-interpreter-custom

> [!CAUTION]
> 非公式/Unofficial

https://github.com/opensandbox-group/sandbox-images の opensandbox/code-interpreter をベースに、カスタムイメージを各種最新版で自動的に作る

## 同梱パッケージ
- [Rust](https://github.com/rust-lang/rust)
- [Cargo](https://github.com/rust-lang/cargo)
- [Clippy](https://github.com/rust-lang/rust-clippy)
- [rustfmt](https://github.com/rust-lang/rustfmt)
- [Lua](https://github.com/lua/lua)
- [LuaJIT](https://github.com/luajit/luajit)
- [LuaRocks](https://github.com/luarocks/luarocks)
- [OpenCode](https://github.com/anomalyco/opencode)
- [Browser Use](https://github.com/browser-use/browser-use)
- [codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp)
- [Semgrep](https://github.com/semgrep/semgrep)
- [OpenCodeReview](https://github.com/alibaba/open-code-review)
- [ripgrep](https://github.com/burntsushi/ripgrep)

---

## 特記事項

### 1. 動的最新版追従と自動ビルド
- **最新版の動的解決**: 固定バージョンをハードコードせず、Lua/LuaRocks のソースビルド、Rust 安定版、PyPI パッケージをビルド時点の最新バージョンで解決します。
- **無駄ビルドの抑止**: GitHub Actions（`.github/workflows/build.yml`）が 6 時間ごとにベースイメージおよび各コンポーネントの最新状態をチェックし、ハッシュ値に差分が生じた場合のみマルチアーキテクチャ（amd64 / arm64）イメージの再ビルドを行います。
- **GitHub API レート制限回避**: バージョン取得処理は HTTP リダイレクトヘッダーや PyPI/FTP インデックスを利用し、未認証トークン制限によるビルド失敗を防ぎます。

### 2. 実行アーキテクチャ & 常駐プロセス
コンテナ起動時、カスタムエントリポイントによって以下のデーモン・サーバーが自動常駐し、元のベースイメージ機能（Jupyter/Code Interpreter）も並行して維持されます。

| サービス | ポート | 種別 / 用途 |
|---|---|---|
| **OpenCode** | `4096` | REST API サーバー（`opencode serve --port 4096 --hostname 0.0.0.0`） |
| **Semgrep** | `8000` | Streamable HTTP MCP サーバー（`semgrep mcp --transport streamable-http`） |
| **Jupyter Server** | `44771` | ベースイメージの Jupyter カーネルデーモン |
| **codebase-memory-mcp** | - | OpenCode の `local` (stdio) MCP ツールとして事前設定済み |
| **OpenCodeReview** | - | オンデマンド CLI（`ocr` コマンドで実行） |
| **Browser Use** | - | Playwright / Chromium 同梱（Xvfb 対応でヘッドレス/GUI 実行可能） |

### 3. OpenCode の MCP 設定
コンテナ内の `/root/.config/opencode/opencode.json` にて、常駐する Semgrep MCP サーバーおよび codebase-memory-mcp があらかじめ登録されています。
```json
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
```

---

## 起動方法 & 設定

### 環境変数 (LLM 接続情報)
セルフホスト LLM サーバー等のエンドポイントやモデル名は、コンテナ起動時の環境変数経由で動的に設定されます。

| 環境変数 | 説明 | デフォルト値 |
|---|---|---|
| `LLM_BASE_URL` | LLM サーバーの Base URL (OpenCode & OpenCodeReview 共通) | なし |
| `LLM_MODEL` | 使用するモデル名 (共通) | `default-model` |
| `OPENCODE_BASE_URL` | OpenCode 専用の Base URL 上書き | `${LLM_BASE_URL}` |
| `OPENCODE_MODEL` | OpenCode 専用のモデル名上書き | `${LLM_MODEL}` |
| `OCR_BASE_URL` | OpenCodeReview 専用の Base URL 上書き | `${LLM_BASE_URL}` |
| `OCR_MODEL` | OpenCodeReview 専用のモデル名上書き | `${LLM_MODEL}` |

### セキュリティ: OpenSandbox Credential Vault との連携
エージェントによるプロンプトインジェクションやシェル操作から本物の API キー漏洩を防ぐため、**コンテナ内部の設定ファイルには本物のトークンを永続化せず、ダミートークン（`vault-managed-key`）を自動設定します。**

本物の認証キーは OpenSandbox の [Credential Vault](https://open-sandbox.ai/guides/credential-vault)（Egress Sidecar）で透過的に差し替えて運用することを推奨します。

#### OpenSandbox SDK での利用例 (Python)
```python
from opensandbox import Sandbox, SandboxCreateOptions

sandbox = Sandbox.create(
    SandboxCreateOptions(
        image="ghcr.io/<owner>/opensandbox-code-interpreter-custom:latest",
        # 1. 宛先ホストのみを許可するネットワークポリシー
        network_policy={
            "defaultAction": "deny",
            "egress": [
                {"action": "allow", "target": "llm.internal.example.com"}
            ]
        },
        # 2. Credential Proxy の有効化
        credential_proxy={"enabled": True},
        # 3. エンドポイントとモデル名の設定 (コンテナ内に渡す非機密情報)
        env={
            "LLM_BASE_URL": "http://llm.internal.example.com:8000/v1",
            "LLM_MODEL": "qwen2.5-coder-32b"
        }
    )
)

# 4. 本物の認証キーを Sidecar の Vault に登録 (コンテナ内からは一切閲覧不可)
sandbox.vault.set_credential("llm-secret", "sk-real-secret-token-xxxxxx")

# 5. コンテナ外への通信時に Bearer ヘッダーを本物のトークンに透過置換
sandbox.vault.add_binding(
    host="llm.internal.example.com",
    match={"paths": ["/v1/*"], "methods": ["POST"]},
    auth={"type": "bearer", "credential": "llm-secret"}
)
```