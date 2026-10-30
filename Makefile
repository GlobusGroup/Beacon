# Beacon — local domains and reserved ports for your projects.

DERIVED := $(CURDIR)/.xcode
APP     := $(DERIVED)/Build/Products/Release/Beacon.app
SANDBOX := /tmp/beacon-dev

.PHONY: all build app install uninstall reinstall restart dev dev-stop logs clean

all: build app

## Build the daemon and the CLI.
build:
	swift build -c release

## Build the menu bar app.
app:
	xcodebuild -project Beacon.xcodeproj -scheme Beacon -configuration Release \
		-derivedDataPath $(DERIVED) build | tail -3
	@echo "Built $(APP)"

## Install the background service, the CLI and the DNS resolvers. Asks for your password.
install: build
	sudo .build/release/beacon install
	@echo
	@.build/release/beacon status

## Replace an installed service with a freshly built one.
reinstall: build
	sudo .build/release/beacon install

uninstall:
	sudo .build/release/beacon uninstall

restart:
	.build/release/beacon restart

## Run the whole stack on high ports against a throwaway registry.
## Nothing is installed and the real system is untouched.
dev: build
	@mkdir -p $(SANDBOX)
	@echo "Registry: $(SANDBOX)   HTTP :8080   HTTPS :8443   DNS :15353"
	@echo "Drive it with:  BEACON_ROOT=$(SANDBOX) .build/release/beacon list"
	BEACON_ROOT=$(SANDBOX) .build/release/beacond run \
		--http-port 8080 --https-port 8443 --dns-port 15353 --verbose

dev-stop:
	-pkill -f 'beacond run --http-port 8080'

logs:
	tail -f /var/log/beacon.log

clean:
	swift package clean
	rm -rf $(DERIVED)
