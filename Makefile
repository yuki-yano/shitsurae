.PHONY: icons build test app

CONFIGURATION ?= release

icons:
	./Scripts/generate-icons.sh

build:
	swift build

test:
	swift test

app:
	CONFIGURATION=$(CONFIGURATION) ./Scripts/build-app-bundle.sh
