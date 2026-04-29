.PHONY: test test-file lint clean

test:
	@nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua', sequential = true }"

test-file:
	@nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "lua require('plenary.busted').run('$(realpath $(FILE))')"

clean:
	@rm -rf .testcache
