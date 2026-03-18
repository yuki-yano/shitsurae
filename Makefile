.PHONY: icons build test app release-asset bump-version

CONFIGURATION ?= release

icons:
	./Scripts/generate-icons.sh

build:
	swift build

test:
	swift test

app: icons
	CONFIGURATION=$(CONFIGURATION) ./Scripts/build-app-bundle.sh

release-asset:
	./Scripts/create-release-asset.sh

bump-version:
	@test -n "$(KIND)" || (echo "usage: make bump-version KIND={patch|minor|major}" >&2; exit 1)
	./Scripts/bump-version.sh "$(KIND)"
