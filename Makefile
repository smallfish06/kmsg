# kmsg convenience targets.
# Building still uses `swift build` directly (see CLAUDE.md); these wrap the
# Headatever version bump script (head.yymmdd.patch). See VERSIONING.md.

BUMP := scripts/headatever.sh

.PHONY: version release release-major release-push

version: ## Print the current version
	@$(BUMP) show

release: ## Patch release: bump VERSION, commit, tag v<version>
	@$(BUMP) patch

release-major: ## Head release: head+1, date=today, patch=0
	@$(BUMP) major

release-push: ## Patch release, then push commit + tag (triggers release workflow)
	@$(BUMP) patch --push
