# セットアップ詳細ガイド

このドキュメントは `README.md` のクイックスタートを補完する、手順の詳細版です。
**このプロジェクトを初めて触る人が、上から順に実行すれば構築できる**ように書いています。

## 0. 全体の流れ（手作業と make の役割分担）

構築は「**最初に一度だけ手作業**」→「**あとは `make` コマンドで運用**」という流れです。
どこが手作業で、どこが自動かを最初に把握してください。

```
┌─ 手作業（最初の一度だけ）───────────────────────────┐
│ ① 必要ツールをインストール（Terraform / WireGuard アプリ）│
│ ② ConoHa で VPS Ver.3.0 を有効化 + API ユーザー作成      │
│ ③ SSH 鍵ペアを作成                                       │
│ ④ terraform.tfvars を作成し、認証情報と SSH 公開鍵を記入  │ ← ここが実質のスタート
└──────────────────────────────────────────────────────┘
                     ↓
┌─ make で運用（以降くり返し）──────────────────────────┐
│ make init    → make deploy → make status               │
│ → make show NAME=xxx（QR 表示）→ スマホでスキャン        │
│ 追加/削除:  make client / make remove                   │
└──────────────────────────────────────────────────────┘
```

| ステップ | 手段 | 補足 |
|----------|------|------|
| ツール導入 | 手作業 | make では入りません |
| ConoHa 準備 | 手作業 | コントロールパネル操作 |
| SSH 鍵作成 | 手作業 | `ssh-keygen` |
| `terraform.tfvars` 編集 | 手作業 | **秘密情報のため make 化していません** |
| 初期化・構築・運用 | `make` | `init` / `deploy` / `status` / `client` など |

> ⚠️ **順番が重要**: `make status` / `make show` / `make client` などは
> **`make deploy` が完了してから**でないと動きません（Terraform の出力を参照するため）。
> 必ず `make deploy` → `make status` の順に実行してください。

## 1. 事前準備

### 1-0. 必要なツールをインストール

作業する手元の PC に以下を入れます（サーバー側は cloud-init が自動導入するので不要）。

| ツール | 用途 | 導入例 |
|--------|------|--------|
| [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.5 | インフラ構築 | macOS: `brew install terraform` |
| Git | リポジトリ取得 | 通常プリインストール |
| `make` | 操作の簡略化 | macOS/Linux は標準。Windows は WSL 推奨 |
| WireGuard アプリ | 接続する端末側 | [公式](https://www.wireguard.com/install/) / App Store / Google Play |

### 1-1. ConoHa VPS Ver.3.0 を有効化

ConoHa コントロールパネルの右上のバージョン切替から **Ver.3.0** を選択します。
（Ver.2.0 とは API エンドポイントが異なるため、必ず 3.0 を使用）

### 1-2. API ユーザーを作成

コントロールパネル → **API** メニューから API ユーザーを作成し、以下を控えます。

| 項目 | 例 | tfvars の変数 |
|------|-----|--------------|
| テナント名 | `gnct12345678` | `conoha_tenant_name` |
| ユーザー名 | `gncu12345678` | `conoha_user_name` |
| パスワード | （作成時に設定）| `conoha_password` |

エンドポイント（`https://identity.c3j1.conoha.io/v3`）とドメイン名（`gnc`）は
既定値のままで構いません。

### 1-3. SSH 鍵ペアを作成

```bash
ssh-keygen -t ed25519 -C "orenovpn" -f ~/.ssh/orenovpn
cat ~/.ssh/orenovpn.pub    # この内容を ssh_public_key に貼る
```

> 📌 **鍵の置き場所に関する重要な注意**
> 上の例のように**既定以外のパス**（`~/.ssh/orenovpn`）へ鍵を作った場合、
> `make ssh` / `make client` などが自動でこの鍵を見つけられません。次のいずれかで対応します。
>
> - **その都度 `SSH_KEY` を渡す**（最も簡単）:
>   ```bash
>   make ssh    SSH_KEY=~/.ssh/orenovpn
>   make client NAME=iphone SSH_KEY=~/.ssh/orenovpn
>   ```
> - **`~/.ssh/config` に書いておく**（一度書けば以降は指定不要・推奨）:
>   ```
>   Host orenovpn-server
>       HostName <サーバーIP>
>       Port 22022
>       User vpnadmin
>       IdentityFile ~/.ssh/orenovpn
>   ```
> - **`ssh-add ~/.ssh/orenovpn`** で ssh-agent に登録しておく。
>
> 既定パス（`~/.ssh/id_ed25519`）に鍵を作った場合は、これらの対応は不要です。

## 2. 設定ファイルの編集

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

最低限、以下の 4 項目を埋めれば動きます。

```hcl
conoha_tenant_name = "gnct12345678"
conoha_user_name   = "gncu12345678"
conoha_password    = "********"
ssh_public_key     = "ssh-ed25519 AAAAC3Nza... orenovpn"
```

### イメージ名・ボリュームタイプの確認（うまく動かない場合）

イメージ名やボリュームタイプは地域・時期で変わることがあります。
[OpenStack CLI](https://doc.conoha.jp/reference/openstack-cli/) で正確な値を確認できます。

```bash
openstack image list        # image_name（例: vmi-debian-13.0-amd64）
openstack flavor list        # flavor_name（例: g2l-t-c1m512）
openstack volume type list   # volume_type
```

確認した値を `terraform.tfvars` に設定してください。

## 3. デプロイ

```bash
make init      # terraform init（プロバイダ取得。最初の一度・要ネット接続）
make plan      # 作成される内容を確認（任意）
make deploy    # terraform apply（確認プロンプトで yes を入力）
```

> `make deploy` は完全無人ではありません。`terraform apply` の確認で
> `yes` の入力を求められます。確認を省きたい場合は
> `make deploy` の代わりに `terraform -chdir=terraform apply -auto-approve` を使えます。

apply 完了後、接続情報（`next_steps`）が表示されます。以降の `make status` /
`make show` などはこの出力を参照するため、**必ず apply 完了後**に実行してください。

## 4. 初期設定の完了を待つ

VPS 作成後、cloud-init が裏でパッケージ導入と WireGuard 構成を行います
（初回 3〜5 分）。

```bash
make status    # 'cloud-init status --wait' を実行
```

`status: done` になれば完了です。ログは以下で確認できます。

```bash
make ssh
sudo cat /var/log/orenovpn-setup.log
```

## 5. クライアントの接続

### スマートフォン（QR コード）

```bash
make show NAME=client1
```

表示された QR コードを、スマホの [WireGuard アプリ](https://www.wireguard.com/install/)の
「＋」→「QR コードから作成」でスキャンし、トグルを ON にすれば接続完了です。

### PC（設定ファイル）

```bash
# サーバーから設定ファイルを取得
scp -P 22022 vpnadmin@<サーバーIP>:/etc/orenovpn/clients/client1.conf ./
# WireGuard アプリに client1.conf をインポート
```

### クライアントの追加・削除

```bash
make client NAME=my-laptop    # 追加
make clients                  # 一覧
make remove NAME=my-laptop    # 削除
```

## 6. トラブルシューティング

| 症状 | 対処 |
|------|------|
| `make ssh` で `Permission denied (publickey)` | 鍵を既定外パスに作った可能性。`make ssh SSH_KEY=~/.ssh/orenovpn` で鍵を指定（[1-3 の注意](#1-3-ssh-鍵ペアを作成)参照）|
| `make status` 等が `@:` や空ホストで失敗 | まだ `make deploy` が完了していない。先に `make deploy` を実行 |
| SSH で繋がらない | SG は `ssh_port`（既定 22022）のみ許可。`ssh -p 22022 vpnadmin@IP`。緊急時は ConoHa の Web コンソールで復旧 |
| `image not found` | `openstack image list` で正しい `image_name` を確認 |
| VPN 接続できるが通信できない | `make ssh` → `sudo wg show` でハンドシェイクを確認。`sudo cat /var/log/orenovpn-setup.log` でエラー確認 |
| クライアント追加が反映されない | `sudo systemctl status wg-quick@wg0` を確認 |

## 7. 撤去

```bash
make destroy    # VPS・ボリューム・SG をすべて削除
```

> `delete_on_termination = false` のため、ボリュームは明示的に destroy する
> 構成です。課金停止のため destroy 後に ConoHa 上で残存リソースがないか確認してください。
