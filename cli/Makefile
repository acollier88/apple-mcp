RELEASE_DIR = .build/release
# Build provenance (#33): the commit is written to a file under .build/ (never
# the tracked tree) and linked into __TEXT,__at_build; BuildInfo.swift reads
# it back for `apple-tasks --version` and doctor. The commit is part of the
# file name so a new HEAD changes the link line and forces a relink.
STAMP_DIR = $(CURDIR)/.build/stamp

.PHONY: all cli helper clean test

all: cli helper

cli:
	@mkdir -p "$(STAMP_DIR)"
	@commit=$$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown); \
	if [ "$$commit" != unknown ] && [ -n "$$(git status --porcelain -- . 2>/dev/null)" ]; then \
	  commit="$$commit-dirty"; \
	fi; \
	stamp="$(STAMP_DIR)/build-$$commit.txt"; \
	printf 'commit=%s\nsource=%s\n' "$$commit" "$$(git rev-parse --show-toplevel 2>/dev/null)" > "$$stamp"; \
	echo "build stamp: commit $$commit"; \
	swift build -c release \
	  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __at_build -Xlinker "$$stamp"

# Private ReminderKit helper for native tag mirroring. Optional: the CLI
# works without it ([tag] prefixes remain the source of truth).
helper: cli
	clang -fobjc-arc -O -framework Foundation \
		-o $(RELEASE_DIR)/apple-tasks-private Sources/private-helper/apple-tasks-private.m

test:
	swift test

clean:
	swift package clean
