# =============================================================================
# orenovpn 操作用 Makefile
#   よく使う操作を短いコマンドにまとめたもの。
#   例:  make init → make deploy → make client NAME=my-phone
# =============================================================================
TF := terraform -chdir=terraform

# 接続情報は terraform の出力から取得（apply 完了後に有効になる）。
# `=`（遅延展開）なので、apply 前の init/deploy では評価されない。
SSH_HOST = $(shell $(TF) output -raw server_ip 2>/dev/null)
SSH_PORT = $(shell $(TF) output -raw ssh_port 2>/dev/null)
SSH_USER = $(shell $(TF) output -raw admin_user 2>/dev/null)

# 任意: 既定パス(~/.ssh/id_ed25519 等)以外に秘密鍵を置いた場合に指定する。
#   例)  make ssh SSH_KEY=~/.ssh/orenovpn
# ~/.ssh/config や ssh-add で鍵を解決している場合は指定不要。
SSH_KEY ?=

# 実際に叩く ssh コマンド（SSH_KEY 指定時のみ -i を付与）
SSH = ssh -p $(SSH_PORT) $(if $(strip $(SSH_KEY)),-i $(SSH_KEY),) $(SSH_USER)@$(SSH_HOST)

.PHONY: help preset init plan deploy apply status ssh client clients show remove destroy fmt validate images

help: ## このヘルプを表示
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

preset: ## 設定プリセットを適用  例: make preset PRESET=balanced  (simple|balanced|hardened)
	@case "$(PRESET)" in \
	  simple)   f=presets/01-simple.tfvars ;; \
	  balanced) f=presets/02-balanced.tfvars ;; \
	  hardened) f=presets/03-hardened.tfvars ;; \
	  *) echo "PRESET=simple|balanced|hardened のいずれかを指定してください"; exit 1 ;; \
	esac; \
	if [ -f terraform/terraform.tfvars ] && [ "$(FORCE)" != "1" ]; then \
	  echo "terraform/terraform.tfvars は既に存在します。上書きするなら FORCE=1 を付けてください。"; exit 1; \
	fi; \
	cp "terraform/$$f" terraform/terraform.tfvars; \
	echo "$$f を terraform/terraform.tfvars に適用しました。"; \
	echo "→ 認証情報とSSH公開鍵を編集してください（②③は allowed_ssh_cidr も）。"

images: ## 利用可能な OS イメージ名を確認   例: make images FILTER=debian
	@./scripts/list-images.sh $(FILTER)

init: ## Terraform を初期化（最初に一度）
	$(TF) init

plan: ## 変更内容を確認
	$(TF) plan

deploy apply: ## VPS を作成/更新
	$(TF) apply

status: ## サーバーの初期設定完了を待つ
	@$(SSH) 'cloud-init status --wait'

ssh: ## サーバーへ SSH 接続
	@$(SSH)

client: ## クライアントを追加   例: make client NAME=my-phone
	@test -n "$(NAME)" || (echo "NAME を指定してください: make client NAME=my-phone"; exit 1)
	@$(SSH) 'sudo wg-client add $(NAME)'

clients: ## クライアント一覧を表示
	@$(SSH) 'sudo wg-client list'

show: ## 設定と QR を再表示   例: make show NAME=my-phone
	@test -n "$(NAME)" || (echo "NAME を指定してください: make show NAME=my-phone"; exit 1)
	@$(SSH) 'sudo wg-client show $(NAME)'

remove: ## クライアントを削除   例: make remove NAME=my-phone
	@test -n "$(NAME)" || (echo "NAME を指定してください: make remove NAME=my-phone"; exit 1)
	@$(SSH) 'sudo wg-client remove $(NAME)'

destroy: ## VPS を削除（VPN を完全に撤去）
	$(TF) destroy

fmt: ## Terraform コードを整形
	$(TF) fmt -recursive

validate: ## Terraform コードを検証
	$(TF) validate
