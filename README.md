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
- **最新版の動的解決**: 固定バージョンをハードコードせず、Lua / LuaRocks のソースビルド、Rust 安定版、PyPI パッケージ、npm パッケージをビルド時点の最新バージョンで解決・構築します。
- **マルチランタイム対応**: ベースイメージに同梱されているすべての Python バージョン（`/opt/python/versions/cpython-*`）および Node.js バージョン（`/opt/node/v*`）に対してツール群をインストールし、最新バージョンのバイナリを `/usr/local/bin` へシンボリックリンク配置します。
- **無駄ビルドの抑止**: GitHub Actions（`.github/workflows/build.yml`）が定期的にベースイメージおよび各コンポーネントの最新状態をチェックし、ハッシュ値に差分が生じた場合のみマルチアーキテクチャ（amd64 / arm64）イメージの再ビルドを行います。
- **API レート制限回避**: バージョン取得処理は HTTP リダイレクトヘッダーやインデックスページを利用し、未認証トークン制限によるビルド失敗を防ぎます。

### 2. 実行アーキテクチャ & 常駐プロセス
コンテナ起動時、カスタムエントリポイント（`/usr/local/bin/custom-entrypoint.sh`）によって各サービスの自動設定およびデーモンが起動し、ベースイメージ本来の機能（Jupyter/Code Interpreter）も並行して維持されます。

| サービス / ツール | ポート | 種別 / 用途 |
|---|---|---|
| **OpenCode** | `4096` | バックグラウンド常駐（`opencode serve --port 4096 --hostname 0.0.0.0`） |
| **Semgrep** | `8000` | Streamable HTTP MCP サーバーとしてバックグラウンド常駐（`semgrep mcp --transport streamable-http --port 8000`） |
| **Jupyter Server** | `44771` | ベースイメージの Code Interpreter デーモン（`/opt/code-interpreter/code-interpreter.sh`） |
| **codebase-memory-mcp** | - | OpenCode の `local` (stdio) MCP ツールとして事前設定済み |
| **OpenCodeReview** | - | オンデマンド CLI（`ocr` / `open-code-review` コマンドで実行） |
| **Browser Use** | - | Playwright / Chromium 同梱（Xvfb / ヘッドレス実行対応、`PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` 設定済み） |

### 3. OpenCode の初期設定 (MCP 構成)
コンテナ内の `/root/.config/opencode/opencode.json` にて、常駐する Semgrep MCP サーバーおよび codebase-memory-mcp があらかじめ登録されています。起動時に環境変数が指定された場合、LLM プロバイダ設定が同ファイルへ動的にマージされます。

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
コンテナ起動時に以下の環境変数を渡すことで、OpenCode、OpenCodeReview、Browser Use の接続先が自動構成されます。

| 環境変数 | 説明 | デフォルト値 |
|---|---|---|
| `LLM_BASE_URL` | LLM サーバーの Base URL（全ツール共通フォールバック） | なし |
| `LLM_MODEL` | 使用するモデル名（全ツール共通フォールバック） | `default-model` |
| `OPENCODE_BASE_URL` | OpenCode 専用の Base URL 上書き | `${LLM_BASE_URL}` |
| `OPENCODE_MODEL` | OpenCode 専用のモデル名上書き | `${LLM_MODEL}` |
| `OPENCODE_PROVIDER` | OpenCode のプロバイダ識別子 | `selfhosted` |
| `OCR_BASE_URL` | OpenCodeReview 専用の Base URL 上書き | `${LLM_BASE_URL}` |
| `OCR_MODEL` | OpenCodeReview 専用のモデル名上書き | `${LLM_MODEL}` |
| `OCR_PROVIDER` | OpenCodeReview のプロバイダ識別子 | `custom-selfhosted` |
| `BROWSER_USE_BASE_URL` | Browser Use 向け Base URL（`OPENAI_API_BASE` に設定） | `${LLM_BASE_URL}` |
| `BROWSER_USE_MODEL` | Browser Use 向けモデル名 | `${LLM_MODEL}` |
| `BROWSER_USE_API_KEY` | Browser Use 向け API キー | `vault-managed-key`（未指定時） |

### セキュリティ: OpenSandbox Credential Vault との連携
エージェントによるプロンプトインジェクションやシェル操作を通じた実 API キーの漏洩を防ぐため、**コンテナ内部の設定ファイルや環境変数には実際のトークンを永続化せず、ダミートークン（`vault-managed-key`）を自動設定します。**

実際の認証キーは OpenSandbox の [Credential Vault](https://open-sandbox.ai/guides/credential-vault)（Egress Sidecar）で透過的に差し替えて運用することを推奨します。

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
