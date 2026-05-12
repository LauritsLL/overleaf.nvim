local config = require('overleaf.config')
local bridge = require('overleaf.bridge')
local project = require('overleaf.project')
local Document = require('overleaf.document')
local buffer = require('overleaf.buffer')
local sync = require('overleaf.sync')

local M = {}

--- Open a file with the configured viewer or platform default (only if not already open)
---@param file_path string
local function open_file(file_path)
  -- Check if okular is already running
  local pgrep_output = vim.fn.system('pgrep okular')
  local okular_running = (pgrep_output ~= '' and vim.v.shell_error == 0)
  config.log('debug', 'okular running check: output=%s error=%d', pgrep_output:gsub('\n', ''), vim.v.shell_error)

  if not okular_running then
    local viewer = config.get().pdf_viewer or 'okular'
    config.log('debug', 'Opening PDF with viewer: %s', viewer)
    vim.fn.jobstart({ viewer, file_path }, { detach = true })
  else
    config.log('debug', 'okular already running, skipping open')
  end
end

M._state = {
  connected = false,
  project_name = nil,
  project_id = nil,
  project_data = nil,
  csrf_token = nil,
  documents = {}, -- doc_id -> Document
  main_doc_id_override = nil, -- user-chosen main .tex doc id (session-only)
}

-- Latexmk job for the in-flight compile, if any. Two latexmk runs in the same
-- directory race over the intermediate files: with XeLaTeX the second run's
-- `xelatex -no-pdf` truncates main.xdv while the first run's `xdvipdfmx` is
-- still reading it (and both runs' xdvipdfmx write main.pdf at once), which
-- leaves a perfectly fine main.xdv but a corrupt, unopenable main.pdf. Larger
-- projects compile slowly enough for a second :w / :Overleaf compile to land
-- inside that window, so M.compile() refuses to start one while another runs.
M._compile_job = nil

function M.setup(opts)
  config.setup(opts)

  -- Set vimtex viewer defaults for okular + synctex if the user hasn't configured them.
  -- Okular's --unique flag reuses an existing window and supports forward/inverse search.
  -- For inverse search, configure okular's editor (Settings → Editor) to:
  --   nvim --headless -c "VimtexInverseSearch %l '%f'"
  vim.schedule(function()
    if vim.fn.executable('okular') == 1 then
      if not vim.g.vimtex_view_method then
        vim.g.vimtex_view_method = 'general'
      end
      if vim.g.vimtex_view_method == 'general' and not vim.g.vimtex_view_general_viewer then
        vim.g.vimtex_view_general_viewer = 'okular'
        vim.g.vimtex_view_general_options = '--unique file:@pdf\\#src:@line@tex'
      end
    end
  end)

  -- Default keymaps (prefix: <leader>o for Overleaf)
  local keys = opts and opts.keys or true
  if keys then
    local map = vim.keymap.set
    map('n', '<leader>oc', function() M.connect() end, { desc = 'Overleaf: Connect' })
    map('n', '<leader>od', function() M.disconnect() end, { desc = 'Overleaf: Disconnect' })
    map('n', '<leader>ob', function() M.compile() end, { desc = 'Overleaf: Build (compile)' })
    map('n', '<leader>ot', function() M.toggle_tree() end, { desc = 'Overleaf: Toggle tree' })
    map('n', '<leader>oo', function() M.select_document() end, { desc = 'Overleaf: Open document' })
    map('n', '<leader>op', function() M.preview_file() end, { desc = 'Overleaf: Preview file' })
    map('n', '<leader>or', function() M.show_comment() end, { desc = 'Overleaf: Read comment' })
    map('n', '<leader>oR', function() M.reply_comment() end, { desc = 'Overleaf: Reply to comment' })
    map('n', '<leader>ox', function() M.resolve_comment() end, { desc = 'Overleaf: Resolve/reopen comment' })
    map('n', '<leader>of', function() M.search() end, { desc = 'Overleaf: Find in project' })
    map('n', '<leader>om', function() M.set_main() end, { desc = 'Overleaf: Set main .tex file' })
  end
end

function M.connect()
  config.log('info', 'Starting bridge...')

  -- Step 1: Start bridge process
  bridge.start(function(err)
    if err then
      config.log('error', 'Failed to start bridge: %s', err.message)
      return
    end

    -- Step 2: Get cookie (from config, .env, or Chrome)
    M._get_cookie(function(cookie)
      if not cookie then return end

      config.log('info', 'Authenticating...')

      -- Step 3: Authenticate and get project list
      bridge.request('auth', { cookie = cookie }, function(auth_err, result)
        if auth_err then
          config.log('error', 'Authentication failed: %s', auth_err.message)
          return
        end

        config.log('info', 'Authenticated as %s (%d projects)', result.userEmail or result.userId, #result.projects)
        M._state.csrf_token = result.csrfToken
        project.set_projects(result.projects)

        -- Step 4: Select project
        project.select_project(
          function(project_id, project_name) M._connect_project(cookie, project_id, project_name) end
        )
      end)
    end)
  end)
end

function M._get_cookie(callback)
  -- Chrome first, then config/env as fallback
  config.log('info', 'Checking Chrome profiles...')
  bridge.request('listChromeProfiles', {}, function(err, result)
    if err or not result or not result.profiles or #result.profiles == 0 then
      config.log('debug', 'Chrome profiles not available: %s', err and err.message or 'none found')
      M._get_cookie_fallback(callback)
      return
    end

    local profiles = result.profiles

    local function extract_from_profile(profile_dir)
      config.log('info', 'Extracting cookie from Chrome (%s)...', profile_dir)
      bridge.request('getCookie', { profile = profile_dir }, function(cookie_err, cookie_result)
        if not cookie_err and cookie_result and cookie_result.cookie then
          config.log('info', 'Cookie extracted from Chrome')
          config.get().cookie = cookie_result.cookie
          callback(cookie_result.cookie)
          return
        end
        config.log('debug', 'Chrome extraction failed: %s', cookie_err and cookie_err.message or 'unknown')
        M._get_cookie_fallback(callback)
      end)
    end

    if #profiles == 1 then
      extract_from_profile(profiles[1].dir)
    else
      vim.schedule(function()
        vim.ui.select(profiles, {
          prompt = 'Select Chrome Profile:',
          format_item = function(item) return item.name .. ' (' .. item.dir .. ')' end,
        }, function(choice)
          if choice then
            extract_from_profile(choice.dir)
          else
            M._get_cookie_fallback(callback)
          end
        end)
      end)
    end
  end)
end

function M._get_cookie_fallback(callback)
  local cookie = config.load_cookie()
  if cookie then
    callback(cookie)
    return
  end
  config.log('error', 'No cookie found. Log in to overleaf.com in Chrome, or set OVERLEAF_COOKIE in .env')
  callback(nil)
end

function M._connect_project(cookie, project_id, project_name)
  config.log('info', 'Connecting to project: %s', project_name)

  -- Register event handlers before connecting
  M._setup_event_handlers()

  -- Set up bridge auto-restart on unexpected exit
  bridge._on_unexpected_exit = function(code)
    config.log('warn', 'Bridge process died (code %d), attempting reconnect...', code)
    M._state.connected = false
    M._reconnect.attempt = 0
    M._attempt_reconnect()
  end

  bridge.request('connect', {
    cookie = cookie,
    projectId = project_id,
  }, function(err, result)
    if err then
      config.log('error', 'Failed to connect: %s', err.message)
      return
    end

    M._state.connected = true
    M._state.project_id = project_id
    M._state.project_name = project_name
    M._state.project_data = result.project

    -- Parse project tree
    project.parse_project_tree(result.project)

    config.log('info', 'Connected to: %s', project_name)

    -- Load comment threads
    require('overleaf.comments').load_threads(project_id)

    -- Start file sync (if sync_dir configured)
    sync.start(project_name)
    sync.sync_all(M._state, project._project_tree)

    -- Show tree immediately
    vim.schedule(function() require('overleaf.tree').toggle() end)
  end)
end

function M._setup_event_handlers()
  bridge.on_event('otUpdateApplied', function(data)
    -- Skip own-ACK events (no op field = acknowledgment for our own op)
    -- Our ACK is already handled by the applyOtUpdate callback → _on_ack()
    if not data.op then return end

    local doc = M._state.documents[data.doc]
    if doc then
      doc:on_remote_op(data, function(transformed_ops)
        buffer.apply_remote(doc, transformed_ops)
        sync.schedule_write(doc)
      end)
    end
  end)

  bridge.on_event('otUpdateError', function(data)
    config.log('debug', 'OT Error for doc %s: %s', data.doc or '?', data.message or '?')
    -- Only rejoin if connected (disconnect handler handles reconnect separately)
    if M._state.connected then
      local doc = M._state.documents[data.doc]
      if doc and not doc._rejoining then doc:rejoin() end
    end
  end)

  bridge.on_event('disconnect', function(data)
    if M._state.connected then config.log('warn', 'Disconnected: %s — reconnecting...', data.reason or 'unknown') end
    M._state.connected = false
    M._attempt_reconnect()
  end)

  -- File tree events
  bridge.on_event('reciveNewDoc', function(data)
    if not data or not data.doc then return end
    local doc_info = data.doc
    local meta = data.meta or {}
    local new_id = doc_info._id or doc_info.id

    -- File-restore: remap old doc to new ID and rejoin
    if meta.kind == 'file-restore' then
      local old_id = M._pending_restore and M._pending_restore[meta.path or '']
      if old_id then
        M._pending_restore[meta.path] = nil
        config.log('info', 'File restore: remapping %s -> %s (%s)', old_id, new_id, meta.path or '?')

        -- Update tree entry ID
        project.update_entry_id(old_id, new_id)

        -- Remap open document to new ID
        local old_doc = M._state.documents[old_id]
        if old_doc then
          M._state.documents[old_id] = nil
          M._state.documents[new_id] = old_doc
          old_doc.doc_id = new_id
          old_doc.joined = false
          old_doc.inflight_op = nil
          old_doc.pending_ops = nil
          if old_doc._flush_timer then
            vim.fn.timer_stop(old_doc._flush_timer)
            old_doc._flush_timer = nil
          end

          -- Immediately join the new doc (server already has it ready)
          bridge.request('joinDoc', { docId = new_id }, function(err, result)
            if err then
              config.log('error', 'Failed to join restored doc %s: %s', meta.path or '?', err.message)
              return
            end

            local content = table.concat(result.lines, '\n')
            old_doc.version = result.version
            old_doc.content = content
            old_doc.server_content = content
            old_doc.joined = true
            old_doc._rejoining = false
            old_doc.ranges = result.ranges

            config.log('info', 'Restored doc %s (v%d)', meta.path or '?', result.version)

            -- Update buffer with new content
            if old_doc.bufnr and vim.api.nvim_buf_is_valid(old_doc.bufnr) then
              vim.schedule(function()
                old_doc.applying_remote = true
                vim.api.nvim_buf_set_lines(old_doc.bufnr, 0, -1, false, result.lines)
                vim.bo[old_doc.bufnr].modified = false
                old_doc.applying_remote = false

                -- Re-render comments if available
                if result.ranges then
                  local comments = require('overleaf.comments')
                  comments.parse_ranges(new_id, result.ranges)
                  comments.render(old_doc.bufnr, new_id, old_doc.content)
                end
              end)
            end
          end)
        end
      end

      vim.schedule(function() require('overleaf.tree').refresh() end)
      return
    end

    -- Normal new doc (not restore)
    local parent_path = project.get_folder_path(data.parentFolderId)
    local path = parent_path .. (doc_info.name or '')
    if not project.path_exists(path) then
      local depth = 0
      if data.parentFolderId then
        for _, e in ipairs(project._project_tree) do
          if e.id == data.parentFolderId then
            depth = (e.depth or 0) + 1
            break
          end
        end
      end
      project.add_entry({
        id = new_id,
        name = doc_info.name,
        path = path,
        type = 'doc',
        depth = depth,
      })
    end
    vim.schedule(function() require('overleaf.tree').refresh() end)
  end)

  bridge.on_event('reciveNewFile', function(data)
    if not data or not data.file then return end
    local file = data.file
    local parent_path = project.get_folder_path(data.parentFolderId)
    local path = parent_path .. (file.name or '')
    if not project.path_exists(path) then
      local depth = 0
      if data.parentFolderId then
        for _, e in ipairs(project._project_tree) do
          if e.id == data.parentFolderId then
            depth = (e.depth or 0) + 1
            break
          end
        end
      end
      project.add_entry({
        id = file._id or file.id,
        name = file.name,
        path = path,
        type = 'file',
        depth = depth,
      })
    end
    vim.schedule(function() require('overleaf.tree').refresh() end)
  end)

  bridge.on_event('removeEntity', function(data)
    if not data or not data.entityId then return end
    local meta = data.meta or {}

    -- For file-restore, don't remove the entry — reciveNewDoc will remap it
    if meta.kind == 'file-restore' then
      config.log('debug', 'File restore: old doc %s will be replaced', data.entityId)
      M._pending_restore = M._pending_restore or {}
      M._pending_restore[meta.path or ''] = data.entityId
      return
    end

    project.remove_entry(data.entityId)
    vim.schedule(function() require('overleaf.tree').refresh() end)
  end)

  -- Comment events
  local function rerender_comments()
    local comments = require('overleaf.comments')
    for doc_id, doc in pairs(M._state.documents) do
      if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) and doc.content then
        comments.render(doc.bufnr, doc_id, doc.content)
      end
    end
  end

  bridge.on_event('newComment', function(data)
    vim.schedule(function()
      require('overleaf.comments').on_new_comment(data)
      rerender_comments()
    end)
  end)

  bridge.on_event('resolveThread', function(data)
    vim.schedule(function()
      require('overleaf.comments').on_resolve_thread(data)
      rerender_comments()
    end)
  end)

  bridge.on_event('reopenThread', function(data)
    vim.schedule(function()
      require('overleaf.comments').on_reopen_thread(data)
      rerender_comments()
    end)
  end)

  bridge.on_event('deleteThread', function(data)
    vim.schedule(function()
      require('overleaf.comments').on_delete_thread(data)
      rerender_comments()
    end)
  end)

  -- Collaborator cursor tracking
  bridge.on_event('clientUpdated', function(data)
    vim.schedule(function() require('overleaf.cursors').on_client_updated(data) end)
  end)

  bridge.on_event('clientDisconnected', function(data)
    vim.schedule(function() require('overleaf.cursors').on_client_disconnected(data) end)
  end)
end

-- Auto-reconnect state
M._reconnect = {
  attempt = 0,
  max_attempts = 5,
  timer = nil,
  in_progress = false,
}

function M._attempt_reconnect()
  if M._reconnect.in_progress then return end
  if M._state.connected then return end
  if not M._state.project_id then return end -- never connected

  M._reconnect.attempt = M._reconnect.attempt + 1
  if M._reconnect.attempt > M._reconnect.max_attempts then
    config.log('error', 'Reconnect failed after %d attempts', M._reconnect.max_attempts)
    M._reconnect.attempt = 0
    return
  end

  -- Exponential backoff: 2s, 4s, 8s, 16s, 30s
  local delay = math.min(2000 * (2 ^ (M._reconnect.attempt - 1)), 30000)
  config.log(
    'debug',
    'Reconnecting in %ds (attempt %d/%d)...',
    delay / 1000,
    M._reconnect.attempt,
    M._reconnect.max_attempts
  )

  M._reconnect.in_progress = true

  if M._reconnect.timer then vim.fn.timer_stop(M._reconnect.timer) end

  M._reconnect.timer = vim.fn.timer_start(delay, function()
    M._reconnect.timer = nil
    M._do_reconnect()
  end)
end

function M._do_reconnect()
  local cookie = config.get().cookie
  if not cookie then
    config.log('error', 'No cookie available for reconnect')
    M._reconnect.in_progress = false
    return
  end

  -- Ensure bridge is running
  if not bridge.is_running() then
    bridge.start(function(err)
      if err then
        config.log('error', 'Failed to restart bridge: %s', err.message)
        M._reconnect.in_progress = false
        M._attempt_reconnect()
        return
      end
      M._setup_event_handlers()
      M._reconnect_to_project(cookie)
    end)
  else
    M._reconnect_to_project(cookie)
  end
end

function M._reconnect_to_project(cookie)
  bridge.request('connect', {
    cookie = cookie,
    projectId = M._state.project_id,
  }, function(err, result)
    M._reconnect.in_progress = false

    if err then
      config.log('debug', 'Reconnect failed: %s', err.message)
      M._attempt_reconnect()
      return
    end

    M._state.connected = true
    M._state.project_data = result.project
    M._reconnect.attempt = 0

    config.log('info', 'Reconnected to: %s', M._state.project_name or '?')

    -- Re-join all open documents (wait for server to settle after restore)
    vim.defer_fn(function() M._rejoin_documents() end, 3000)
  end)
end

function M._rejoin_documents()
  for _, doc in pairs(M._state.documents) do
    if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then
      -- Reset all state for clean rejoin
      doc._rejoining = false
      doc.joined = false
      doc.inflight_op = nil
      doc.pending_ops = nil
      if doc._flush_timer then
        vim.fn.timer_stop(doc._flush_timer)
        doc._flush_timer = nil
      end
      doc:rejoin()
    end
  end
end

function M.open_document(doc_id_or_path, doc_path)
  local doc_id = doc_id_or_path
  local path = doc_path

  if not path then
    -- Assume it's a path, look up ID
    local info = project.get_doc_by_path(doc_id_or_path)
    if info then
      doc_id = info.id
      path = info.path
    else
      config.log('error', 'Document not found: %s', doc_id_or_path)
      return
    end
  end

  -- Check if already open
  if M._state.documents[doc_id] then
    local existing = M._state.documents[doc_id]
    if existing.bufnr and vim.api.nvim_buf_is_valid(existing.bufnr) then
      vim.api.nvim_set_current_buf(existing.bufnr)
      return
    end
  end

  local doc = Document.new(doc_id, path)
  M._state.documents[doc_id] = doc

  doc:join(function(err, lines, ranges)
    if err then
      M._state.documents[doc_id] = nil
      return
    end

    buffer.create(doc, lines)

    -- Write to sync dir and start watching for external changes
    sync.write_doc(doc)
    sync.watch(doc)

    -- Parse and render comments if ranges contain comments
    if ranges then
      local comments = require('overleaf.comments')
      comments.parse_ranges(doc_id, ranges)
      vim.schedule(function()
        if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then comments.render(doc.bufnr, doc_id, doc.content) end
      end)
    end
  end)
end

function M.select_project()
  if #project._projects == 0 then
    config.log('warn', 'Not authenticated. Run :OverleafConnect first.')
    return
  end

  project.select_project(function(project_id, project_name)
    local cookie = config.get().cookie
    M._connect_project(cookie, project_id, project_name)
  end)
end

function M.select_document()
  if not M._state.connected then
    config.log('warn', 'Not connected. Run :OverleafConnect first.')
    return
  end

  project.select_document(function(doc_id, doc_path) M.open_document(doc_id, doc_path) end)
end

function M.toggle_tree()
  if not M._state.connected then
    config.log('warn', 'Not connected. Run :OverleafConnect first.')
    return
  end
  require('overleaf.tree').toggle()
end

function M.preview_file()
  if not M._state.connected then
    config.log('warn', 'Not connected. Run :Overleaf connect first.')
    return
  end

  -- Get file entries from project tree
  local files = {}
  for _, entry in ipairs(project._project_tree) do
    if entry.type == 'file' then table.insert(files, entry) end
  end

  if #files == 0 then
    config.log('info', 'No binary files in project')
    return
  end

  vim.ui.select(files, {
    prompt = 'Preview file:',
    format_item = function(item) return item.path end,
  }, function(choice)
    if not choice then return end

    config.log('info', 'Downloading %s...', choice.name)
    bridge.request('downloadFile', {
      cookie = config.get().cookie,
      projectId = M._state.project_id,
      fileId = choice.id,
      fileName = choice.name,
      outputDir = config.get().pdf_dir,
    }, function(err, result)
      if err then
        config.log('error', 'Download failed: %s', err.message)
        return
      end
      config.log('info', 'Opening %s', result.path)
      vim.schedule(function() open_file(result.path) end)
    end)
  end)
end

function M.create_doc(name, parent_folder_id)
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end

  local prefix = project.get_folder_path(parent_folder_id)

  local function do_create(doc_name)
    if not doc_name or doc_name == '' then return end

    local full_path = prefix .. doc_name
    if project.path_exists(full_path) then
      config.log('error', 'File already exists: %s', full_path)
      return
    end

    bridge.request('createDoc', {
      cookie = config.get().cookie,
      csrfToken = M._state.csrf_token,
      projectId = M._state.project_id,
      name = doc_name,
      parentFolderId = parent_folder_id,
    }, function(err, result)
      if err then
        local msg = err.message or ''
        if msg:match('already exists') or msg:match('400') then
          config.log('error', 'File already exists: %s', doc_name)
        else
          config.log('error', 'Failed to create doc: %s', msg)
        end
        return
      end

      config.log('info', 'Created: %s', full_path)
      vim.schedule(function()
        -- Add to tree from API response
        local depth = 0
        if parent_folder_id then
          for _, e in ipairs(project._project_tree) do
            if e.id == parent_folder_id then
              depth = (e.depth or 0) + 1
              break
            end
          end
        end
        project.add_entry({
          id = result._id or result.id,
          name = doc_name,
          path = full_path,
          type = 'doc',
          depth = depth,
        })
        require('overleaf.tree').refresh()
      end)
    end)
  end

  if name then
    do_create(name)
  else
    vim.ui.input({ prompt = 'New document name: ' }, do_create)
  end
end

function M.create_folder(name, parent_folder_id)
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end

  local prefix = project.get_folder_path(parent_folder_id)

  local function do_create(folder_name)
    if not folder_name or folder_name == '' then return end

    local full_path = prefix .. folder_name .. '/'
    if project.path_exists(full_path) then
      config.log('error', 'Folder already exists: %s', full_path)
      return
    end

    bridge.request('createFolder', {
      cookie = config.get().cookie,
      csrfToken = M._state.csrf_token,
      projectId = M._state.project_id,
      name = folder_name,
      parentFolderId = parent_folder_id,
    }, function(err, result)
      if err then
        local msg = err.message or ''
        if msg:match('already exists') or msg:match('400') then
          config.log('error', 'Folder already exists: %s', folder_name)
        else
          config.log('error', 'Failed to create folder: %s', msg)
        end
        return
      end

      config.log('info', 'Created folder: %s', full_path)
      vim.schedule(function()
        local depth = 0
        if parent_folder_id then
          for _, e in ipairs(project._project_tree) do
            if e.id == parent_folder_id then
              depth = (e.depth or 0) + 1
              break
            end
          end
        end
        project.add_entry({
          id = result._id or result.id,
          name = folder_name,
          path = full_path,
          type = 'folder',
          depth = depth,
        })
        require('overleaf.tree').refresh()
      end)
    end)
  end

  if name then
    do_create(name)
  else
    vim.ui.input({ prompt = 'New folder name: ' }, do_create)
  end
end

function M.search(pattern)
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end

  local function do_search(pat)
    if not pat or pat == '' then return end
    require('overleaf.search').grep(pat, M._state)
  end

  if pattern then
    do_search(pattern)
  else
    vim.ui.input({ prompt = 'Search pattern: ' }, do_search)
  end
end

function M.upload_file(file_path, parent_folder_id)
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end

  local function do_upload(path)
    if not path or path == '' then return end

    -- Expand ~ and resolve
    path = vim.fn.expand(path)
    if vim.fn.filereadable(path) ~= 1 then
      config.log('error', 'File not found: %s', path)
      return
    end

    local file_name = vim.fn.fnamemodify(path, ':t')
    config.log('info', 'Uploading %s...', file_name)

    bridge.request('uploadFile', {
      cookie = config.get().cookie,
      csrfToken = M._state.csrf_token,
      projectId = M._state.project_id,
      filePath = path,
      fileName = file_name,
      parentFolderId = parent_folder_id,
    }, function(err, _result)
      if err then
        config.log('error', 'Upload failed: %s', err.message)
        return
      end
      config.log('info', 'Uploaded: %s', file_name)
      -- Tree update happens via reciveNewFile socket event
    end)
  end

  if file_path then
    do_upload(file_path)
  else
    vim.ui.input({ prompt = 'Local file path: ', completion = 'file' }, do_upload)
  end
end

function M.rename_entity()
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end

  -- Show entries to rename
  local entries = {}
  for _, entry in ipairs(project._project_tree) do
    table.insert(entries, entry)
  end

  vim.ui.select(entries, {
    prompt = 'Rename:',
    format_item = function(item) return item.path end,
  }, function(choice)
    if not choice then return end

    vim.ui.input({ prompt = 'New name for "' .. choice.name .. '": ', default = choice.name }, function(new_name)
      if not new_name or new_name == '' or new_name == choice.name then return end

      bridge.request('renameEntity', {
        cookie = config.get().cookie,
        csrfToken = M._state.csrf_token,
        projectId = M._state.project_id,
        entityId = choice.id,
        entityType = choice.type,
        newName = new_name,
      }, function(err, _)
        if err then
          config.log('error', 'Rename failed: %s', err.message)
          return
        end
        vim.schedule(function()
          local updated = project.rename_entry(choice.id, new_name)
          if updated and choice.type == 'doc' then
            local doc = M._state.documents[choice.id]
            if doc and doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then
              doc.path = updated.path
              vim.api.nvim_buf_set_name(doc.bufnr, sync.buf_name(updated.path))
            end
          end
          if updated then config.log('info', 'Renamed to: %s', updated.path) end
          require('overleaf.tree').refresh()
        end)
      end)
    end)
  end)
end

function M.delete_entity()
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end

  -- Show deletable entries
  local entries = {}
  for _, entry in ipairs(project._project_tree) do
    table.insert(entries, entry)
  end

  vim.ui.select(entries, {
    prompt = 'Delete:',
    format_item = function(item)
      local icon = item.type == 'folder' and '[dir] ' or ''
      return icon .. item.path
    end,
  }, function(choice)
    if not choice then return end

    -- Confirm
    vim.ui.input({ prompt = 'Delete "' .. choice.path .. '"? (y/N): ' }, function(answer)
      if answer ~= 'y' and answer ~= 'Y' then return end

      bridge.request('deleteEntity', {
        cookie = config.get().cookie,
        csrfToken = M._state.csrf_token,
        projectId = M._state.project_id,
        entityId = choice.id,
        entityType = choice.type,
      }, function(err, _)
        if err then
          config.log('error', 'Delete failed: %s', err.message)
          return
        end
        config.log('info', 'Deleted: %s', choice.path)
        vim.schedule(function()
          project.remove_entry(choice.id)
          require('overleaf.tree').refresh()
        end)
      end)
    end)
  end)
end

function M.history()
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end

  config.log('info', 'Fetching history...')
  bridge.request('getHistory', {
    cookie = config.get().cookie,
    projectId = M._state.project_id,
  }, function(err, result)
    if err then
      config.log('error', 'History failed: %s', err.message)
      return
    end

    local updates = result.updates or {}
    if #updates == 0 then
      config.log('info', 'No history entries')
      return
    end

    vim.schedule(function() M._show_history(updates) end)
  end)
end

function M._show_history(updates)
  -- Format history entries for display
  local items = {}
  for _, update in ipairs(updates) do
    local users = {}
    for _, u in ipairs(update.meta and update.meta.users or {}) do
      table.insert(users, u.first_name or u.email or '?')
    end

    local ts = update.meta and update.meta.end_ts or 0
    local date = os.date('%Y-%m-%d %H:%M', ts / 1000)

    local files = {}
    for _, p in ipairs(update.pathnames or {}) do
      table.insert(files, p)
    end

    table.insert(items, {
      label = date .. ' | ' .. table.concat(users, ', '),
      detail = table.concat(files, ', '),
      fromV = update.fromV,
      toV = update.toV,
    })
  end

  vim.ui.select(items, {
    prompt = 'Project History:',
    format_item = function(item)
      local detail = item.detail ~= '' and (' (' .. item.detail .. ')') or ''
      return item.label .. detail
    end,
  }, function(choice)
    if not choice then return end
    config.log('info', 'Version range: v%d -> v%d', choice.fromV, choice.toV)
  end)
end

function M.compile()
  if not M._state.connected then
    config.log('warn', 'Not connected. Run :Overleaf connect first.')
    return
  end

  local sync_mod = require('overleaf.sync')
  if not sync_mod._sync_dir then
    config.log('warn', 'Local compile requires sync_dir to be configured in setup().')
    return
  end

  -- jobwait(..., 0): -1 means the job is still running; anything else (an exit
  -- code, or -3 for an unknown id) means it has finished, so we're free to go.
  if M._compile_job and vim.fn.jobwait({ M._compile_job }, 0)[1] == -1 then
    config.log('info', 'A compile is already running — re-run :Overleaf compile when it finishes')
    return
  end

  M._compile_local()
end

--- Return the project-tree entry for the root/main .tex file.
--- Resolution order: user override (set via :Overleaf set_main / <leader>om)
--- → project's rootDoc_id → first root-level .tex → any .tex.
function M._get_main_tex_entry()
  local proj = require('overleaf.project')
  local override_id = M._state.main_doc_id_override
  if override_id then
    local entry = proj.get_doc_by_id(override_id)
    if entry then return entry end
  end
  local root_id = M._state.project_data and M._state.project_data.rootDoc_id
  if root_id then
    local entry = proj.get_doc_by_id(root_id)
    if entry then return entry end
  end
  -- First .tex at root level (no path separator)
  for _, e in ipairs(proj._project_tree) do
    if e.type == 'doc' and e.path:match('%.tex$') and not e.path:match('/') then return e end
  end
  -- Any .tex file as last resort
  for _, e in ipairs(proj._project_tree) do
    if e.type == 'doc' and e.path:match('%.tex$') then return e end
  end
  return nil
end

--- Update b:vimtex_main on every open Overleaf .tex buffer so VimtexView and
--- VimTeX's project-aware features pick up the new main file.
function M._refresh_vimtex_main()
  local sync_mod = require('overleaf.sync')
  if not sync_mod._sync_dir then return end
  local main_entry = M._get_main_tex_entry()
  if not main_entry then return end
  local main_path = sync_mod._sync_dir .. '/' .. main_entry.path

  for _, doc in pairs(M._state.documents) do
    if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) and doc.path:match('%.tex$') then
      vim.b[doc.bufnr].vimtex_main = main_path
    end
  end
end

--- Set the main .tex file used for compilation. If invoked from the Overleaf
--- tree sidebar with a .tex entry under the cursor, that entry is used
--- directly. Otherwise a picker (vim.ui.select) lists every .tex doc in the
--- project. Honors any user-installed vim.ui.select handler (telescope,
--- fzf-lua, dressing.nvim, …) automatically.
function M.set_main()
  local proj = require('overleaf.project')

  -- If the cursor is in the Overleaf tree on a .tex doc, use it directly.
  local tree = require('overleaf.tree')
  local cur_win = vim.api.nvim_get_current_win()
  if tree._tree_winnr and cur_win == tree._tree_winnr then
    local line_idx = vim.api.nvim_win_get_cursor(0)[1]
    local entry = proj._project_tree[line_idx]
    if entry and entry.type == 'doc' and entry.path:match('%.tex$') then
      M._apply_main(entry)
      return
    end
  end

  -- Fall back to a picker over all .tex docs.
  local tex_docs = {}
  for _, e in ipairs(proj._project_tree) do
    if e.type == 'doc' and e.path:match('%.tex$') then table.insert(tex_docs, e) end
  end

  if #tex_docs == 0 then
    config.log('warn', 'No .tex documents found in project')
    return
  end

  vim.ui.select(tex_docs, {
    prompt = 'Select main .tex file for compilation:',
    format_item = function(item) return item.path end,
  }, function(choice)
    if choice then M._apply_main(choice) end
  end)
end

function M._apply_main(entry)
  M._state.main_doc_id_override = entry.id
  config.log('info', 'Main .tex set to: %s', entry.path)
  M._refresh_vimtex_main()
  pcall(function() require('overleaf.tree').refresh() end)
end

--- Build the latexmk argv, honoring the user's VimTeX configuration when
--- present so engine choice (e.g. -xelatex, -lualatex) and other compiler
--- options carry over. Always ensures an engine flag and -synctex=1 are set
--- so forward search via VimtexView works regardless of user options.
---@param main_path string absolute path to the main .tex file
---@param force boolean|nil if true, pass -g to bust latexmk's "previous run errored" cache
---@return string[] argv
function M._build_latexmk_cmd(main_path, force)
  local cmd = { 'latexmk', '-cd' }
  if force then table.insert(cmd, '-g') end

  -- XeLaTeX builds the PDF in two steps: `xelatex -no-pdf` → main.xdv, then
  -- xdvipdfmx → main.pdf. xdvipdfmx defaults to emitting a PDF 1.5 file, and if
  -- the document \includegraphics a newer PDF (1.7 — common: anything exported
  -- from a recent tool), xdvipdfmx bails partway with
  --   "Trying to include PDF file with version (1.7) ... newer than ... (1.5)"
  --   "Didn't find \"endobj\"" / "pdf_link_obj(): passed invalid object"
  -- leaving a truncated, unopenable main.pdf. (Overleaf's own xelatex doesn't
  -- hit this — it runs with a higher output version.) Raise xdvipdfmx's output
  -- PDF version to 1.7 unless something already set one. This is a no-op for
  -- non-xelatex engines, where $xdvipdfmx is never invoked.
  table.insert(cmd, '-e')
  table.insert(cmd, [[$xdvipdfmx =~ s/^\s*(\S+)/$1 -V 7/ unless $xdvipdfmx =~ / -V /;]])

  local vt = vim.g.vimtex_compiler_latexmk
  local options = vt and vt.options

  if type(options) == 'table' and #options > 0 then
    for _, opt in ipairs(options) do
      table.insert(cmd, opt)
    end

    local has_engine, has_synctex, has_fle, has_interaction = false, false, false, false
    for _, opt in ipairs(options) do
      if
        opt == '-pdf'
        or opt == '-xelatex'
        or opt == '-pdfxe'
        or opt == '-lualatex'
        or opt == '-pdflua'
        or opt == '-dvi'
        or opt == '-ps'
      then
        has_engine = true
      end
      if type(opt) == 'string' and opt:match('^-synctex=') then has_synctex = true end
      if opt == '-file-line-error' then has_fle = true end
      if type(opt) == 'string' and opt:match('^-interaction=') then has_interaction = true end
    end
    if not has_engine then table.insert(cmd, '-pdf') end
    if not has_synctex then table.insert(cmd, '-synctex=1') end
    -- These two options are required for accurate error reporting / parsing.
    if not has_fle then table.insert(cmd, '-file-line-error') end
    if not has_interaction then table.insert(cmd, '-interaction=nonstopmode') end
  else
    -- Defaults when VimTeX latexmk options aren't configured
    table.insert(cmd, '-pdf')
    table.insert(cmd, '-synctex=1')
    table.insert(cmd, '-interaction=nonstopmode')
    table.insert(cmd, '-file-line-error')
  end

  table.insert(cmd, main_path)
  return cmd
end

--- Extract the first LaTeX error from a .log file. Recognizes both formats:
---   1. file-line-error:  "./main.tex:26: Misplaced alignment tab character &."
---                        (no leading '!' — LaTeX with -file-line-error
---                        substitutes 'file:line:' for the '!' prefix)
---   2. classic:          "! Misplaced alignment tab character &."  with
---                        "l.26 ..." on a later line.
--- Skips obvious non-errors (LaTeX/Package Warning/Info lines).
---@param log_text string full contents of main.log
---@return string|nil
function M._first_latex_error(log_text)
  if not log_text or #log_text == 0 then return nil end
  local lines = vim.split(log_text, '\n', { plain = true })
  for i, line in ipairs(lines) do
    -- FLE format: <file>:<line>: <message>
    local fle_file, fle_lnum, fle_msg = line:match('^(%S+%.%a+):(%d+):%s*(.+)$')
    if fle_file and fle_lnum and fle_msg and not fle_msg:match('^%s*$') then
      -- Skip warnings/info that also use FLE-like prefixes
      local lower = fle_msg:lower()
      if not lower:match('^warning') and not lower:match('^info') then
        return string.format('%s:%s: %s', fle_file, fle_lnum, fle_msg)
      end
    end

    -- Classic format: "! <message>" then "l.<num>" a few lines later
    if line:match('^!') then
      local msg = line:sub(3)
      local lnum
      for j = i + 1, math.min(i + 8, #lines) do
        local n = lines[j]:match('^l%.(%d+)')
        if n then
          lnum = n
          break
        end
      end
      if lnum then return string.format('line %s: %s', lnum, msg) end
      return msg
    end
  end
  return nil
end

--- Cheap structural check that `path` is a complete PDF: it must begin with the
--- "%PDF-" signature and the trailing bytes must contain the "%%EOF" marker.
--- A PDF that fails this is truncated — e.g. xdvipdfmx aborted partway through
--- (font/graphics error on a complex document) or a second compile clobbered
--- the file. Such a PDF is non-empty but cannot be opened, so we must not pass
--- it off as a successful build.
---@param path string
---@return boolean
function M._pdf_looks_valid(path)
  local f = io.open(path, 'rb')
  if not f then return false end
  local head = f:read(5)
  if head ~= '%PDF-' then
    f:close()
    return false
  end
  local size = f:seek('end') or 0
  local tail_len = math.min(size, 2048)
  f:seek('end', -tail_len)
  local tail = f:read(tail_len) or ''
  f:close()
  return tail:find('%%EOF', 1, true) ~= nil
end

--- Run latexmk directly on the synced project.
--- VimTeX is NOT used for compilation to avoid its noisy messages; it is only
--- used afterwards for VimtexView (forward search via synctex). The latexmk
--- argv is derived from g:vimtex_compiler_latexmk.options when available so
--- the user's choice of engine (xelatex/lualatex/etc.) is respected.
function M._compile_local()
  local sync_mod = require('overleaf.sync')
  local sync_dir = sync_mod._sync_dir
  if not sync_dir then return end

  -- Land every debounced disk write before handing the tree to latexmk so the
  -- compile reads current source — and so a write can't fire mid-compile,
  -- changing a source file's mtime under xelatex/xdvipdfmx and corrupting the
  -- intermediate files it is in the middle of reading.
  sync_mod.flush_pending_writes()

  local main_entry = M._get_main_tex_entry()
  if not main_entry then
    config.log('error', 'No .tex file found in project')
    return
  end

  local main_path = sync_dir .. '/' .. main_entry.path
  if vim.fn.filereadable(main_path) ~= 1 then
    config.log('error', 'Main tex file not on disk yet: %s', main_path)
    return
  end

  local pdf_path = main_path:gsub('%.tex$', '.pdf')
  local log_path = main_path:gsub('%.tex$', '.log')
  -- latexmk's own console transcript (distinct from main.log) — this is where
  -- the .xdv→.pdf driver reports, so a failed build dumps it here.
  local build_log_path = main_path:gsub('%.tex$', '.latexmk-output.log')

  config.log('info', 'Compiling...')

  local function attempt(force)
    -- Capture latexmk output so failures are diagnosable. We treat success as
    -- "the .pdf is fresh on disk AND structurally complete after the run"
    -- rather than "exit code == 0", because latexmk can exit non-zero even
    -- when xelatex+xdvipdfmx produced a valid PDF (e.g. harmless warnings,
    -- certain rc-file callbacks, or non-fatal rerun-checks).
    local pre_mtime = vim.fn.filereadable(pdf_path) == 1 and vim.fn.getftime(pdf_path) or -1
    local stderr_buf = {}
    local stdout_buf = {}

    local job = vim.fn.jobstart(M._build_latexmk_cmd(main_path, force), {
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, data) if data then vim.list_extend(stdout_buf, data) end end,
      on_stderr = function(_, data) if data then vim.list_extend(stderr_buf, data) end end,
      on_exit = function(job_id, code)
        if M._compile_job == job_id then M._compile_job = nil end
        vim.schedule(function()
          -- Always parse the log so vim.diagnostic gets updated
          local log_text = nil
          if vim.fn.filereadable(log_path) == 1 then
            local f = io.open(log_path, 'r')
            if f then
              log_text = f:read('*a')
              f:close()
              M._parse_compile_log(log_text)
            end
          end

          -- latexmk relays the xelatex *and* the xdvipdfmx (.xdv→.pdf) output on
          -- its own stdout/stderr — NOT into main.log — so when xdvipdfmx is the
          -- one that failed (can't find/embed a graphic or font, needs
          -- shell-escape, …) the cause is only visible there. Persist the full
          -- transcript next to main.log and surface the lines that look like the
          -- actual complaint, plus the first error from main.log.
          local transcript = {}
          vim.list_extend(transcript, stdout_buf)
          vim.list_extend(transcript, stderr_buf)

          local function report_failure(headline)
            local saved = false
            local bf = io.open(build_log_path, 'w')
            if bf then
              bf:write(table.concat(transcript, '\n'))
              bf:close()
              saved = true
            end

            config.log(
              'warn',
              'Compile failed (%s, exit=%d) — see :Overleaf diagnostics, %s%s',
              headline,
              code,
              log_path,
              saved and (' and ' .. build_log_path) or ''
            )

            local first_err = M._first_latex_error(log_text or '')
            if first_err then config.log('warn', 'LaTeX error: %s', first_err) end

            local hits = {}
            for _, line in ipairs(transcript) do
              if
                line:match('xdvipdfmx')
                or line:match('dvipdfm')
                or line:match('[Ff]atal')
                or line:match('^!')
                or line:match('[Cc]ould not find')
                or line:match('[Nn]ot found')
                or line:match('shell%-escape')
                or line:match('[Ee]rror:')
              then
                hits[#hits + 1] = line
              end
            end
            if #hits == 0 then
              local tail = M._tail_lines(transcript, 8)
              if tail ~= '' then hits = vim.split(tail, '\n', { plain = true }) end
            end
            while #hits > 12 do
              table.remove(hits, 1)
            end
            if #hits > 0 then config.log('warn', 'latexmk output:\n  %s', table.concat(hits, '\n  ')) end
          end

          local pdf_mtime = vim.fn.filereadable(pdf_path) == 1 and vim.fn.getftime(pdf_path) or -1
          local pdf_fresh = pdf_mtime > pre_mtime
          local pdf_exists = pdf_mtime > 0

          if not pdf_exists or not pdf_fresh then
            -- Detect latexmk's "stuck cache" state: it remembers a previous
            -- error and refuses to rerun because nothing changed in the
            -- sources. We auto-retry once with -g to bust that cache.
            local stdout_text = table.concat(stdout_buf, '\n')
            local stuck = stdout_text:match('Nothing to do')
              and stdout_text:match('previous invocation')
            if stuck and not force then
              config.log('info', 'latexmk cached a previous error — forcing rebuild...')
              attempt(true)
              return
            end

            report_failure(pdf_exists and 'PDF was not updated' or 'no PDF produced')
            return
          end

          -- A fresh PDF is on disk, but the XeLaTeX .xdv→.pdf step (xdvipdfmx)
          -- may have aborted partway — common on larger documents (a font or
          -- graphics it can't embed) — or a parallel build clobbered the file.
          -- The result is a non-empty but truncated PDF that won't open: refuse
          -- to report it as a successful build, and don't open it in the viewer.
          if not M._pdf_looks_valid(pdf_path) then
            report_failure('PDF is truncated/corrupt')
            return
          end

          os.remove(build_log_path) -- last build succeeded; drop the stale transcript

          if code ~= 0 then
            config.log('info', 'Compile finished with warnings (exit=%d), PDF updated', code)
          else
            config.log('info', 'Compile succeeded')
          end

          -- Try VimtexView first (handles okular --unique + forward search via synctex).
          -- VimtexView works as long as b:vimtex is initialised; it doesn't need to have
          -- done the compilation itself.
          local view_bufnr = M._find_overleaf_tex_bufnr()
          if view_bufnr then
            local has_vimtex = vim.api.nvim_buf_call(view_bufnr, function()
              return vim.b.vimtex ~= nil
            end)
            if has_vimtex then
              local ok = pcall(function()
                vim.api.nvim_buf_call(view_bufnr, function()
                  vim.cmd('VimtexView')
                end)
              end)
              if ok then return end
            end
          end

          -- Fallback: open okular only if not already running
          local pgrep_output = vim.fn.system('pgrep okular')
          if pgrep_output == '' or vim.v.shell_error ~= 0 then
            vim.fn.jobstart({ 'okular', pdf_path }, { detach = true })
          end
        end)
      end,
    })

    if not job or job <= 0 then
      config.log('error', 'Could not start latexmk — is it installed and on PATH?')
      return
    end
    M._compile_job = job
  end

  attempt(false)
end

--- Take the last `n` non-empty lines of a list of strings, joined by '\n'.
---@param lines string[]
---@param n number
---@return string
function M._tail_lines(lines, n)
  local out = {}
  for i = #lines, 1, -1 do
    local s = lines[i]
    if s and s ~= '' then
      table.insert(out, 1, s)
      if #out >= n then break end
    end
  end
  return table.concat(out, '\n')
end

--- Return the currently active overleaf tex buffer, or any open overleaf tex buffer.
---@return number|nil bufnr
function M._find_overleaf_tex_bufnr()
  local cur = vim.api.nvim_get_current_buf()
  for _, doc in pairs(M._state.documents) do
    if doc.bufnr == cur and doc.path:match('%.tex$') then return cur end
  end
  for _, doc in pairs(M._state.documents) do
    if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) and doc.path:match('%.tex$') then
      return doc.bufnr
    end
  end
  return nil
end

function M._parse_compile_log(log_text)
  local ns = vim.api.nvim_create_namespace('overleaf_compile')

  -- Clear all previous diagnostics
  for _, doc in pairs(M._state.documents) do
    if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then vim.diagnostic.set(ns, doc.bufnr, {}) end
  end

  if #log_text == 0 then return end

  -- Build path -> doc lookup
  local path_to_doc = {}
  for _, doc in pairs(M._state.documents) do
    if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then
      path_to_doc[doc.path] = doc
      -- Also index without leading path components for relative matches
      local basename = doc.path:match('[^/]+$')
      if basename then path_to_doc[basename] = doc end
    end
  end

  local diagnostics = {} -- bufnr -> list of diagnostics

  -- Track current file via LaTeX log parenthesis-based file tracking
  local file_stack = {}
  local current_file = nil

  local lines = vim.split(log_text, '\n', { plain = true })
  local i = 1
  while i <= #lines do
    local line = lines[i]

    -- Track file opens/closes via parentheses
    for char in line:gmatch('[%(%)][^%(%)]*') do
      if char:sub(1, 1) == '(' then
        local fname = char:sub(2):match('^%s*([^%s%)]+)')
        if fname and fname:match('%.[a-zA-Z]+$') then
          table.insert(file_stack, current_file)
          current_file = fname
        end
      elseif char:sub(1, 1) == ')' then
        current_file = table.remove(file_stack)
      end
    end

    -- Match LaTeX errors in file-line-error format:
    --   ./main.tex:26: Misplaced alignment tab character &.
    -- (no leading "!" — LaTeX with -file-line-error substitutes file:line:
    -- for the "!" prefix.) Skip Warning/Info lines that share the prefix.
    do
      local fle_file, fle_lnum, fle_msg = line:match('^(%S+%.%a+):(%d+):%s*(.+)$')
      if fle_file and fle_lnum and fle_msg and not fle_msg:match('^%s*$') then
        local lower = fle_msg:lower()
        if not lower:match('^warning') and not lower:match('^info') then
          local doc = path_to_doc[fle_file] or path_to_doc[fle_file:match('[^/]+$') or '']
          if doc then
            diagnostics[doc.bufnr] = diagnostics[doc.bufnr] or {}
            table.insert(diagnostics[doc.bufnr], {
              lnum = tonumber(fle_lnum) - 1,
              col = 0,
              severity = vim.diagnostic.severity.ERROR,
              message = fle_msg,
              source = 'latex',
            })
          end
        end
      end
    end

    -- Match LaTeX errors in classic format: lines starting with "!"
    if line:match('^!') then
      local msg = line:sub(3) -- strip "! "
      local lnum = 0

      -- Look ahead for "l.<number>" line number
      for j = i + 1, math.min(i + 5, #lines) do
        local ln = lines[j]:match('^l%.(%d+)')
        if ln then
          lnum = tonumber(ln) - 1 -- 0-indexed
          break
        end
      end

      local doc = current_file and (path_to_doc[current_file] or path_to_doc[current_file:match('[^/]+$') or ''])
      if doc then
        diagnostics[doc.bufnr] = diagnostics[doc.bufnr] or {}
        table.insert(diagnostics[doc.bufnr], {
          lnum = lnum,
          col = 0,
          severity = vim.diagnostic.severity.ERROR,
          message = msg,
          source = 'latex',
        })
      end
    end

    -- Match LaTeX warnings
    local warn_msg = line:match('LaTeX Warning:%s*(.*)')
    if warn_msg then
      local lnum = 0
      local ln = warn_msg:match('on input line (%d+)')
      if ln then lnum = tonumber(ln) - 1 end

      local doc = current_file and (path_to_doc[current_file] or path_to_doc[current_file:match('[^/]+$') or ''])
      if doc then
        diagnostics[doc.bufnr] = diagnostics[doc.bufnr] or {}
        table.insert(diagnostics[doc.bufnr], {
          lnum = lnum,
          col = 0,
          severity = vim.diagnostic.severity.WARN,
          message = warn_msg,
          source = 'latex',
        })
      end
    end

    -- Match Overfull/Underfull hbox warnings
    local box_msg = line:match('(O[vn][edr][rf][fu][ul]l \\[hv]box.*)')
    if box_msg then
      local lnum = 0
      local ln = line:match('at lines? (%d+)')
      if ln then lnum = tonumber(ln) - 1 end

      local doc = current_file and (path_to_doc[current_file] or path_to_doc[current_file:match('[^/]+$') or ''])
      if doc then
        diagnostics[doc.bufnr] = diagnostics[doc.bufnr] or {}
        table.insert(diagnostics[doc.bufnr], {
          lnum = lnum,
          col = 0,
          severity = vim.diagnostic.severity.HINT,
          message = box_msg,
          source = 'latex',
        })
      end
    end

    i = i + 1
  end

  -- Set diagnostics for each buffer
  for bufnr, diags in pairs(diagnostics) do
    vim.diagnostic.set(ns, bufnr, diags)
  end

  -- Count by severity
  local error_count, warn_count, hint_count = 0, 0, 0
  for _, diags in pairs(diagnostics) do
    for _, d in ipairs(diags) do
      if d.severity == vim.diagnostic.severity.ERROR then
        error_count = error_count + 1
      elseif d.severity == vim.diagnostic.severity.WARN then
        warn_count = warn_count + 1
      else
        hint_count = hint_count + 1
      end
    end
  end

  if error_count > 0 or warn_count > 0 then
    config.log('info', 'Diagnostics: %d error(s), %d warning(s), %d hint(s)', error_count, warn_count, hint_count)
  end
end

function M.refresh_comments()
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end

  local comments = require('overleaf.comments')

  -- Reload threads from API
  comments.load_threads(M._state.project_id, function(err)
    if err then return end

    -- Re-join each open doc to get fresh ranges
    for doc_id, doc in pairs(M._state.documents) do
      if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) and doc.joined then
        bridge.request('joinDoc', { docId = doc_id }, function(join_err, result)
          if join_err then return end
          if result.ranges then comments.parse_ranges(doc_id, result.ranges) end
          vim.schedule(function()
            if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then
              comments.render(doc.bufnr, doc_id, doc.content)
            end
          end)
        end)
      end
    end
  end)
end

function M.show_comment()
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end

  -- Find current doc
  local bufnr = vim.api.nvim_get_current_buf()
  local doc_id = nil
  local doc = nil
  for id, d in pairs(M._state.documents) do
    if d.bufnr == bufnr then
      doc_id = id
      doc = d
      break
    end
  end

  if not doc_id then
    config.log('warn', 'Not an Overleaf document')
    return
  end

  local comments = require('overleaf.comments')
  local doc_comments = comments._doc_comments[doc_id]
  local thread_count = vim.tbl_count(comments._threads)
  config.log(
    'debug',
    'show_comment: doc=%s, threads=%d, doc_comments=%d',
    doc_id,
    thread_count,
    doc_comments and #doc_comments or 0
  )

  local thread, _ = comments.get_thread_at_cursor(doc_id, doc.content)
  if thread then
    comments.show_thread(thread)
  else
    config.log(
      'info',
      'No comment at cursor (threads=%d, doc_comments=%d)',
      thread_count,
      doc_comments and #doc_comments or 0
    )
  end
end

function M.list_comments()
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end
  require('overleaf.comments').list_all(M._state.project_id)
end

function M.reply_comment()
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local doc_id = nil
  local doc = nil
  for id, d in pairs(M._state.documents) do
    if d.bufnr == bufnr then
      doc_id = id
      doc = d
      break
    end
  end

  if not doc_id then
    config.log('warn', 'Not an Overleaf document')
    return
  end

  local comments = require('overleaf.comments')
  local thread = comments.get_thread_at_cursor(doc_id, doc.content)
  if not thread then
    config.log('info', 'No comment at cursor')
    return
  end

  vim.ui.input({ prompt = 'Reply: ' }, function(content)
    if not content or content == '' then return end

    bridge.request('addComment', {
      cookie = config.get().cookie,
      csrfToken = M._state.csrf_token,
      projectId = M._state.project_id,
      threadId = thread.id,
      content = content,
    }, function(err, _)
      if err then
        config.log('error', 'Reply failed: %s', err.message)
        return
      end
      config.log('info', 'Reply added')
    end)
  end)
end

function M.resolve_comment()
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local doc_id = nil
  local doc = nil
  for id, d in pairs(M._state.documents) do
    if d.bufnr == bufnr then
      doc_id = id
      doc = d
      break
    end
  end

  if not doc_id then
    config.log('warn', 'Not an Overleaf document')
    return
  end

  local comments = require('overleaf.comments')
  local thread = comments.get_thread_at_cursor(doc_id, doc.content)
  if not thread then
    config.log('info', 'No comment at cursor')
    return
  end

  config.log('debug', 'resolve_comment: threadId=%s resolved=%s', thread.id, tostring(thread.resolved))

  if thread.resolved then
    bridge.request('reopenThread', {
      cookie = config.get().cookie,
      csrfToken = M._state.csrf_token,
      projectId = M._state.project_id,
      docId = doc_id,
      threadId = thread.id,
    }, function(err, _)
      if err then
        config.log('error', 'Reopen failed: %s', err.message)
        return
      end
      thread.resolved = false
      config.log('info', 'Thread reopened')
      vim.schedule(function() comments.render(bufnr, doc_id, doc.content) end)
    end)
  else
    bridge.request('resolveThread', {
      cookie = config.get().cookie,
      csrfToken = M._state.csrf_token,
      projectId = M._state.project_id,
      docId = doc_id,
      threadId = thread.id,
    }, function(err, _)
      if err then
        config.log('error', 'Resolve failed: %s', err.message)
        return
      end
      thread.resolved = true
      config.log('info', 'Thread resolved')
      vim.schedule(function() comments.render(bufnr, doc_id, doc.content) end)
    end)
  end
end

function M.sync_all()
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end
  sync.sync_all(M._state, project._project_tree)
end

function M.sync_import()
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end
  sync.import_all(M._state)
end

function M.sync_export()
  if not M._state.connected then
    config.log('warn', 'Not connected.')
    return
  end
  sync.export_all(M._state)
end

function M.disconnect()
  -- Stop auto-reconnect
  M._reconnect.attempt = 0
  M._reconnect.in_progress = false
  if M._reconnect.timer then
    vim.fn.timer_stop(M._reconnect.timer)
    M._reconnect.timer = nil
  end
  bridge._on_unexpected_exit = nil

  -- Stop file sync watchers
  sync.stop()

  -- Clear collaborator cursors and comments
  pcall(function() require('overleaf.cursors').clear_all() end)
  pcall(function() require('overleaf.comments').clear_all() end)

  -- Leave all documents
  for _, doc in pairs(M._state.documents) do
    doc:leave(function() buffer.cleanup(doc) end)
  end
  M._state.documents = {}

  -- Disconnect bridge
  bridge.stop()

  M._state.connected = false
  M._state.project_name = nil
  M._state.project_id = nil
  M._state.project_data = nil
  M._state.csrf_token = nil

  config.log('info', 'Disconnected')
end

function M.status()
  if not M._state.connected then
    config.log('info', 'Not connected')
    return
  end

  local doc_count = 0
  for _ in pairs(M._state.documents) do
    doc_count = doc_count + 1
  end

  config.log(
    'info',
    'Project: %s | Documents: %d | Connected: %s',
    M._state.project_name or '?',
    doc_count,
    M._state.connected and 'yes' or 'no'
  )

  for _, doc in pairs(M._state.documents) do
    config.log('info', '  - %s (v%d)', doc.path, doc.version or 0)
  end
end

--- Statusline component for lualine or custom statusline
--- Usage with lualine: sections = { lualine_x = { require('overleaf').statusline } }
function M.statusline()
  if not M._state.connected then return '' end

  local proj = M._state.project_name or '?'

  -- Show current doc name if in an overleaf buffer
  local bufname = vim.api.nvim_buf_get_name(0)
  local doc_path = sync.parse_buf_name(bufname)
  if doc_path then return 'OL: ' .. proj .. ' / ' .. doc_path end

  return 'OL: ' .. proj
end

return M
