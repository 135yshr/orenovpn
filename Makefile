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

.PHONY: help init plan deploy apply status ssh client clients show remove destroy fmt validate

help: ## このヘルプを表示
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

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
