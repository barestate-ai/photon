SWIFT_TESTING_PLUGINS = /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
SWIFT_SOURCES = Package.swift Sources/Barestate Sources/BarestateCore Sources/barestate-mcp \
	Sources/barestate-gateway Tests

.PHONY: vendor build bundle test lint check check-agpl atom atom-archive e2e bench dmg dist clean

vendor:
	scripts/fetch-cef.sh

build: vendor
	swift build -c release

bundle: build
	scripts/bundle.sh

test: vendor
	swift test -c release -Xswiftc -plugin-path -Xswiftc $(SWIFT_TESTING_PLUGINS)
	@if ps -axo pid,command | grep -F "$(CURDIR)/.build" | grep '[f]ake_atom.py'; then \
		echo "test: a fake Atom runtime was left running (pids above)"; exit 1; fi

lint:
	swift format lint --strict --recursive $(SWIFT_SOURCES)
	@for f in scripts/*.sh; do bash -n "$$f" || exit 1; done
	@python3 -c "import ast,sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]" e2e/*.py scripts/*.py fixtures/server.py
	@echo "lint: ok"

# The pattern is split so this file does not match its own search.
check-agpl:
	@if git grep -il "GNU AFFE""RO" -- . >/dev/null; then echo "check-agpl: AGPL text is tracked"; exit 1; fi
	@if grep -q '\.package(' Package.swift; then echo "check-agpl: Package.swift has a package dependency"; exit 1; fi
	@echo "check-agpl: ok"

check: build test
	scripts/check-secrets.sh
	$(MAKE) --no-print-directory check-agpl lint

atom:
	scripts/setup-atom.sh all

atom-archive:
	scripts/setup-atom.sh pack

e2e: bundle
	python3 e2e/run.py < /dev/null

bench:
	@test -f scripts/bench.py || { echo "bench: scripts/bench.py does not exist yet"; exit 1; }
	python3 scripts/bench.py

dmg: bundle
	scripts/dmg.sh

dist:
	@test -f scripts/release.sh || { echo "dist: scripts/release.sh does not exist yet"; exit 1; }
	scripts/release.sh

clean:
	rm -rf .build dist
