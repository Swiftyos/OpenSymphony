.PHONY: help all setup deps build fmt fmt-check lint test coverage ci dialyzer e2e secrets images

MIX ?= mix
CONTAINER_ENGINE ?= $(shell command -v podman >/dev/null 2>&1 && echo podman || echo docker)
IMAGE_REVISION ?= $(shell git -C .. rev-parse --short HEAD 2>/dev/null || echo unknown)

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, secrets, images, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

# The whole history and working tree, with the repo's rules (../.gitleaks.toml).
secrets:
	gitleaks git --redact --config ../.gitleaks.toml ..

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci

# Builds from the repository root, so both images' build contexts are explicit.
images:
	cd .. && $(CONTAINER_ENGINE) build \
		-f elixir/images/symphony/Containerfile \
		--build-arg REVISION=$(IMAGE_REVISION) \
		-t symphony:dev .
	cd .. && $(CONTAINER_ENGINE) build \
		-f elixir/images/agent-tools/Containerfile \
		--build-arg REVISION=$(IMAGE_REVISION) \
		-t symphony-agent-tools:dev .
