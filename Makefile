.PHONY: build release test check ui-check demo run
build:
	bash scripts/build.sh debug
release:
	bash scripts/build.sh release
test:
	swift run ClipDuneChecks
check:
	bash scripts/check.sh
ui-check:
	bash scripts/check-ui.sh
demo:
	swift run ClipDune --demo
run:
	swift run ClipDune
