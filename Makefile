PREFIX ?= /usr/local
# Set SUDO= (empty) with a user-writable PREFIX for a sudo-free install,
# e.g.: make install PREFIX=$$HOME/.local SUDO=
SUDO ?= sudo
AGENT = com.utw.upmixd
AGENT_PLIST = $(HOME)/Library/LaunchAgents/$(AGENT).plist

PANEL_AGENT = com.utw.upmix-panel
PANEL_AGENT_PLIST = $(HOME)/Library/LaunchAgents/$(PANEL_AGENT).plist
PANEL_APP = $(HOME)/Applications/UpmixPanel.app

.PHONY: build test install uninstall install-panel uninstall-panel

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

# The menu-bar panel is per-user: ~/Applications bundle + login agent, no sudo.
install-panel: build
	install -d $(PANEL_APP)/Contents/MacOS $(HOME)/Library/LaunchAgents
	install -m 644 dist/UpmixPanel-Info.plist $(PANEL_APP)/Contents/Info.plist
	install -m 755 .build/release/upmix-panel $(PANEL_APP)/Contents/MacOS/upmix-panel
	sed "s|__HOME__|$(HOME)|g" dist/$(PANEL_AGENT).plist > $(PANEL_AGENT_PLIST)
	-launchctl bootout gui/$$(id -u) $(PANEL_AGENT_PLIST) 2>/dev/null
	sleep 1
	launchctl bootstrap gui/$$(id -u) $(PANEL_AGENT_PLIST)

uninstall-panel:
	-launchctl bootout gui/$$(id -u) $(PANEL_AGENT_PLIST) 2>/dev/null
	rm -f $(PANEL_AGENT_PLIST)
	rm -rf $(PANEL_APP)
