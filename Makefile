# Top-level orchestrator for the apple-tasks monorepo.
# Products: cli/ + mcp/ (agent API) and apps/AgentTasks (ops / Siri app).

CLI_DIR = cli
RELEASE_DIR = $(CLI_DIR)/.build/release

.PHONY: all cli helper mcp app clean betacheck mail-rule

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
	sed 's|@APPLE_TASKS_BIN_DEFAULT@|$(CURDIR)/$(RELEASE_DIR)/apple-tasks|g' \
		tools/mail-rule-capture.applescript > "$$tmp"; \
	osacompile -o "$(MAIL_SCRIPTS_DIR)/apple-tasks-capture.scpt" "$$tmp"
	@echo "installed: $(MAIL_SCRIPTS_DIR)/apple-tasks-capture.scpt"
	@echo "attach it: Mail > Settings > Rules > Add Rule > Run AppleScript > apple-tasks-capture"

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
