# orenovpn — ConoHa に自分専用の VPN を建てるテンプレート（WireGuard / IKEv2）

ConoHa VPS Ver.3.0（OpenStack 準拠 API）上に、セキュアな個人 VPN を数コマンドで
構築する Terraform テンプレートです。**WireGuard**（専用アプリ）と **IKEv2/IPsec**
（iPhone / macOS の標準 VPN・アプリ不要）の 2 方式に対応します。

Terraform で VPS を作成（フェーズ1）し、`make setup` でファイアウォール・SSH 堅牢化・
VPN 構成・初期クライアント作成までを自動化します（フェーズ2）。iPhone へは QR コードで
構成プロファイルを配布できます。

> ベースは [ConoHa で WireGuard VPN を建てる記事](https://qiita.com/yamagami2211/items/4ccb7ccd5bfd80400389)
> の構成。そこに IaC 化・IKEv2 対応・QR 配布・セキュリティ強化を上乗せしています。

---

## 特長

- 🚀 **ほぼ自動** — `make deploy`（VPS 作成）→ `make setup`（VPN 構成）の 2 ステップで完結
- 📱 **2 方式を選択** — WireGuard（専用アプリ）／ IKEv2/IPsec（iPhone/macOS 標準VPN・アプリ不要）
- 🔳 **QR で配布** — `make serve-profile` で iPhone に構成を QR 配布（Let's Encrypt の信頼された証明書）
- 🔧 **設定は 1 ファイル** — `terraform.tfvars` を編集するだけ。最小 4 項目で動く
- 🔒 **セキュア既定値** — SSH 鍵認証のみ・root/パスワード無効・最小ファイアウォール・fail2ban・自動更新
- 🩺 **自己診断＋CI** — `make doctor` で実機点検、`make check`／GitHub Actions で変更を自動検証
- 🧩 **クライアント管理が簡単** — `make client NAME=<名前>` で鍵/証明書発行と QR/プロファイル配布
- 📦 **テンプレート化** — 誰でも fork して自分の環境にすぐ展開可能

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
        ▲ Terraform でVPS作成（フェーズ1）→ make setup で上記を構成（フェーズ2）
```

> `vpn_protocol = "ikev2"` の場合は WireGuard の代わりに IKEv2/IPsec（UDP 500/4500、
> strongSwan）を構成し、iPhone/macOS の標準 VPN から証明書認証で接続します。

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
make preset PRESET=balanced   # simple | balanced | hardened | ikev2 から選ぶ
$EDITOR terraform/terraform.tfvars   # 認証情報と SSH 公開鍵を記入（最小 4 項目）

# 2. デプロイ（フェーズ1: VPS 作成・最小構成で高速起動）
make init
make deploy                  # terraform apply

# 3. SSH 疎通を確認（初回ブート 1〜2 分）
make status

# 4. ソフト導入・VPN 構成（フェーズ2: 進捗を画面で確認できる）
make setup

# 5. サーバー構成を自己診断（任意・不通時の切り分け）
make doctor

# 6. クライアントを追加（初期クライアントは setup 時に作成済み）
make client NAME=my-phone

# 7. クライアント設定を配布
make show NAME=my-phone            # WireGuard=QR / IKEv2=導入案内 を表示
make serve-profile NAME=my-phone   # iPhone: Safari で QR をスキャンして構成を取得（IKEv2向け）
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
| `make preset PRESET=x` | 設定プリセットを適用（simple/balanced/hardened/ikev2）|
| `make check` | デプロイ前のローカル検証（fmt/validate/構文/shellcheck）|
| `make deploy` | VPS を作成/更新（フェーズ1）|
| `make status` | SSH 疎通を待つ |
| `make setup` | ソフト導入・VPN 構成（フェーズ2）|
| `make doctor` | サーバー構成を自己診断（不通/通信不可の切り分け）|
| `make client NAME=x` | クライアント x を追加（QR/プロファイル）|
| `make clients` | クライアント一覧 |
| `make show NAME=x` | 設定と QR/導入案内を再表示 |
| `make serve-profile NAME=x` | iPhone へ QR で構成プロファイルを配布 |
| `make profile NAME=x` | 構成/設定ファイルを手元にダウンロード |
| `make remove NAME=x` | クライアント x を削除 |
| `make ssh` | サーバーへ SSH |
| `make images` / `make volume-types` | 利用可能な OS イメージ / ボリュームタイプを確認 |
| `make destroy` | VPN を完全撤去 |

---

## 設定のカスタマイズ

まず用途に合った**プリセット**（`make preset PRESET=simple|balanced|hardened|ikev2`）で
土台を作り、必要なら `terraform/terraform.tfvars` を個別に調整します
（プリセットの比較は [`terraform/presets/README.md`](terraform/presets/README.md)、
全変数の詳細は [`docs/SETUP.md`](docs/SETUP.md)）。よく変える項目:

| 変数 | 既定値 | 説明 |
|------|--------|------|
| `vpn_protocol` | `wireguard` | `wireguard`（専用アプリ）/ `ikev2`（iPhone/macOS標準VPN・アプリ不要）|
| `image_name` | `vmi-debian-13.5-amd64` | OS イメージ（`make images` で確認）|
| `flavor_name` | `g2l-t-c1m512` | プラン（最安 512MB）|
| `allowed_ssh_cidr` | `["0.0.0.0/0"]` | SSH 許可元 IP（**固定 IP に絞ると安全**）|
| `wg_port` | `51820` | WireGuard ポート |
| `wg_dns` | `1.1.1.1,1.0.0.1` | クライアント DNS |
| `wg_clients` | `["client1"]` | 初期作成クライアント |
| `randomize_profile_port` | `false` | QR 配布ポートを apply 時にランダム化 |
| `enable_cert_revocation` | `false` | IKEv2 証明書の失効(CRL)を有効化（`make remove` で失効可能）|

> SSH ポートは事故防止のため **22 番固定**です（`ssh_port` 変数は廃止済み）。

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
├── .github/workflows/ci.yml     # CI（fmt/validate/構文/shellcheck を自動検証）
├── terraform/
│   ├── versions.tf              # プロバイダのバージョン
│   ├── providers.tf             # ConoHa/OpenStack 接続
│   ├── variables.tf             # 変数定義
│   ├── main.tf                  # VPS・ボリューム・鍵
│   ├── security.tf              # セキュリティグループ（配信ポート含む）
│   ├── outputs.tf               # 接続情報の出力
│   ├── terraform.tfvars.example # ★設定ファイルの雛形
│   ├── presets/                 # 用途別プリセット（simple/balanced/hardened/ikev2）
│   └── templates/
│       └── cloud-init.yaml.tftpl
├── scripts/
│   ├── setup.sh                 # サーバー構成（フェーズ2・make setup が実行）
│   ├── wg-client                # WireGuard クライアント管理
│   ├── ikev2-client             # IKEv2 クライアント管理（.mobileconfig 生成）
│   ├── vpn-client               # プロトコル振り分け（wg/ikev2）
│   ├── serve-profile.sh         # QR で構成プロファイルを一時配信
│   ├── doctor.sh                # サーバー構成の自己診断
│   ├── list-images.sh           # 利用可能な OS イメージの確認
│   └── list-volume-types.sh     # 利用可能なボリュームタイプの確認
└── docs/
    ├── SETUP.md                 # 詳細セットアップ
    ├── USAGE.md                 # 使い方（各デバイスからの接続・管理）
    ├── SECURITY.md              # セキュリティ設計と追加対策
    ├── TROUBLESHOOTING.md       # 構築ログ / ConoHa 固有の落とし穴
    └── RETROSPECTIVE.md         # 開発の振り返り（意思決定・KPT）
```

---

## ライセンス

MIT
