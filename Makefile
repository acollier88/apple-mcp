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

.PHONY: all cli helper clean
