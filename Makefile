# Top-level orchestrator for the apple-tasks monorepo.
# Products: cli/ + mcp/ (agent API) and apps/AgentTasks (ops / Siri app).

CLI_DIR = cli
RELEASE_DIR = $(CLI_DIR)/.build/release
APPLE_TASKS_BIN = $(CURDIR)/$(RELEASE_DIR)/apple-tasks
LAUNCH_AGENTS = $(HOME)/Library/LaunchAgents
CONFIG_DIR = $(HOME)/.config/apple-tasks
WRAPPER_DST = $(CONFIG_DIR)/bin/run-with-env.sh
DISPATCH_LABEL = com.apple-tasks.dispatch
DIGEST_LABEL = com.apple-tasks.digest
# Seconds between dispatch passes (default 5 min). Override: make install-agent INTERVAL=120
INTERVAL ?= 300
# Local clock for morning digest. Override: make install-digest HOUR=7 MINUTE=0
HOUR ?= 7
MINUTE ?= 0

.PHONY: all cli helper mcp app clean betacheck mail-rule \
	install-agent uninstall-agent install-digest uninstall-digest

all: cli helper

cli:
	$(MAKE) -C $(CLI_DIR) cli

helper: cli
	$(MAKE) -C $(CLI_DIR) helper

mcp:
	cd mcp && bun install

app:
	cd apps/AgentTasks && ./build.sh

clean:
	$(MAKE) -C $(CLI_DIR) clean
	rm -rf apps/AgentTasks/build

# Mail-rule capture: compile + install the AppleScript Mail rules invoke.
# Attach manually: Mail > Settings > Rules > Add Rule > Run AppleScript.
MAIL_SCRIPTS_DIR = $(HOME)/Library/Application Scripts/com.apple.mail
mail-rule: cli
	mkdir -p "$(MAIL_SCRIPTS_DIR)"
	@tmp=$$(mktemp); trap 'rm -f "$$tmp"' EXIT; \
	sed 's|@APPLE_TASKS_BIN_DEFAULT@|$(APPLE_TASKS_BIN)|g' \
		tools/mail-rule-capture.applescript > "$$tmp"; \
	osacompile -o "$(MAIL_SCRIPTS_DIR)/apple-tasks-capture.scpt" "$$tmp"
	@echo "installed: $(MAIL_SCRIPTS_DIR)/apple-tasks-capture.scpt"
	@echo "attach it: Mail > Settings > Rules > Add Rule > Run AppleScript > apple-tasks-capture"

# --- Always-on dispatch (launchd) -------------------------------------------

install-agent: cli helper
	@mkdir -p "$(CONFIG_DIR)/bin" "$(CONFIG_DIR)/logs" "$(LAUNCH_AGENTS)"
	@cp tools/launchd/run-with-env.sh "$(WRAPPER_DST)"
	@chmod +x "$(WRAPPER_DST)"
	@if [ ! -f "$(CONFIG_DIR)/agents.json" ]; then \
	  cp examples/agents.json "$(CONFIG_DIR)/agents.json"; \
	  echo "seeded $(CONFIG_DIR)/agents.json from examples/ — edit workdirs before relying on it"; \
	fi
	@if [ ! -f "$(CONFIG_DIR)/launchd.env" ]; then \
	  printf '# Optional env for LaunchAgents (sourced by run-with-env.sh)\n# export CURSOR_API_KEY=\n# export ANTHROPIC_API_KEY=\n' \
	    > "$(CONFIG_DIR)/launchd.env"; \
	  echo "wrote $(CONFIG_DIR)/launchd.env (add API keys here if needed)"; \
	fi
	@tmp=$$(mktemp); \
	sed -e 's|@WRAPPER@|$(WRAPPER_DST)|g' \
	    -e 's|@APPLE_TASKS_BIN@|$(APPLE_TASKS_BIN)|g' \
	    -e 's|@HOME@|$(HOME)|g' \
	    -e 's|@INTERVAL@|$(INTERVAL)|g' \
	    tools/launchd/$(DISPATCH_LABEL).plist > "$$tmp"; \
	mv "$$tmp" "$(LAUNCH_AGENTS)/$(DISPATCH_LABEL).plist"
	@uid=$$(id -u); \
	launchctl bootout "gui/$$uid/$(DISPATCH_LABEL)" 2>/dev/null || true; \
	launchctl bootstrap "gui/$$uid" "$(LAUNCH_AGENTS)/$(DISPATCH_LABEL).plist"; \
	launchctl enable "gui/$$uid/$(DISPATCH_LABEL)" 2>/dev/null || true
	@echo "installed LaunchAgent $(DISPATCH_LABEL) (every $(INTERVAL)s)"
	@echo "  binary:  $(APPLE_TASKS_BIN)"
	@echo "  config:  $(CONFIG_DIR)/agents.json"
	@echo "  logs:    $(CONFIG_DIR)/logs/dispatch.*.log"
	@echo "  dry-run: $(APPLE_TASKS_BIN) dispatch --dry-run"
	@echo "  unload:  make uninstall-agent"

uninstall-agent:
	@uid=$$(id -u); \
	launchctl bootout "gui/$$uid/$(DISPATCH_LABEL)" 2>/dev/null || true; \
	rm -f "$(LAUNCH_AGENTS)/$(DISPATCH_LABEL).plist"
	@echo "removed LaunchAgent $(DISPATCH_LABEL)"

install-digest: cli helper
	@mkdir -p "$(CONFIG_DIR)/bin" "$(CONFIG_DIR)/logs" "$(LAUNCH_AGENTS)"
	@cp tools/launchd/run-with-env.sh "$(WRAPPER_DST)"
	@chmod +x "$(WRAPPER_DST)"
	@tmp=$$(mktemp); \
	sed -e 's|@WRAPPER@|$(WRAPPER_DST)|g' \
	    -e 's|@APPLE_TASKS_BIN@|$(APPLE_TASKS_BIN)|g' \
	    -e 's|@HOME@|$(HOME)|g' \
	    -e 's|@HOUR@|$(HOUR)|g' \
	    -e 's|@MINUTE@|$(MINUTE)|g' \
	    tools/launchd/$(DIGEST_LABEL).plist > "$$tmp"; \
	mv "$$tmp" "$(LAUNCH_AGENTS)/$(DIGEST_LABEL).plist"
	@uid=$$(id -u); \
	launchctl bootout "gui/$$uid/$(DIGEST_LABEL)" 2>/dev/null || true; \
	launchctl bootstrap "gui/$$uid" "$(LAUNCH_AGENTS)/$(DIGEST_LABEL).plist"; \
	launchctl enable "gui/$$uid/$(DIGEST_LABEL)" 2>/dev/null || true
	@echo "installed LaunchAgent $(DIGEST_LABEL) (daily $(HOUR):$$(printf '%02d' $(MINUTE)))"
	@echo "  unload: make uninstall-digest"

uninstall-digest:
	@uid=$$(id -u); \
	launchctl bootout "gui/$$uid/$(DIGEST_LABEL)" 2>/dev/null || true; \
	rm -f "$(LAUNCH_AGENTS)/$(DIGEST_LABEL).plist"
	@echo "removed LaunchAgent $(DIGEST_LABEL)"

# Beta upgrade regression drill. Rebuilds the CLI last; dyld-runs the
# FoundationModels probe when present under research/.
betacheck:
	@log=$$(mktemp); probe=$$(mktemp); trap 'rm -f "$$log" "$$probe"' EXIT; \
	step() { name=$$1; shift; \
	  if "$$@" >"$$log" 2>&1; then echo "PASS  $$name"; \
	  else echo "FAIL  $$name"; cat "$$log"; exit 1; fi; }; \
	step "doctor"           $(RELEASE_DIR)/apple-tasks doctor; \
	step "private --check"  $(RELEASE_DIR)/apple-tasks-private --check; \
	step "whereami"         $(RELEASE_DIR)/apple-tasks whereami; \
	step "list smoke"       $(RELEASE_DIR)/apple-tasks list --status open; \
	step "swift build"      $(MAKE) -C $(CLI_DIR) cli; \
	if [ -f research/ClaudeLanguageModel/SchemaProbe.swift ]; then \
	  step "fm probe compile" swiftc research/ClaudeLanguageModel/SchemaProbe.swift -o "$$probe"; \
	  step "fm probe run"     "$$probe"; \
	fi
