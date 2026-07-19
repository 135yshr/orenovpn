# 開発の振り返り（Retrospective）

ConoHa VPS 上に個人用 VPN を構築するテンプレート「orenovpn」を、企画から実機接続確認・
PR マージまで進めた過程の振り返り。技術的な問題と対処の**詳細な時系列**は
[TROUBLESHOOTING.md](./TROUBLESHOOTING.md) にあり、本書はそれを踏まえた**より上位の
意思決定・学び・KPT**をまとめる。

---

## 1. 目的とゴール

- ConoHa VPS Ver.3.0（OpenStack 準拠 API）上に、**個人用のセキュアな VPN** を
  `make` 数コマンドで構築できるテンプレートを作る。
- **他の人がそのまま展開できる**こと（設定は `terraform.tfvars` 1 ファイルに集約）。
- 参考記事の WireGuard 最小構成を土台に、**Infrastructure as Code 化とセキュリティ強化**を
  上乗せする。
- 途中で要件が育ち、最終的に次を満たした：
  - **WireGuard** と **IKEv2/IPsec** の 2 方式に対応
  - IKEv2 は **iPhone / macOS の標準 VPN（専用アプリ不要）** から接続
  - **QR コード**で構成プロファイルを配布
  - **実機（iPhone・macOS）で接続確立まで検証**

## 2. 最終的な成果物

- **Terraform (OpenStack Provider)** … VPS / ブートボリューム / SSH 鍵 / セキュリティグループ
- **2 フェーズ構成** … フェーズ1: cloud-init で最小初期化 ／ フェーズ2: `make setup` で
  スクリプト転送・VPN 構成（観察・再実行可能）
- **`scripts/`** … `setup.sh`（サーバー構成）、`wg-client` / `ikev2-client` / `vpn-client`
  （クライアント管理）、`serve-profile.sh`（QR 配布）、`list-images.sh` / `list-volume-types.sh`
- **プリセット 4 種** … simple / balanced / hardened / ikev2-apple
- **ドキュメント** … SETUP / USAGE / SECURITY / TROUBLESHOOTING（＋本書）

## 3. 開発の経緯（フェーズ別）

1. **テンプレート初版** … WireGuard・Terraform・cloud-init・プリセット・docs を整備。
2. **ConoHa 固有の制約との格闘** … ボリュームタイプ/サイズ、user_data 16KiB 制限、そして
   **`config_drive = true` が cloud-init 適用の鍵**という突破口（最重要発見）。
3. **設計の見直し** … SSH ポート変更機能を廃止（事故要因）。プリセットを
   「terraform.tfvars.example と同じ ①〜⑥ 構造で、その段の適切値が埋まった状態」に統一。
   OS バージョン選択（`image_name`）＋ `make images` / `make volume-types` を追加。
4. **IKEv2 対応の追加** … iPhone/Mac の標準 VPN で使えるよう、証明書認証＋`.mobileconfig`
   生成を実装。4 つ目のプリセット（ikev2-apple）も追加。
5. **QR 配布** … `serve-profile` で VPS から一時 HTTPS 配信し iPhone の Safari で取得。
6. **接続を阻む問題の連鎖を解消**（下記 4 で詳述）。
7. **信頼された証明書化・配信ポートのランダム化・経路健全性の強化**。
8. **CodeRabbit autofix**（2 ラウンド）で指摘を反映。
9. **実機接続確認**（iPhone → macOS）→ PR マージ。

## 4. 直面した主要な問題と学び（要約）

> 詳細な症状・原因・対処は [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) を参照。

| 問題 | 根本原因 | 学び |
|---|---|---|
| user_data が反映されない | ConoHa は metadata 経由の user_data を適用しないことがある | **`config_drive = true` が必須** |
| user_data 16KiB 超過 | 制限は base64 後のサイズ。gzip 不可 | スクリプトは user_data に埋めず**2 フェーズ化** |
| 22 以外の全ポート不通（長期の誤診） | Debian 13 既定の **nftables `table inet filter`** が遮断。ufw だけ見て見落とし | **同種機能の二重起動を最初に点検**（`nft list ruleset`）。「実プロセスを見たか？」が転機 |
| 「カスタム TCP SG は効かない」という誤仮説 | 上記 nftables が真因だった | 仮説は**反証まで確認**する。UDP(IKEv2)が通っていた事実が反証の糸口だった |
| IKEv2 が ON→即 OFF（AUTH_FAILED） | クライアント証明書 SAN が rfc822 のみ。iOS は ID_FQDN を送るため型不一致 | 証明書チェーンが正しくても**識別子(ID)の型**で落ちる。SAN に dNSName を追加 |
| VPN は張れるが通信不可（戻り 0） | NAT を `before.rules` に入れた後で `ufw --force reset` が消していた | **適用順序**（reset 後に NAT）。戻り 0 は NAT 未適用をまず疑う |
| IPv6 リーク対策が無効 | swanctl の pool.addrs に v4/v6 混在指定で v6 が読まれず | プールは**v4/v6 を分離**する |

**一番の教訓**: 症状（外部から不通）を SG やアプリ設定のせいにして長く回り道したが、
真因はサーバー内で別に動いていた nftables だった。「**実際に動いているプロセス／ルールを
自分の目で確認する**」ことを最初のステップに置くべきだった。

## 5. 設計上の主要な意思決定

- **2 フェーズ構成の採用** … user_data 制限の回避だけでなく、`make setup` の画面出力で
  構成失敗をその場で観察・再実行できる**デバッグ性**を得た。結果的に上記の問題解決を
  大きく助けた。
- **SSH ポート固定（22）** … ポート変更は socket activation 等の事故要因で、利点が薄い
  ため機能ごと排除。
- **ファイアウォールを ufw に一本化** … nftables との二重稼働を止め、原因調査の
  複雑さを減らした。
- **QR 配布の証明書を Let's Encrypt 化** … `<IP>.sslip.io` ＋ HTTP-01 で信頼証明書を取得し
  ブラウザ警告を解消。取得結果はキャッシュしてレート制限を回避、失敗時は自己署名へ
  フォールバック。独自ドメインも `PROFILE_DOMAIN` で選択可能。
- **配信ポートのデプロイ単位ランダム化** … 「毎回ランダム」は ConoHa の SG 仕様上不可
  （作成時にしか反映されない）と判断し、`random_integer` で apply 時に固定する方式に。
- **IKEv2 の経路健全性を明示的に強化** … PFS・鍵ローテーション・IPv6 リーク封じ込め。

## 6. KPT（うまくいった / 課題 / 次にやる）

**Keep（うまくいった）**
- 2 フェーズ構成による観察可能性が、難所の切り分けを支えた。
- 問題ごとに「症状→原因→対処→結果（コミット）」で記録を残したこと。
- 最終的に実機（iPhone・macOS）で確立まで確認し、再現性を担保できたこと。

**Problem（課題だった）**
- nftables を見落として長期間 SG/ネットワーク層を疑い続けた（サーバー内の実状態確認が遅れた）。
- 証明書関連の修正（拡張→SAN 型）が**クリーン再構築で検証されるまで**「直った」と誤認していた。
- 誤った仮説（カスタム TCP 不可）をコメントに残したまま設計判断してしまった。

**Try（次に活かす）**
- 到達性トラブルは初手で `nft list ruleset` / `iptables -S` / 稼働サービス一覧を確認する。
- 「修正した」は**クリーン環境での再現確認**まで含めて初めて完了とする。
- 仮説はコード/ログで**反証**を取ってから設計に反映する。

## 7. 残課題・将来の展望

- **証明書失効（CRL/OCSP）** … 現状 IKEv2 の `remove` はローカル配布物の削除のみで、
  発行済み証明書は失効しない。厳密運用が必要なら strongSwan 側の revocation 検証設定と
  セットで実装する。
- **カスタム TCP SG ルールの TCP 到達性** … nftables 無効化後にランダム配信ポートで到達を
  確認済みだが、より広範なポートでの検証余地はある。
- **プリセット/USAGE の追補** … `randomize_profile_port` の記載、接続確認手順の反映など。
- **鍵ローテーションの実挙動** … iOS 上で長時間セッション時に切断が起きないか継続観察。
