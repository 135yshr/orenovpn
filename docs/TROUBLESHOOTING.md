# 構築ログ / トラブルシューティング記録

ConoHa VPS Ver.3.0 上に本テンプレートで VPN を実際に構築する過程で遭遇した問題と、
その原因・対処・結果を時系列で記録したもの。ConoHa 固有の落とし穴が多く、同じ轍を
踏まないための知見として残す。

> 凡例: **症状** → **原因** → **対処** → **結果**（該当コミット）

---

## 1. ボリュームタイプが存在しない

- **症状**: `terraform apply` で `specified volume type does not exist`（400）。
- **原因**: `volume_type` の既定値 `c3j1-ds02` が実在しなかった。ConoHa v3 のブート用
  ボリュームタイプは末尾が `-boot`（例 `c3j1-ds02-boot`）。
- **対処**: 既定を `c3j1-ds02-boot` に修正。確認用に `make volume-types`
  （`scripts/list-volume-types.sh`）を追加。
- **結果**: 解決。（`86a36cf`）

## 2. ブートボリュームのサイズがプランと不整合

- **症状**: サーバー作成時に `512MB plan can only attach 30GB boot volume`（400）。
- **原因**: `volume_size` 既定 100GB が 512MB プランと不整合。512MB プランは 30GB 固定。
- **対処**: 既定を 30 に変更。プランとサイズの対応をコメントに明記。
- **結果**: 解決。（`2a8c531`）

## 3. user_data が 16KiB 制限を超過

- **症状**: `User data size must be under 16KiB`。当初スクリプトを base64 埋め込みして
  いたため約 19KiB になっていた。
- **試行錯誤**:
  - gzip 圧縮（`base64gzip`）→ ConoHa が `User data header is invalid` を返し**gzip 不可**と判明。
  - プレーンテキスト埋め込み → プロバイダが送信時に base64 化するため実質 +33% となり
    なお超過（制限は**base64 後**のサイズに適用）。
  - スクリプトのコメント/空行を最小化 → 一旦 15KB 台に収めた。
- **最終対処**: **構築を 2 フェーズ化**（下記 4）してスクリプトを user_data から排除。
  user_data は約 1.9KiB に激減し問題自体を根絶。
- **結果**: 解決。（`a193a9e` → `33cc45a` → `4c8f604` → 最終的に `8719127` で解消）

## 4. 「起動したのに SSH で入れない」／デバッグ性の悪さ

- **症状**: 初回ブートで全部やる方式だと、失敗時に SSH すら入れず原因が見えない。
- **対処**: **2 フェーズ構成に再設計**。
  - フェーズ1（cloud-init・最小限）: ユーザー作成 + SSH 鍵 + SSH 堅牢化のみ。
  - フェーズ2（`make setup`）: スクリプトを SSH 転送し、パッケージ導入・VPN 構成を
    画面で見ながら実行（冪等・再実行可能）。
- **結果**: デバッグ性が大幅改善。user_data も最小化（上記 3 も同時に解消）。（`8719127`）

## 5. SSH ポート変更が反映されない（当初の誤診）

- **症状**: `ssh_port` を 22 以外にすると全く接続できない。
- **当初の推測**: Debian 13 の SSH ソケットアクティベーション（`ssh.socket`）で
  `sshd_config` の `Port` が無視される、と考え socket 無効化を実装（`378a355`）。
- **真因**: 実は下記 6（user_data 未適用）が原因で、sshd_config ドロップイン自体が
  書かれておらず 22 番のままだった。socket 説は的外れだった。
- **最終対処**: ポート変更機能は「利点が少なく事故要因」として**廃止し SSH は 22 番固定**に。
  防御は鍵認証＋fail2ban が担う。
- **結果**: 解決（機能削除）。（`47abee4`）

## 6. ★最重要: user_data が cloud-init に適用されない（config_drive 欠如）

- **症状**: SSH で root＋鍵では入れるが、`vpnops` ユーザーが作られず、SSH 堅牢化も
  未適用。`cloud-init status` は `done` なのに `#cloud-config` の中身が反映されない。
- **原因**: **ConoHa は metadata サービス経由の user_data を cloud-init に渡さない**。
  鍵は metadata 経由で root に注入されるが、user_data(#cloud-config) は
  **config-drive 経由でないと処理されない**。
- **対処**: インスタンスに **`config_drive = true`** を追加。あわせて cloud-init を
  ロックアウト耐性に（root 鍵ログインを残す・swap を setup.sh 側へ移動）。
- **結果**: **解決（最大の突破口）**。`make status` が `SSH 疎通OK` になり vpnops で
  ログイン可能に。これ以前の SSH 不通の多くはこれが真因だった。（`8616631`）

## 7. SSH 秘密鍵のパスが既定外

- **症状**: `make status` が `Permission denied (publickey)`。
- **原因**: 鍵が `~/.ssh/orenovpn`（既定 `~/.ssh/id_ed25519` ではない）。
- **対処**: `SSH_KEY=` で指定可能に。さらに `orenovpn.local.mk`（gitignore）や環境変数
  `ORENOVPN_SSH_KEY` で毎回指定を省略できるようにした。
- **結果**: 解決。（`5aa3e86`）

## 8. allowed_ssh_cidr がプレースホルダのまま

- **症状**: SSH ルールが `203.0.113.10/32`（ドキュメント例のIP）で作られ、実 IP から
  SSH 不可。
- **原因**: hardened 系設定の `allowed_ssh_cidr` プレースホルダを実 IP に置換していなかった。
- **対処**: 自分のグローバル IP（`curl -4 ifconfig.co`）または `0.0.0.0/0` に設定。
- **結果**: 解決（設定修正）。

## 9. iPhone への構成ファイル配布

- **背景**: IKEv2 の `.mobileconfig` はサーバー上に root 所有(0600)で生成され、iPhone
  から直接は取得できない。
- **対応**:
  - `make profile`: SSH(22) 経由で Mac にダウンロード（`sudo cat`）→ AirDrop/メール等で転送。（`5c9d7e2`）
  - `make serve-profile`: VPS から一時 HTTPS + QR 配信（iPhone の Safari で直接取得）。

## 10. serve-profile: 動的に追加した SG ルールが効かない

- **症状**: 一時ポートを API で SG に追加しても、Mac からも到達不可（timeout）。
  サーバー内では待受 OK・ufw OK・localhost 200。
- **原因**: **ConoHa は稼働中インスタンスに「後から追加した SG ルール」を反映しない**。
  SG オブジェクトには存在するが、実インスタンスのフィルタに適用されない。
- **対処**: 配信ポートを **Terraform で作成時から SG に宣言**する方式へ変更
  （`enable_profile_download` / `profile_port`）。serve-profile は SG を触らず
  ufw 開閉＋配信のみ（ufw は即反映される）。（`0e119f6`）
- **結果**: 部分的。下記 11・12 へ続く。

## 11. serve-profile の権限バグ

- **症状**: クライアントが「見つからない」／`serve.py` を書けない。
- **原因**: クライアントファイルは `/etc/orenovpn/clients`(0700/root) にあり、vpnops の
  `[ -f ]` では検出不可。配信 dir を `sudo mkdir` すると vpnops が書き込めない。
- **対処**: `sudo test -f` に変更、配信 dir は非 sudo で作成。（`5f77711`）
- **結果**: 解決。

## 12. 作成時に宣言した 443 すら外部から到達不可（調査中）

- **症状**: 443 を作成時から SG に宣言し、depends_on で全ルールをインスタンス前に
  作成しても、443 だけ外部から timeout（22/500/4500 は到達可）。
  サーバー内は待受 OK・ufw ALLOW・localhost 200。SG オブジェクトにも 443 は存在。
- **切り分けで判明**:
  - サーバー/ufw/証明書は正常（localhost=200）。遮断は ConoHa ネットワーク層。
  - `depends_on`（ルールをインスタンス前に作成）でも改善せず → 作成時タイミングの
    問題ではない。
  - ConoHa には `IPv4v6-Web`(80/443) 等の**定義済み SG** が存在。
- **現在の仮説**: **ConoHa は 80/443（Web 標準ポート）を特別扱いし、カスタム SG ルール
  では開かない**（22 はカスタムルールで開くのに 443 は開かない、と整合）。
- **対処（検証1）**: 配信ポートを **8443**（カスタム高位ポート）に変更。（`ac7e717`）
- **検証1の結果**: **8443 も外部到達不可**（待受・ufw・localhost は正常）。
  → 443 特有ではなく、**ConoHa は 22 以外のカスタム SG TCP ルールを実質適用していない**
  可能性が濃厚。22/500/4500 のみ通り、それ以外の TCP は塞がれる。
- **対処（検証2）**: ConoHa の**定義済み SG `IPv4v6-Web`（80/443 を開く）**をインスタンスに
  アタッチし、配信ポートを 443 に戻す方式へ。定義済み SG なら ConoHa が確実に適用する想定。
- **結果**: 検証中。

---

## ConoHa 固有の落とし穴（まとめ）

1. **ブートボリューム**: タイプは `-boot` 付き、サイズはプラン固定（512MB→30GB）。
2. **user_data は config-drive が必須**（`config_drive = true`）。metadata 経由では
   cloud-init に適用されない。← 最重要。
3. **user_data 16KiB 制限は base64 後のサイズ**に適用。gzip user-data は不可。
4. **SG ルールは稼働中インスタンスに後から反映されない**。必要なポートは
   インスタンス作成時までに SG へ宣言しておくこと。
5. **80/443 は特別扱いの疑い**（カスタム SG ルールで開かない／要 `IPv4v6-Web`）。
6. SSH のポート変更は避け 22 番固定が無難（socket activation 等の事故要因）。

## 検証手段として整備したもの

- `make images` / `make volume-types`: 利用可能な OS イメージ・ボリュームタイプの確認。
- 2 フェーズ構成 + `make setup` の画面出力: 構成失敗をその場で観察・再実行。
- `serve-profile` の `[diag]` 出力 + Mac からの到達性自己テスト: 障害が
  サーバー/ufw/SG のどの層かを切り分け。
