PLENARY ?= $(shell ls -d $(HOME)/.local/share/nvim/lazy/plenary.nvim 2>/dev/null || echo .deps/plenary.nvim)

.PHONY: test preview lint fmt deps docs

test: ## run the busted specs
	@PLENARY_DIR=$(PLENARY) nvim --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/tuleap { minimal_init = 'tests/minimal_init.lua' }"

preview: ## render every view against canned payloads
	@nvim --headless -u NONE -l tests/preview.lua $(VIEW)

lint: ## luacheck + stylua, when installed
	@command -v luacheck >/dev/null && luacheck lua plugin tests || echo "luacheck not installed, skipped"
	@command -v stylua   >/dev/null && stylua --check lua plugin tests || echo "stylua not installed, skipped"

fmt: ## format with stylua
	@stylua lua plugin tests

docs: ## regenerate the help tags
	@nvim --headless -c "helptags doc" -c "qa"

deps: ## fetch plenary locally (for CI or a bare checkout)
	@mkdir -p .deps
	@test -d .deps/plenary.nvim || git clone --depth 1 https://github.com/nvim-lua/plenary.nvim .deps/plenary.nvim
