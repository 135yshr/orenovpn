# セットアップ詳細ガイド

このドキュメントは `README.md` のクイックスタートを補完する、手順の詳細版です。

## 1. 事前準備

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
openstack image list        # image_name（例: vmi-debian-12.0-amd64）
openstack flavor list        # flavor_name（例: g2l-t-c1m512）
openstack volume type list   # volume_type
```

確認した値を `terraform.tfvars` に設定してください。

## 3. デプロイ

```bash
make init      # terraform init（プロバイダ取得。最初の一度）
make plan      # 作成される内容を確認（任意）
make deploy    # terraform apply → yes
```

apply 完了後、接続情報（`next_steps`）が表示されます。

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
