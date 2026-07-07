RELEASE_DIR = .build/release

all: cli helper

cli:
	swift build -c release

# Private ReminderKit helper for native tag mirroring. Optional: the CLI
# works without it ([tag] prefixes remain the source of truth).
helper: cli
	clang -fobjc-arc -O -framework Foundation \
		-o $(RELEASE_DIR)/apple-tasks-private Sources/private-helper/apple-tasks-private.m

clean:
	swift package clean

# Beta upgrade regression drill (IDEAS #32/#33): one command for upgrade
# morning. Runs each check in order, prints PASS/FAIL per step, and stops
# on the first failure (dumping that step's output). Rebuilds last so a
# toolchain break is caught too. If the FoundationModels schema probe
# spike is present, compiles AND dyld-runs it to catch SDK/OS skew.
betacheck:
	@log=$$(mktemp); probe=$$(mktemp); trap 'rm -f "$$log" "$$probe"' EXIT; \
	step() { name=$$1; shift; \
	  if "$$@" >"$$log" 2>&1; then echo "PASS  $$name"; \
	  else echo "FAIL  $$name"; cat "$$log"; exit 1; fi; }; \
	step "doctor"           $(RELEASE_DIR)/apple-tasks doctor; \
	step "private --check"  $(RELEASE_DIR)/apple-tasks-private --check; \
	step "whereami"         $(RELEASE_DIR)/apple-tasks whereami; \
	step "list smoke"       $(RELEASE_DIR)/apple-tasks list --status open; \
	step "swift build"      swift build -c release; \
	if [ -f spikes/ClaudeLanguageModel/SchemaProbe.swift ]; then \
	  step "fm probe compile" swiftc spikes/ClaudeLanguageModel/SchemaProbe.swift -o "$$probe"; \
	  step "fm probe run"     "$$probe"; \
	fi

.PHONY: all cli helper clean betacheck
