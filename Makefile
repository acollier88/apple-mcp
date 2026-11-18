# Top-level orchestrator for the apple-tasks monorepo.
# Products: cli/ + mcp/ (agent API) and apps/AgentTasks (ops / Siri app).

CLI_DIR = cli
RELEASE_DIR = $(CLI_DIR)/.build/release
# Deployed copies (#33). launchd, the app and the Mail rule run these, never
# the build directory, so a `swift build` in some checkout cannot swap the
# live dispatcher. Override: make install BINDIR=/x/bin (or PREFIX=/x).
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
APPLE_TASKS_BIN = $(BINDIR)/apple-tasks
# All overridable on the command line so the install targets can be exercised
# against a temp dir; LAUNCHCTL=true skips loading/unloading the job.
LAUNCH_AGENTS = $(HOME)/Library/LaunchAgents
CONFIG_DIR = $(HOME)/.config/apple-tasks
LAUNCHCTL = launchctl
WRAPPER_DST = $(CONFIG_DIR)/bin/run-with-env.sh
DISPATCH_LABEL = com.apple-tasks.dispatch
DIGEST_LABEL = com.apple-tasks.digest
WATCHDOG_LABEL = com.apple-tasks.watchdog
# Seconds between dispatch passes (default 5 min). Override: make install-agent INTERVAL=120
INTERVAL ?= 300
# Local clock for morning digest. Override: make install-digest HOUR=7 MINUTE=0
HOUR ?= 7
MINUTE ?= 0

# sign-identity: once-per-machine self-signed "AgentTasks Dev" cert so TCC
# and Keychain ACLs survive rebuilds (ad-hoc identities change every link).
.PHONY: all cli helper install mcp app server install-server clean betacheck mail-rule \
	install-agent uninstall-agent install-digest uninstall-digest \
	install-watchdog uninstall-watchdog test sign-identity

all: cli helper

cli:
	$(MAKE) -C $(CLI_DIR) cli
	tools/sign.sh $(RELEASE_DIR)/apple-tasks

helper: cli
	$(MAKE) -C $(CLI_DIR) helper
	tools/sign.sh $(RELEASE_DIR)/apple-tasks-private

# Copy apple-tasks and its sibling apple-tasks-private helper (it must sit
# next to the main binary: NativeTags.helperURL) into $(BINDIR). Each file is
# staged in a temp dir inside $(BINDIR) under its final basename — codesign
# derives the identifier from the file name, and TCC grants follow identifier
# + certificate — signed with tools/sign.sh exactly like the build copies,
# then mv'd into place: a same-directory rename(2), so a dispatch pass never
# execs a half-written file. A pre-#33 symlink into cli/.build is replaced by
# the real file. Helper first, so the new main binary never sees an old one.
install: cli helper
	@mkdir -p "$(BINDIR)"
	@set -e; for name in apple-tasks-private apple-tasks; do \
	  stage=$$(mktemp -d "$(BINDIR)/.install-$$name.XXXXXX"); \
	  if cp -p "$(RELEASE_DIR)/$$name" "$$stage/$$name" \
	     && tools/sign.sh "$$stage/$$name" \
	     && mv -f "$$stage/$$name" "$(BINDIR)/$$name"; then \
	    rmdir "$$stage"; \
	  else \
	    rm -f "$$stage/$$name"; rmdir "$$stage"; \
	    echo "error: installing $$name into $(BINDIR) failed" >&2; exit 1; \
	  fi; \
	done
	@echo "installed: $(BINDIR)/apple-tasks — $$("$(BINDIR)/apple-tasks" --version)"
	@echo "installed: $(BINDIR)/apple-tasks-private"

# Persistent self-signed codesigning identity in the login keychain (idempotent).
# KEYCHAIN=/tmp/foo.keychain-db KEYCHAIN_PASSWORD=... for a throwaway keychain.
sign-identity:
	tools/sign-identity.sh

mcp:
	cd mcp && bun install

SERVER_BIN = $(CURDIR)/server/.build/release/apple-tasks-server
LOCAL_BIN = $(HOME)/.local/bin

server:
	cd server && swift build -c release
	@echo "binary: $(SERVER_BIN)"
	@echo "run:    $(SERVER_BIN)"
	@echo "or:     make install-server   # symlink ~/.local/bin/apple-tasks-server"

install-server: server
	@mkdir -p "$(LOCAL_BIN)"
	@ln -sfn "$(SERVER_BIN)" "$(LOCAL_BIN)/apple-tasks-server"
	@echo "installed: $(LOCAL_BIN)/apple-tasks-server -> $(SERVER_BIN)"
	@echo "auth: APPLE_TASKS_SERVE_TOKEN or ~/.config/apple-tasks/serve.json"

# build.sh runs `make install` itself and stamps $(BINDIR)/apple-tasks into
# the bundle (not the build-directory path).
app:
	cd apps/AgentTasks && BINDIR="$(BINDIR)" ./build.sh

test:
	$(MAKE) -C $(CLI_DIR) test
	cd server && swift test
	cd mcp && bun run typecheck && bun test

clean:
	$(MAKE) -C $(CLI_DIR) clean
	rm -rf apps/AgentTasks/build

# Mail-rule capture: compile + install the AppleScript Mail rules invoke.
# Attach manually: Mail > Settings > Rules > Add Rule > Run AppleScript.
MAIL_SCRIPTS_DIR = $(HOME)/Library/Application Scripts/com.apple.mail
mail-rule: install
	mkdir -p "$(MAIL_SCRIPTS_DIR)"
	@tmp=$$(mktemp); trap 'rm -f "$$tmp"' EXIT; \
	sed 's|@APPLE_TASKS_BIN_DEFAULT@|$(APPLE_TASKS_BIN)|g' \
		tools/mail-rule-capture.applescript > "$$tmp"; \
	osacompile -o "$(MAIL_SCRIPTS_DIR)/apple-tasks-capture.scpt" "$$tmp"
	@echo "installed: $(MAIL_SCRIPTS_DIR)/apple-tasks-capture.scpt"
	@echo "attach it: Mail > Settings > Rules > Add Rule > Run AppleScript > apple-tasks-capture"

# --- Always-on dispatch (launchd) -------------------------------------------

install-agent: install
	@mkdir -p "$(CONFIG_DIR)/bin" "$(CONFIG_DIR)/logs" "$(LAUNCH_AGENTS)"
	@cp tools/launchd/run-with-env.sh "$(WRAPPER_DST)"
	@chmod +x "$(WRAPPER_DST)"
	@if [ ! -f "$(CONFIG_DIR)/agents.json" ]; then \
	  cp examples/agents.json "$(CONFIG_DIR)/agents.json"; \
	  echo "seeded $(CONFIG_DIR)/agents.json from examples/ — edit workdirs before relying on it"; \
	fi
	@if [ ! -f "$(CONFIG_DIR)/launchd.env" ]; then \
	  printf '# Optional env for LaunchAgents (sourced by run-with-env.sh)\n# export CURSOR_API_KEY=\n# export ANTHROPIC_API_KEY=\n# export TYPESAFE_API_KEY=\n' \
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
	$(LAUNCHCTL) bootout "gui/$$uid/$(DISPATCH_LABEL)" 2>/dev/null || true; \
	$(LAUNCHCTL) bootstrap "gui/$$uid" "$(LAUNCH_AGENTS)/$(DISPATCH_LABEL).plist"; \
	$(LAUNCHCTL) enable "gui/$$uid/$(DISPATCH_LABEL)" 2>/dev/null || true
	@echo "installed LaunchAgent $(DISPATCH_LABEL) (every $(INTERVAL)s)"
	@echo "  binary:  $(APPLE_TASKS_BIN) (installed copy; redeploy: make install)"
	@echo "  config:  $(CONFIG_DIR)/agents.json"
	@echo "  logs:    $(CONFIG_DIR)/logs/dispatch.*.log"
	@echo "  dry-run: $(APPLE_TASKS_BIN) dispatch --dry-run"
	@echo "  unload:  make uninstall-agent"

uninstall-agent:
	@uid=$$(id -u); \
	$(LAUNCHCTL) bootout "gui/$$uid/$(DISPATCH_LABEL)" 2>/dev/null || true; \
	rm -f "$(LAUNCH_AGENTS)/$(DISPATCH_LABEL).plist"
	@echo "removed LaunchAgent $(DISPATCH_LABEL)"

install-digest: install
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
	$(LAUNCHCTL) bootout "gui/$$uid/$(DIGEST_LABEL)" 2>/dev/null || true; \
	$(LAUNCHCTL) bootstrap "gui/$$uid" "$(LAUNCH_AGENTS)/$(DIGEST_LABEL).plist"; \
	$(LAUNCHCTL) enable "gui/$$uid/$(DIGEST_LABEL)" 2>/dev/null || true
	@echo "installed LaunchAgent $(DIGEST_LABEL) (daily $(HOUR):$$(printf '%02d' $(MINUTE)))"
	@echo "  unload: make uninstall-digest"

uninstall-digest:
	@uid=$$(id -u); \
	$(LAUNCHCTL) bootout "gui/$$uid/$(DIGEST_LABEL)" 2>/dev/null || true; \
	rm -f "$(LAUNCH_AGENTS)/$(DIGEST_LABEL).plist"
	@echo "removed LaunchAgent $(DIGEST_LABEL)"

# Dispatcher watchdog (#56): a separate 3-minute job that reads heartbeats
# and the ledger and pushes when the dispatcher hangs or stops running.
install-watchdog: install
	@mkdir -p "$(CONFIG_DIR)/bin" "$(CONFIG_DIR)/logs" "$(LAUNCH_AGENTS)"
	@cp tools/launchd/run-with-env.sh "$(WRAPPER_DST)"
	@chmod +x "$(WRAPPER_DST)"
	@tmp=$$(mktemp); \
	sed -e 's|@WRAPPER@|$(WRAPPER_DST)|g' \
	    -e 's|@APPLE_TASKS_BIN@|$(APPLE_TASKS_BIN)|g' \
	    -e 's|@HOME@|$(HOME)|g' \
	    tools/launchd/$(WATCHDOG_LABEL).plist > "$$tmp"; \
	mv "$$tmp" "$(LAUNCH_AGENTS)/$(WATCHDOG_LABEL).plist"
	@uid=$$(id -u); \
	$(LAUNCHCTL) bootout "gui/$$uid/$(WATCHDOG_LABEL)" 2>/dev/null || true; \
	$(LAUNCHCTL) bootstrap "gui/$$uid" "$(LAUNCH_AGENTS)/$(WATCHDOG_LABEL).plist"; \
	$(LAUNCHCTL) enable "gui/$$uid/$(WATCHDOG_LABEL)" 2>/dev/null || true
	@echo "installed LaunchAgent $(WATCHDOG_LABEL) (every 180s)"
	@echo "  unload: make uninstall-watchdog"

uninstall-watchdog:
	@uid=$$(id -u); \
	$(LAUNCHCTL) bootout "gui/$$uid/$(WATCHDOG_LABEL)" 2>/dev/null || true; \
	rm -f "$(LAUNCH_AGENTS)/$(WATCHDOG_LABEL).plist"
	@echo "removed LaunchAgent $(WATCHDOG_LABEL)"

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
