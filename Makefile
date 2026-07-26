# =============================================================================
# orenovpn 操作用 Makefile
#   よく使う操作を短いコマンドにまとめたもの。
#   例:  make init → make deploy → make client NAME=my-phone
# =============================================================================
TF := terraform -chdir=terraform

# ローカル設定（任意・gitignore 済み）。SSH_KEY 等を毎回指定せず固定できる。
#   orenovpn.local.mk に  SSH_KEY = ~/.ssh/orenovpn  と書いておけば以降は省略可。
-include orenovpn.local.mk

# 接続情報は terraform の出力から取得（apply 完了後に有効になる）。
# `=`（遅延展開）なので、apply 前の init/deploy では評価されない。
SSH_HOST = $(shell $(TF) output -raw server_ip 2>/dev/null)
SSH_PORT = 22
SSH_USER = $(shell $(TF) output -raw admin_user 2>/dev/null)

# 秘密鍵のパス。既定パス(~/.ssh/id_ed25519 等)以外なら指定する。優先順位:
#   1) コマンドで SSH_KEY=... を明示   2) orenovpn.local.mk   3) 環境変数 ORENOVPN_SSH_KEY
# ~/.ssh/config や ssh-add で解決している場合は不要。
SSH_KEY ?= $(ORENOVPN_SSH_KEY)

# 実際に叩く ssh / scp コマンド（SSH_KEY 指定時のみ -i を付与）
SSH = ssh -p $(SSH_PORT) $(if $(strip $(SSH_KEY)),-i $(SSH_KEY),) $(SSH_USER)@$(SSH_HOST)
SCP = scp -P $(SSH_PORT) $(if $(strip $(SSH_KEY)),-i $(SSH_KEY),)

# NAME はレシピに直接展開せず環境変数で渡し、シェル側で検証する（$(NAME) を
# レシピ文字列に埋め込むと Make 展開時点でシェル注入/パストラバーサルの余地が
# 生じるため）。使う側は $$NAME を参照する。
export NAME

# HOURS も同様に環境変数として渡す（コマンドラインだけでなく orenovpn.local.mk で
# 定義した場合もレシピのシェルへ届くようにする）。
export HOURS

# NAME を英数字・ハイフン・アンダースコアのみに制限（空も拒否）。各ターゲット冒頭で呼ぶ。
NAMECHECK = printf '%s' "$$NAME" | grep -qE '^[A-Za-z0-9_-]+$$' || { echo "NAME を英数字・ハイフン・アンダースコアで指定してください（例: NAME=my-phone）"; exit 1; }

.PHONY: help preset init plan deploy apply status setup sync-scripts ssh doctor alerts-test alerts-status configure-alerts configure-logging access-log dns-log logs-status client clients show profile serve-profile remove destroy fmt validate check images volume-types

# HOURS（記録の参照範囲）を整数に検証し、未指定なら 6 にする。各レシピの先頭で呼ぶ。
HOURSCHECK = HOURS="$${HOURS:-6}"; printf '%s' "$$HOURS" | grep -qE '^[0-9]+$$' || { echo "HOURS は整数で指定してください（例: HOURS=6）"; exit 1; }

help: ## このヘルプを表示
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

preset: ## 設定プリセットを適用  例: make preset PRESET=balanced  (simple|balanced|hardened|ikev2)
	@case "$(PRESET)" in \
	  simple)   f=presets/01-simple.tfvars ;; \
	  balanced) f=presets/02-balanced.tfvars ;; \
	  hardened) f=presets/03-hardened.tfvars ;; \
	  ikev2)    f=presets/04-ikev2-apple.tfvars ;; \
	  *) echo "PRESET=simple|balanced|hardened|ikev2 のいずれかを指定してください"; exit 1 ;; \
	esac; \
	if [ -f terraform/terraform.tfvars ] && [ "$(FORCE)" != "1" ]; then \
	  echo "terraform/terraform.tfvars は既に存在します。上書きするなら FORCE=1 を付けてください。"; exit 1; \
	fi; \
	cp "terraform/$$f" terraform/terraform.tfvars; \
	echo "$$f を terraform/terraform.tfvars に適用しました。"; \
	echo "→ 認証情報とSSH公開鍵を編集してください（②③は allowed_ssh_cidr も）。"

images: ## 利用可能な OS イメージ名を確認   例: make images FILTER=debian
	@./scripts/list-images.sh $(FILTER)

volume-types: ## 利用可能なボリュームタイプ名を確認
	@./scripts/list-volume-types.sh

init: ## Terraform を初期化（最初に一度）
	$(TF) init

plan: ## 変更内容を確認
	$(TF) plan

deploy apply: ## VPS を作成/更新
	$(TF) apply

status: ## サーバーの初回ブート完了(SSH疎通)を待つ
	@$(SSH) 'cloud-init status --wait || true; echo "SSH 疎通OK"'

setup: ## ソフト導入・VPN構成を実行（deploy後・観察しながら）
	@echo "スクリプトを転送中..."
	@$(SCP) scripts/setup.sh scripts/wg-client scripts/ikev2-client scripts/vpn-client scripts/watch.sh scripts/orenovpn-logs $(SSH_USER)@$(SSH_HOST):/tmp/
	@echo "サーバー上で構成を実行します（出力を確認してください）..."
	@$(SSH) 'bash -o pipefail -c "\
	         sudo install -m 0755 /tmp/wg-client /usr/local/sbin/wg-client && \
	         sudo install -m 0755 /tmp/ikev2-client /usr/local/sbin/ikev2-client && \
	         sudo install -m 0755 /tmp/vpn-client /usr/local/sbin/vpn-client && \
	         sudo install -m 0755 /tmp/watch.sh /usr/local/sbin/orenovpn-watch && \
	         sudo install -m 0755 /tmp/orenovpn-logs /usr/local/sbin/orenovpn-logs && \
	         sudo install -m 0700 /tmp/setup.sh /usr/local/sbin/setup.sh && \
	         sudo /usr/local/sbin/setup.sh 2>&1 | sudo tee /var/log/orenovpn-setup.log && \
	         rm -f /tmp/setup.sh /tmp/wg-client /tmp/ikev2-client /tmp/vpn-client /tmp/watch.sh /tmp/orenovpn-logs"'

sync-scripts: ## サーバー上のスクリプトだけを最新に更新（setup.sh は実行しない）
	@echo "スクリプトを転送中..."
	@$(SCP) scripts/setup.sh scripts/wg-client scripts/ikev2-client scripts/vpn-client scripts/watch.sh scripts/orenovpn-logs $(SSH_USER)@$(SSH_HOST):/tmp/
	@$(SSH) 'bash -o pipefail -c "\
	         sudo install -m 0755 /tmp/wg-client /usr/local/sbin/wg-client && \
	         sudo install -m 0755 /tmp/ikev2-client /usr/local/sbin/ikev2-client && \
	         sudo install -m 0755 /tmp/vpn-client /usr/local/sbin/vpn-client && \
	         sudo install -m 0755 /tmp/watch.sh /usr/local/sbin/orenovpn-watch && \
	         sudo install -m 0755 /tmp/orenovpn-logs /usr/local/sbin/orenovpn-logs && \
	         sudo install -m 0700 /tmp/setup.sh /usr/local/sbin/setup.sh && \
	         rm -f /tmp/setup.sh /tmp/wg-client /tmp/ikev2-client /tmp/vpn-client /tmp/watch.sh /tmp/orenovpn-logs"'
	@echo "✅ スクリプトを更新しました。"
	@echo "   ※ サーバー構成そのもの（ufw / unbound / 記録ルール等）の反映には make setup が必要です。"

ssh: ## サーバーへ SSH 接続
	@$(SSH)

doctor: ## サーバー構成を自己診断（不通/通信不可の原因切り分け）
	@$(SSH) 'bash -s' < scripts/doctor.sh

alerts-test: ## 通信監視のテストメールを送信（設定確認用）
	@echo "テストメールを送信します（ALERT_EMAIL 宛て）..."
	@$(SSH) 'sudo orenovpn-watch test'

alerts-status: ## 通信監視 timer の状態と直近ログを表示
	@$(SSH) 'systemctl status orenovpn-watch.timer --no-pager || true; echo; sudo journalctl -u orenovpn-watch --no-pager -n 20 || true'

configure-alerts: ## 既存サーバーにアラート設定を反映（対話入力・state に残さない）
	@ORENOVPN_SSH="$(SSH)" bash scripts/configure-alerts.sh

configure-logging: ## アクセス先の記録をON/OFF  例: make configure-logging ACCESS_LOG=on DNS_LOG=on DAYS=14
	@ORENOVPN_SSH="$(SSH)" ACCESS_LOG="$(ACCESS_LOG)" DNS_LOG="$(DNS_LOG)" DAYS="$(DAYS)" \
	  bash scripts/configure-logging.sh

access-log: ## 記録した接続先(宛先IP/ポート)を表示・集計  例: make access-log HOURS=6
	@$(HOURSCHECK); $(SSH) "sudo orenovpn-logs access $$HOURS"

dns-log: ## 記録したDNS問い合わせ(ドメイン名)を表示・集計  例: make dns-log HOURS=6
	@$(HOURSCHECK); $(SSH) "sudo orenovpn-logs dns $$HOURS"

logs-status: ## 記録機能の有効/無効・適用ルール・待受を表示
	@$(SSH) 'sudo orenovpn-logs status'

client: ## クライアントを追加   例: make client NAME=my-phone
	@$(NAMECHECK)
	@$(SSH) "sudo vpn-client add $$NAME"

clients: ## クライアント一覧を表示
	@$(SSH) 'sudo vpn-client list'

show: ## 設定/QR/プロファイルを再表示   例: make show NAME=my-phone
	@$(NAMECHECK)
	@$(SSH) "sudo vpn-client show $$NAME"

serve-profile: ## VPSから一時HTTPS+QRで配信(iPhoneのSafariで取得)  例: make serve-profile NAME=iphone
	@$(NAMECHECK)
	@SSH_KEY="$(SSH_KEY)" SERVE_PORT="$$($(TF) output -raw profile_port 2>/dev/null)" PROFILE_DOMAIN="$(PROFILE_DOMAIN)" ./scripts/serve-profile.sh "$$NAME" "$(SSH_HOST)" "$(SSH_USER)"

profile: ## 構成ファイルを手元にDL(iOSはAirDropで転送)  例: make profile NAME=iphone
	@$(NAMECHECK)
	@umask 077; $(SSH) "sudo cat /etc/orenovpn/clients/$$NAME.mobileconfig 2>/dev/null || sudo cat /etc/orenovpn/clients/$$NAME.conf 2>/dev/null" > "$$NAME.download"; \
	if [ ! -s "$$NAME.download" ]; then echo "取得失敗: クライアント '$$NAME' が見つかりません（make clients で確認）"; rm -f "$$NAME.download"; exit 1; fi; \
	if head -1 "$$NAME.download" | grep -qi xml; then mv "$$NAME.download" "$$NAME.mobileconfig"; f="$$NAME.mobileconfig"; else mv "$$NAME.download" "$$NAME.conf"; f="$$NAME.conf"; fi; \
	chmod 600 "$$f"; \
	echo "保存しました: ./$$f （0600。VPN 資格情報そのものなので取り扱い注意）"; \
	echo "→ iPhoneへ: Finderで $$f を右クリック → 共有 → AirDrop で iPhone を選択"; \
	echo "⚠️ メール/クラウド経由で渡さないこと（IKEv2 は .mobileconfig 内に p12 の"; \
	echo "   復号パスワードが平文で入っており、渡した先の履歴に残った時点で漏洩です）。"; \
	echo "   端末へ入れたら手元のファイルは削除してください: rm $$f"

remove: ## クライアントを削除   例: make remove NAME=my-phone
	@$(NAMECHECK)
	@$(SSH) "sudo vpn-client remove $$NAME"

destroy: ## VPS を削除（VPN を完全に撤去）
	$(TF) destroy

fmt: ## Terraform コードを整形
	$(TF) fmt -recursive

validate: ## Terraform コードを検証
	$(TF) validate

check: ## デプロイ前のローカル一括検証（fmt/validate/構文/shellcheck）
	@echo "==> terraform fmt -check"
	@$(TF) fmt -check -recursive
	@echo "==> terraform validate"
	@$(TF) validate
	@echo "==> bash -n（全スクリプト構文）"
	@for f in scripts/*; do bash -n "$$f" || exit 1; done; echo "  scripts OK"
	@if command -v shellcheck >/dev/null 2>&1; then \
	  echo "==> shellcheck"; shellcheck -S warning scripts/*; \
	else echo "==> shellcheck（未導入・スキップ）"; fi
	@echo "✅ すべての検証を通過しました"
