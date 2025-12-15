local M = {}

-- module-local state: state[bufnr] = { pattern = <escaped>, text = <raw>, pending = bool, captured = bool }
local state = {}

local function ensure_buf_state(bufnr)
	state[bufnr] = state[bufnr] or {}

	return state[bufnr]
end

local function escape_literal(s)
	if not s or s == "" then
		return nil
	end

	local ok = s:gsub("\\", "\\\\")
	ok = ok:gsub("\n", "\\n")

	return "\\V" .. ok
end

local function do_capture(bufnr, deleted)
	if not deleted or deleted == "" then
		return false
	end

	local pat = escape_literal(deleted)
	if not pat then
		return false
	end

	local s = ensure_buf_state(bufnr)
	s.pattern = pat
	s.text = deleted
	s.captured = true
	s.pending = nil
	local shown = deleted:gsub("\n", "\\n")

	return true
end

local function on_text_yank_post(ev)
	local bufnr = vim.api.nvim_get_current_buf()

	local s = state[bufnr]
	if not s or not s.pending or s.captured then
		return
	end

	ev = ev or vim.v.event
	if not ev or not ev.regcontents or #ev.regcontents == 0 then
		return
	end

	local deleted = table.concat(ev.regcontents, "\n")
	do_capture(bufnr, deleted)
end

local function capture_from_register()
	local bufnr = vim.api.nvim_get_current_buf()

	local s = state[bufnr]
	if not s or not s.pending or s.captured then
		return
	end

	local deleted = vim.fn.getreg('"') or ""
	if deleted == "" then
		deleted = vim.fn.getreg("1") or ""
	end

	do_capture(bufnr, deleted)
end

local function find_next_literal(bufnr, text)
	local cur = vim.api.nvim_win_get_cursor(0)
	local start_line = cur[1]
	local start_col = cur[2] + 1
	local nlines = vim.api.nvim_buf_line_count(bufnr)

	for l = start_line, nlines do
		local line = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1] or ""
		local s_col = 1
		if l == start_line then
			s_col = start_col + 1
		end

		local found = string.find(line, text, s_col, true)
		if found then
			vim.api.nvim_win_set_cursor(0, { l, found - 1 })
			return true
		end
	end
	for l = 1, start_line - 1 do
		local line = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1] or ""

		local found = string.find(line, text, 1, true)
		if found then
			vim.api.nvim_win_set_cursor(0, { l, found - 1 })
			return true
		end
	end
	return false
end

function M.repeat_next()
	local bufnr = vim.api.nvim_get_current_buf()

	local entry = state[bufnr]
	if not entry or not entry.text then
		return
	end

	local shown = (entry.text or ""):gsub("\n", "\\n")

	local ok = false
	if not entry.text:find("\n") then
		ok = find_next_literal(bufnr, entry.text)
	else
		local pat = entry.pattern
		if not pat then
			return
		end
		ok = (vim.fn.search(pat, "W") ~= 0)
	end

	if not ok then
		return
	end

	vim.cmd("normal! .")
end

function M.setup(opts)
	opts = opts or {}
	local key = opts.keymap or "<leader>n"
	local ops = opts.operators or { "c", "s", "C" }

	-- primary capture: TextYankPost (yank/delete)
	vim.api.nvim_create_autocmd("TextYankPost", {
		callback = function(ev)
			vim.schedule(function()
				on_text_yank_post(ev)
			end)
		end,
	})

	-- fallbacks: sometimes register population/order differs
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
		callback = function()
			vim.schedule(capture_from_register)
		end,
	})

	-- cleanup state on buffer unload
	vim.api.nvim_create_autocmd("BufUnload", {
		callback = function(args)
			state[tonumber(args.buf)] = nil
		end,
	})

	-- remap operators once
	for _, op in ipairs(ops) do
		vim.keymap.set("n", op, function()
			local bufnr = vim.api.nvim_get_current_buf()
			local s = ensure_buf_state(bufnr)
			s.pending = true
			s.captured = false
			s.pending_op = op
			return op
		end, { expr = true, noremap = true, silent = true })

		vim.keymap.set("v", op, function()
			local bufnr = vim.api.nvim_get_current_buf()
			local s = ensure_buf_state(bufnr)
			s.pending = true
			s.captured = false
			s.pending_op = op
			return op
		end, { expr = true, noremap = true, silent = true })
	end

	vim.keymap.set("n", key, function()
		M.repeat_next()
	end, { noremap = true, silent = true })

	vim.api.nvim_create_user_command("RepeatLastChangeNext", function()
		M.repeat_next()
	end, {})
end

return M
