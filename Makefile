PREFIX ?= /usr/local
AGENT = com.utw.upmixd
AGENT_PLIST = $(HOME)/Library/LaunchAgents/$(AGENT).plist

.PHONY: build test install uninstall

build:
	swift build -c release

test:
	swift test

install: build
	sudo install -m 755 .build/release/upmixd $(PREFIX)/bin/upmixd
	install -m 644 dist/$(AGENT).plist $(AGENT_PLIST)
	-launchctl bootout gui/$$(id -u) $(AGENT_PLIST) 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(AGENT_PLIST)

uninstall:
	-launchctl bootout gui/$$(id -u) $(AGENT_PLIST) 2>/dev/null
	rm -f $(AGENT_PLIST)
	sudo rm -f $(PREFIX)/bin/upmixd
