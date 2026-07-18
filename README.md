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
| VPN | WireGuard（Curve25519 / ChaCha20 + 事前共有鍵）|
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
# 1. 設定ファイルを用意
cd terraform
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars      # 認証情報と SSH 公開鍵を記入（最小 4 項目）

# 2. デプロイ（プロジェクトルートに戻って make を使うと簡単）
cd ..
make init
make deploy                  # terraform apply

# 3. 初期設定の完了を待つ（初回 3〜5 分）
make status

# 4. クライアントの QR コードを表示してスマホでスキャン
make show NAME=client1

# 5. クライアントを追加したいとき
make client NAME=my-laptop
```

`make` を使わない場合は各コマンドが `terraform apply` 後の出力（`next_steps`）に
表示されます。

📱 iPhone・Android・PC からの接続手順やクライアント管理の詳細は
[`docs/USAGE.md`](docs/USAGE.md) を参照してください。

---

## よく使う操作（Makefile）

| コマンド | 内容 |
|----------|------|
| `make deploy` | VPS を作成/更新 |
| `make status` | 初期設定の完了を待つ |
| `make client NAME=x` | クライアント x を追加（QR 表示）|
| `make clients` | クライアント一覧 |
| `make show NAME=x` | 設定と QR を再表示 |
| `make remove NAME=x` | クライアント x を削除 |
| `make ssh` | サーバーへ SSH |
| `make destroy` | VPN を完全撤去 |

---

## 設定のカスタマイズ

すべて `terraform/terraform.tfvars` で変更できます（詳細は
[`docs/SETUP.md`](docs/SETUP.md)）。よく変える項目:

| 変数 | 既定値 | 説明 |
|------|--------|------|
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
│   └── templates/
│       └── cloud-init.yaml.tftpl
├── scripts/
│   ├── setup.sh                 # サーバー初期構成（cloud-init から実行）
│   └── wg-client                # クライアント管理ツール
└── docs/
    ├── SETUP.md                 # 詳細セットアップ
    ├── USAGE.md                 # 使い方（各デバイスからの接続・管理）
    └── SECURITY.md              # セキュリティ設計と追加対策
```

---

## ライセンス

MIT
