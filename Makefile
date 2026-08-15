PREFIX ?= /usr/local
# Set SUDO= (empty) with a user-writable PREFIX for a sudo-free install,
# e.g.: make install PREFIX=$$HOME/.local SUDO=
SUDO ?= sudo
AGENT = com.utw.upmixd
AGENT_PLIST = $(HOME)/Library/LaunchAgents/$(AGENT).plist

.PHONY: build test install uninstall

build:
	swift build -c release

test:
	swift test

install: build
	$(SUDO) install -d -m 755 $(PREFIX)/bin
	$(SUDO) install -m 755 .build/release/upmixd $(PREFIX)/bin/upmixd
	install -d $(HOME)/Library/LaunchAgents $(HOME)/Library/Logs
	sed -e "s|__HOME__|$(HOME)|g" -e "s|__PREFIX__|$(PREFIX)|g" dist/$(AGENT).plist > $(AGENT_PLIST)
	-launchctl bootout gui/$$(id -u) $(AGENT_PLIST) 2>/dev/null
	sleep 1
	launchctl bootstrap gui/$$(id -u) $(AGENT_PLIST)

uninstall:
	-launchctl bootout gui/$$(id -u) $(AGENT_PLIST) 2>/dev/null
	rm -f $(AGENT_PLIST)
	$(SUDO) rm -f $(PREFIX)/bin/upmixd
