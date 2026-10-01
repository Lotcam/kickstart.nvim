-- Toggle GDScript breakpoints from nvim, run the Godot project so it stops on
-- them (via Godot's local stdout debugger), jump to the current line in your
-- source window as you step, and drive the whole session with keymaps
-- instead of typing into the terminal.
--
-- Note: Godot's `-b/--breakpoints` CLI flag does NOT actually break in the
-- local (non-remote) debugger (verified empirically against this project's
-- Godot 4.6 build). What DOES work is the literal `breakpoint` GDScript
-- statement combined with `-d/--debug`, so "toggling a breakpoint" inserts
-- a real `breakpoint` line (saved to disk) instead of just marking a sign.

local M = {}

local sign_group = 'GodotBreakpoints'
local sign_name = 'GodotBreakpoint'
local bp_ns = vim.api.nvim_create_namespace 'godot_breakpoints'
local line_ns = vim.api.nvim_create_namespace 'godot_current_line'

-- marks[bufnr] = { [extmark_id] = true }  -- each extmark sits on an inserted "breakpoint" line
local marks = {}

-- state of the currently running debug session (one at a time)
local session = {
  root = nil, -- project root of the running session
  source_win = nil, -- window to jump to on each step/break
  term_buf = nil,
  term_job = nil,
  current_line_buf = nil, -- buffer holding the "current line" extmark
  current_line_id = nil,
}

vim.fn.sign_define(sign_name, { text = '●', texthl = 'DiagnosticSignError' })

local function project_root(bufnr)
  local file = vim.api.nvim_buf_get_name(bufnr)
  local found = vim.fs.find('project.godot', { upward = true, path = vim.fs.dirname(file) })[1]
  return found and vim.fs.dirname(found) or nil
end

-- Find an existing breakpoint extmark sitting exactly on `line` (0-indexed), if any.
local function find_mark_at(bufnr, line)
  for id, _ in pairs(marks[bufnr] or {}) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, bp_ns, id, {})
    if pos[1] and pos[1] == line then return id end
  end
  return nil
end

function M.toggle_breakpoint()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-indexed
  marks[bufnr] = marks[bufnr] or {}

  local existing = find_mark_at(bufnr, cursor_line)
  if existing then
    vim.api.nvim_buf_del_extmark(bufnr, bp_ns, existing)
    vim.fn.sign_unplace(sign_group, { buffer = bufnr, id = existing })
    vim.api.nvim_buf_set_lines(bufnr, cursor_line, cursor_line + 1, false, {})
    marks[bufnr][existing] = nil
  else
    local text = vim.api.nvim_buf_get_lines(bufnr, cursor_line, cursor_line + 1, false)[1] or ''
    local indent = text:match '^%s*' or ''
    vim.api.nvim_buf_set_lines(bufnr, cursor_line, cursor_line, false, { indent .. 'breakpoint' })
    local id = vim.api.nvim_buf_set_extmark(bufnr, bp_ns, cursor_line, 0, {})
    marks[bufnr][id] = true
    vim.fn.sign_place(id, sign_group, sign_name, bufnr, { lnum = cursor_line + 1 })
  end

  vim.cmd 'silent! write'
end

function M.clear_breakpoints()
  for bufnr, ids in pairs(marks) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      -- delete from bottom to top so earlier line numbers stay valid
      local lines = {}
      for id, _ in pairs(ids) do
        local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, bp_ns, id, {})
        if pos[1] then table.insert(lines, pos[1]) end
      end
      table.sort(lines, function(a, b) return a > b end)
      for _, line in ipairs(lines) do
        vim.api.nvim_buf_set_lines(bufnr, line, line + 1, false, {})
      end
      vim.fn.sign_unplace(sign_group, { buffer = bufnr })
      vim.api.nvim_buf_call(bufnr, function() vim.cmd 'silent! write' end)
    end
  end
  marks = {}
  vim.notify('Godot breakpoints cleared', vim.log.levels.INFO)
end

local function clear_current_line()
  if session.current_line_buf and vim.api.nvim_buf_is_valid(session.current_line_buf) then
    vim.api.nvim_buf_del_extmark(session.current_line_buf, line_ns, session.current_line_id)
  end
  session.current_line_buf = nil
  session.current_line_id = nil
end

-- Called (deferred) whenever the terminal prints "*Frame 0 - res://X:N in function ..."
local function jump_to(res_path, line)
  if not session.root then return end
  local rel = res_path:sub(#'res://' + 1)
  local abs = session.root .. '/' .. rel
  if vim.fn.filereadable(abs) == 0 then return end

  clear_current_line()

  if not (session.source_win and vim.api.nvim_win_is_valid(session.source_win)) then
    -- terminal window took over / source window got closed: split one open
    vim.cmd 'topleft vsplit'
    session.source_win = vim.api.nvim_get_current_win()
  end

  vim.api.nvim_win_call(session.source_win, function()
    vim.cmd('edit ' .. vim.fn.fnameescape(abs))
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    vim.cmd 'normal! zz'
    local buf = vim.api.nvim_get_current_buf()
    session.current_line_buf = buf
    session.current_line_id = vim.api.nvim_buf_set_extmark(buf, line_ns, line - 1, 0, {
      line_hl_group = 'Visual',
      sign_text = '▶',
      sign_hl_group = 'DiagnosticSignWarn',
    })
  end)
end

function M.run()
  local root = project_root(vim.api.nvim_get_current_buf())
  if not root then
    vim.notify('Not inside a Godot project (no project.godot found upward)', vim.log.levels.ERROR)
    return
  end

  session.root = root
  session.source_win = vim.api.nvim_get_current_win()
  clear_current_line()

  local godot_exe = vim.g.godot_executable or (vim.fn.executable 'godot' == 1 and 'godot' or '/Applications/Godot.app/Contents/MacOS/Godot')
  local cmd = { godot_exe, '--path', root, '-d' }

  vim.cmd 'botright 15split'
  vim.cmd 'enew'
  local bufnr = vim.api.nvim_get_current_buf()
  session.term_buf = bufnr

  session.term_job = vim.fn.termopen(cmd, {
    on_exit = function()
      session.term_job = nil
      clear_current_line()
    end,
  })

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, buf, _, firstline, _, new_lastline)
      if not vim.api.nvim_buf_is_valid(buf) then return true end
      local lines = vim.api.nvim_buf_get_lines(buf, firstline, new_lastline, false)
      for _, l in ipairs(lines) do
        local path, lnum = l:match '%*Frame 0 %- (res://[^:]+):(%d+)'
        if path then
          local p, n = path, tonumber(lnum)
          vim.schedule(function() jump_to(p, n) end)
        end
      end
    end,
  })

  vim.cmd 'startinsert'
end

-- Send a raw command line to the running debugger's stdin.
function M.send(text)
  if not session.term_job then
    vim.notify('No active Godot debug session (run <leader>dr first)', vim.log.levels.WARN)
    return
  end
  vim.fn.chansend(session.term_job, text .. '\n')
end

function M.continue() M.send 'c' end
function M.next() M.send 'n' end
function M.step_into() M.send 's' end
function M.step_out() M.send 'fin' end
function M.locals() M.send 'lv' end
function M.members() M.send 'mv' end
function M.globals() M.send 'gv' end
function M.backtrace() M.send 'bt' end
function M.quit_game() M.send 'q' end

function M.print_expr()
  vim.ui.input({ prompt = 'Godot debug > p ' }, function(expr)
    if expr and #expr > 0 then M.send('p ' .. expr) end
  end)
end

function M.setup()
  vim.api.nvim_create_autocmd('FileType', {
    pattern = 'gdscript',
    group = vim.api.nvim_create_augroup('godot-debug', { clear = true }),
    callback = function(args)
      local function map(lhs, fn, desc) vim.keymap.set('n', lhs, fn, { buffer = args.buf, silent = true, desc = desc }) end

      map('<leader>db', M.toggle_breakpoint, 'Toggle breakpoint')
      map('<leader>dB', M.clear_breakpoints, 'Clear all breakpoints')
      map('<leader>dr', M.run, 'Run project (stop on breakpoints)')

      map('<leader>dc', M.continue, 'Continue')
      map('<leader>dn', M.next, 'Next line (step over)')
      map('<leader>di', M.step_into, 'Step into')
      map('<leader>do', M.step_out, 'Step out (finish)')

      map('<leader>dl', M.locals, 'Show locals')
      map('<leader>dm', M.members, 'Show members (self)')
      map('<leader>dg', M.globals, 'Show globals')
      map('<leader>dt', M.backtrace, 'Backtrace')
      map('<leader>dp', M.print_expr, 'Print expression')
      map('<leader>dq', M.quit_game, 'Quit running game')
    end,
  })

  -- Safety net: never let a `breakpoint` statement accidentally get left in
  -- the source when leaving nvim.
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('godot-debug-cleanup', { clear = true }),
    callback = function()
      if next(marks) then M.clear_breakpoints() end
    end,
  })
end

return M
