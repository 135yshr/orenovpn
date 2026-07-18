# =============================================================================
# orenovpn 操作用 Makefile
#   よく使う操作を短いコマンドにまとめたもの。
#   例:  make init → make deploy → make client NAME=my-phone
# =============================================================================
TF      := terraform -chdir=terraform
SSH_PORT = $(shell $(TF) output -raw ssh_port 2>/dev/null || echo 22022)

# terraform.tfvars から接続情報を取得（apply 後に有効）
define ssh_target
$(shell $(TF) output -raw ssh_command 2>/dev/null)
endef

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
	@$(call ssh_target) 'cloud-init status --wait'

ssh: ## サーバーへ SSH 接続
	@$(call ssh_target)

client: ## クライアントを追加   例: make client NAME=my-phone
	@test -n "$(NAME)" || (echo "NAME を指定してください: make client NAME=my-phone"; exit 1)
	@$(call ssh_target) 'sudo wg-client add $(NAME)'

clients: ## クライアント一覧を表示
	@$(call ssh_target) 'sudo wg-client list'

show: ## 設定と QR を再表示   例: make show NAME=my-phone
	@test -n "$(NAME)" || (echo "NAME を指定してください: make show NAME=my-phone"; exit 1)
	@$(call ssh_target) 'sudo wg-client show $(NAME)'

remove: ## クライアントを削除   例: make remove NAME=my-phone
	@test -n "$(NAME)" || (echo "NAME を指定してください: make remove NAME=my-phone"; exit 1)
	@$(call ssh_target) 'sudo wg-client remove $(NAME)'

destroy: ## VPS を削除（VPN を完全に撤去）
	$(TF) destroy

fmt: ## Terraform コードを整形
	$(TF) fmt -recursive

validate: ## Terraform コードを検証
	$(TF) validate
