# zserver Makefile
#
# Convenience targets for the local dev workflow. All targets are best-effort:
# if a required tool (e.g. docker) is missing, the target prints a clear
# message and exits 0 so CI/local loops don't fail.
#
# Run from this directory: `cd zserver && make <target>`.
# When invoked from a parent Makefile, pass `-f zserver/Makefile`.

ZSERVER_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SCRIPTS_DIR := $(ZSERVER_DIR)/scripts

# Detect docker; print a friendly skip message when missing. Cached at
# parse time so the check runs once per invocation, not per target.
DOCKER := $(shell command -v docker 2>/dev/null)

.PHONY: help build test check db-up db-migrate db-reset ci clean

help: ## Show this help.
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-15s %s\n", $$1, $$2}'

build: ## zig build
	cd $(ZSERVER_DIR) && zig build

test: ## zig build test
	cd $(ZSERVER_DIR) && zig build test

check: build test ## Build and run unit tests.

db-up: ## Bring up the local Postgres via scripts/db-up.sh (best-effort).
	@if [ -z "$(DOCKER)" ]; then \
		echo "==> docker not available, skipping make db-up"; \
	else \
		bash $(SCRIPTS_DIR)/db-up.sh; \
	fi

db-migrate: ## Apply SQL migrations via scripts/db-migrate.sh.
	bash $(SCRIPTS_DIR)/db-migrate.sh

db-reset: ## Stop and remove the dev postgres volume (docker compose down -v).
	@if [ -z "$(DOCKER)" ]; then \
		echo "==> docker not available, skipping make db-reset"; \
	else \
		echo "==> docker compose down -v (postgres volume)"; \
		cd $(ZSERVER_DIR)/.. && docker compose down -v postgres; \
	fi

ci: ## Best-effort: db-up (skipped if no docker) -> db-migrate -> check.
	@echo "==> make ci: starting"
	@echo "--> db-up"
	@$(MAKE) -f $(ZSERVER_DIR)/Makefile -s db-up
	@echo "--> db-migrate"
	@$(MAKE) -f $(ZSERVER_DIR)/Makefile -s db-migrate
	@echo "--> check"
	@$(MAKE) -f $(ZSERVER_DIR)/Makefile -s check
	@echo "--> smoke (smoke_test.sh)"
	@bash $(ZSERVER_DIR)/scripts/smoke_test.sh
	@echo "--> issue e2e (issue_e2e.sh, 27 endpoints)"
	@bash $(ZSERVER_DIR)/scripts/issue_e2e.sh
	@echo "--> workspace e2e (workspace_e2e.sh, 11 endpoints)"
	@bash $(ZSERVER_DIR)/scripts/workspace_e2e.sh
	@echo "--> skill e2e (skill_e2e.sh, 10 endpoints)"
	@bash $(ZSERVER_DIR)/scripts/skill_e2e.sh
	@echo "--> label e2e (label_e2e.sh, label CRUD + issue/label join)"
	@bash $(ZSERVER_DIR)/scripts/label_e2e.sh
	@echo "--> project e2e (project_e2e.sh, project + resource CRUD)"
	@bash $(ZSERVER_DIR)/scripts/project_e2e.sh
	@echo "--> daemon e2e (daemon_e2e.sh, register/heartbeat/claim/deregister)"
	@bash $(ZSERVER_DIR)/scripts/daemon_e2e.sh
	@echo "--> autopilot e2e (autopilot_e2e.sh, deliveries + rotate-webhook-token)"
	@bash $(ZSERVER_DIR)/scripts/autopilot_e2e.sh
	@echo "--> cloud_runtime e2e (cloud_runtime_e2e.sh, node lifecycle)"
	@bash $(ZSERVER_DIR)/scripts/cloud_runtime_e2e.sh
	@echo "--> frontend integration (frontend_integration.sh, Next.js client call patterns)"
	@bash $(ZSERVER_DIR)/scripts/frontend_integration.sh
	@echo "--> pipeline e2e (pipeline_e2e.sh, pipeline config + run + phase)"
	@bash $(ZSERVER_DIR)/scripts/pipeline_e2e.sh
	@echo "--> role e2e (role_e2e.sh, role CRUD + hierarchy)"
	@bash $(ZSERVER_DIR)/scripts/role_e2e.sh
	@echo "--> commission e2e (commission_e2e.sh, commission rule + calculate)"
	@bash $(ZSERVER_DIR)/scripts/commission_e2e.sh
	@echo "--> content_matrix e2e (content_matrix_e2e.sh, content distribution)"
	@bash $(ZSERVER_DIR)/scripts/content_matrix_e2e.sh
	@echo "--> referral e2e (referral_e2e.sh, referral tracking)"
	@bash $(ZSERVER_DIR)/scripts/referral_e2e.sh
	@echo "--> dashboard_v2 e2e (dashboard_v2_e2e.sh, configurable widgets)"
	@bash $(ZSERVER_DIR)/scripts/dashboard_v2_e2e.sh
	@echo "--> token_economy e2e (token_economy_e2e.sh, earn/spend/transfer)"
	@bash $(ZSERVER_DIR)/scripts/token_economy_e2e.sh
	@echo "--> training e2e (training_e2e.sh, course + certification)"
	@bash $(ZSERVER_DIR)/scripts/training_e2e.sh
	@echo "--> wallet e2e (wallet_e2e.sh, deposit/withdraw/reward)"
	@bash $(ZSERVER_DIR)/scripts/wallet_e2e.sh
	@echo "--> i18n e2e (i18n_e2e.sh, locale + translation)"
	@bash $(ZSERVER_DIR)/scripts/i18n_e2e.sh
	@echo "--> compliance e2e (compliance_e2e.sh, audit rules)"
	@bash $(ZSERVER_DIR)/scripts/compliance_e2e.sh
	@echo "--> community_ops e2e (community_ops_e2e.sh, groups + announcements)"
	@bash $(ZSERVER_DIR)/scripts/community_ops_e2e.sh
	@echo "--> agent e2e (agent_e2e.sh, agent CRUD + env + skills + tasks)"
	@bash $(ZSERVER_DIR)/scripts/agent_e2e.sh
	@echo "--> agent_template e2e (agent_template_e2e.sh, template CRUD)"
	@bash $(ZSERVER_DIR)/scripts/agent_template_e2e.sh
	@echo "==> make ci: done"

clean: ## Remove zig build artifacts.
	rm -rf $(ZSERVER_DIR)/zig-out $(ZSERVER_DIR)/.zig-cache
