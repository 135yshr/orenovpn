# orenovpn — ConoHa に自分専用の WireGuard VPN を建てるテンプレート

ConoHa VPS Ver.3.0（OpenStack 準拠 API）上に、**WireGuard** ベースのセキュアな
個人 VPN をコマンド一発で構築する Terraform テンプレートです。

`terraform apply` を実行するだけで、VPS の作成からファイアウォール・
SSH 堅牢化・WireGuard 起動・初期クライアント作成までを自動で行います。

> ベースは [ConoHa で WireGuard VPN を建てる記事](https://qiita.com/yamagami2211/items/4ccb7ccd5bfd80400389)
> の構成。そこに Infrastructure as Code 化とセキュリティ強化を上乗せしています。

---

## 特長

- 🚀 **フルオートメーション** — `terraform apply` で VPS 作成〜VPN 起動まで完結
- 🔧 **設定は 1 ファイル** — `terraform.tfvars` を編集するだけ。最小 4 項目で動く
- 🔒 **セキュア既定値** — SSH 鍵認証のみ・root/パスワードログイン無効・最小ファイアウォール・fail2ban・自動更新
- 📱 **クライアント管理が簡単** — `wg-client add <名前>` で鍵発行と QR コード表示
- 🧩 **テンプレート化** — 誰でも fork して自分の環境にすぐ展開可能

---

## アーキテクチャ

```
  あなたの端末                 ConoHa VPS (Debian 13)
 ┌───────────┐   WireGuard    ┌──────────────────────────┐
 │ WireGuard │◄══ UDP :51820 ═►│ wg0  10.66.66.1           │
 │  Client   │   (暗号化)      │  ├ ufw (最小許可)          │
 └───────────┘                 │  ├ fail2ban / 自動更新     │──► インターネット
                               │  └ NAT (MASQUERADE)       │    （全通信を VPN 経由）
                               └──────────────────────────┘
        ▲ Terraform + cloud-init が上記をすべて自動構築
```

| レイヤ | 使用技術 |
|--------|----------|
| プロビジョニング | Terraform（OpenStack Provider）|
| サーバー初期構成 | cloud-init + シェルスクリプト |
| VPN | WireGuard（既定）または IKEv2/IPsec（iPhone/macOS 標準VPN・アプリ不要）を `vpn_protocol` で選択 |
| OS | Debian 13（cloud-init 対応イメージ）|

---

## 必要なもの

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.5
- ConoHa アカウントと **VPS Ver.3.0** の利用開始
- ConoHa の **API ユーザー**（コントロールパネル → API メニューで作成）
- SSH 鍵ペア（`ssh-keygen -t ed25519`）

---

## クイックスタート

```bash
# 1. 設定ファイルを用意（プリセットから作るのが簡単・推奨）
make preset PRESET=balanced   # simple | balanced | hardened から選ぶ
$EDITOR terraform/terraform.tfvars   # 認証情報と SSH 公開鍵を記入（最小 4 項目）

# 2. デプロイ（フェーズ1: VPS 作成・最小構成で高速起動）
make init
make deploy                  # terraform apply

# 3. SSH 疎通を確認（初回ブート 1〜2 分）
make status

# 4. ソフト導入・VPN 構成（フェーズ2: 進捗を画面で確認できる）
make setup

# 5. クライアントの QR コードを表示してスマホでスキャン
make show NAME=phone

# 6. クライアントを追加したいとき
make client NAME=my-laptop
```

> **2 フェーズ構成**: まず最小構成で起動して SSH 疎通を確認（フェーズ1）、その後に
> WireGuard 等の導入・構成を SSH 経由で実行（フェーズ2 = `make setup`）。
> 初回ブートが速く確実で、構成の失敗も画面で確認・再実行できます。

`make` を使わない場合は各コマンドが `terraform apply` 後の出力（`next_steps`）に
表示されます。

📱 iPhone・Android・PC からの接続手順やクライアント管理の詳細は
[`docs/USAGE.md`](docs/USAGE.md) を参照してください。

---

## よく使う操作（Makefile）

| コマンド | 内容 |
|----------|------|
| `make preset PRESET=x` | 設定プリセットを適用（simple/balanced/hardened）|
| `make deploy` | VPS を作成/更新（フェーズ1）|
| `make status` | SSH 疎通を待つ |
| `make setup` | ソフト導入・VPN 構成（フェーズ2）|
| `make client NAME=x` | クライアント x を追加（QR 表示）|
| `make clients` | クライアント一覧 |
| `make show NAME=x` | 設定と QR を再表示 |
| `make remove NAME=x` | クライアント x を削除 |
| `make ssh` | サーバーへ SSH |
| `make images` | 利用可能な OS イメージ名を確認 |
| `make destroy` | VPN を完全撤去 |

---

## 設定のカスタマイズ

まず用途に合った**プリセット**（`make preset PRESET=simple|balanced|hardened`）で
土台を作り、必要なら `terraform/terraform.tfvars` を個別に調整します
（プリセットの比較は [`terraform/presets/README.md`](terraform/presets/README.md)、
全変数の詳細は [`docs/SETUP.md`](docs/SETUP.md)）。よく変える項目:

| 変数 | 既定値 | 説明 |
|------|--------|------|
| `vpn_protocol` | `wireguard` | `wireguard`（専用アプリ）/ `ikev2`（iPhone/macOS標準VPN・アプリ不要）|
| `flavor_name` | `g2l-t-c1m512` | プラン（最安 512MB）|
| `ssh_port` | `22022` | SSH ポート |
| `allowed_ssh_cidr` | `["0.0.0.0/0"]` | SSH 許可元 IP（**固定 IP に絞ると安全**）|
| `wg_port` | `51820` | WireGuard ポート |
| `wg_dns` | `1.1.1.1,1.0.0.1` | クライアント DNS |
| `wg_clients` | `["client1"]` | 初期作成クライアント |

---

## セキュリティ

本テンプレートが施す防御と、さらなる堅牢化（kill switch・DNS 漏洩対策など）は
[`docs/SECURITY.md`](docs/SECURITY.md) にまとめています。

- ⚠️ `terraform.tfvars` と `*.tfstate` には**シークレットが含まれます**。
  `.gitignore` 済みですが、公開リポジトリへ push しないよう注意してください。

---

## ディレクトリ構成

```
orenovpn/
├── README.md
├── Makefile                     # よく使う操作のショートカット
├── terraform/
│   ├── versions.tf              # プロバイダのバージョン
│   ├── providers.tf             # ConoHa/OpenStack 接続
│   ├── variables.tf             # 変数定義
│   ├── main.tf                  # VPS・ボリューム・鍵
│   ├── security.tf              # セキュリティグループ
│   ├── outputs.tf               # 接続情報の出力
│   ├── terraform.tfvars.example # ★設定ファイルの雛形
│   ├── presets/                 # 用途別の設定プリセット（simple/balanced/hardened）
│   └── templates/
│       └── cloud-init.yaml.tftpl
├── scripts/
│   ├── setup.sh                 # サーバー初期構成（cloud-init から実行）
│   ├── wg-client                # クライアント管理ツール
│   └── list-images.sh           # 利用可能な OS イメージの確認
└── docs/
    ├── SETUP.md                 # 詳細セットアップ
    ├── USAGE.md                 # 使い方（各デバイスからの接続・管理）
    └── SECURITY.md              # セキュリティ設計と追加対策
```

---

## ライセンス

MIT
