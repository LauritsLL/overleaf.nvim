
# overleaf.nvim
 
Neovim plugin for real-time collaborative LaTeX editing on [Overleaf](https://www.overleaf.com).
 
Edit your Overleaf projects directly in Neovim with full real-time collaboration support via Operational Transformation (OT). Use your favorite Neovim plugins — treesitter, LSP, snippets, copilot, and more — while collaborating with others on Overleaf.
 
## Features
 
- **Real-time collaboration** — edits sync instantly with other Overleaf users via OT
- **Collaborator-safe undo** — `u` / `<C-r>` only ever undo *your own* changes, never a collaborator's
- **Resilient sync** — correct OT transforms for multi-part edits, and a rejoin that keeps your unsynced edits instead of discarding them
- **Full Neovim ecosystem** — treesitter, LSP, snippets, copilot, and all your plugins work out of the box
- **File tree** — browse and manage project files in a sidebar; new files appear under their own folder
- **Context-aware file management** — create and delete based on the entry under the tree cursor or the file you are editing
- **Upload made easy** — upload several files or globs with tab completion, or let the plugin auto-upload new local files
- **Live renames and moves** — when a collaborator renames or moves a file or folder, your tree, disk and open buffers follow
- **Full project download on connect** — every document and binary file is pulled to disk, throttled and retried
- **Auto-authentication** — extracts session cookie from Chrome automatically (macOS)
- **Auto-reconnect** — recovers from disconnects and document restores seamlessly
- **Local LaTeX compilation** — compile with latexmk directly on synced files, with XeLaTeX support and optional compile-on-write
- **PDF preview with inverse search** — forward and inverse search support in Okular for seamless navigation
- **Smart PDF viewer** — tracks viewer state and only opens the window once per compile
- **Comments & reviews** — view, reply, resolve comment threads
- **Collaborator cursors** — see where other users are editing
- **Project-wide search** — grep across all documents
- **History** — view project version history
- **Diagnostics** — chktex linter + LaTeX compile errors via `vim.diagnostic`
- **LSP support** — auto-attaches texlab, ltex, harper_ls to overleaf buffers
- **Local file sync** — mirror documents to disk for external tools (Claude Code, etc.)
- **Multi-file project support** — automatic main file detection and configuration
- **Quiet, complete logging** — full log file, one-line info messages, and full-text popups for warnings and errors (no "Press ENTER" prompts)
## Requirements
 
- Neovim >= 0.10
- Node.js >= 18
- An [Overleaf](https://www.overleaf.com) account
- Chrome / Chromium (for automatic cookie extraction) or a session cookie
## Installation
 
### lazy.nvim
 
```lua
{
  'LauritsLL/overleaf.nvim',
  config = function()
    require('overleaf').setup()
  end,
  build = 'cd node && npm install',
}
```
 
If Node.js is not on your default PATH (e.g., installed via Homebrew on macOS):
 
```lua
{
  'LauritsLL/overleaf.nvim',
  config = function()
    require('overleaf').setup({
      node_path = '/opt/homebrew/bin/node',
    })
  end,
  build = 'cd node && npm install',
}
```
 
### Manual
 
```sh
git clone https://github.com/LauritsLL/overleaf.nvim ~/.local/share/nvim/lazy/overleaf.nvim
cd ~/.local/share/nvim/lazy/overleaf.nvim/node && npm install
```
 
## Authentication
 
### Option 1: Chrome (automatic)
 
Just log in to [overleaf.com](https://www.overleaf.com) in Chrome. The plugin extracts the session cookie automatically. If you have multiple Chrome profiles, you'll be prompted to select one.
 
### Option 2: Manual cookie
 
Create a `.env` file in your working directory:
 
```
OVERLEAF_COOKIE=your_overleaf_session2_cookie_here
```
 
Or pass it directly in setup:
 
```lua
require('overleaf').setup({
  cookie = 'your_overleaf_session2_cookie_here',
})
```
 
> **Warning:** If you use this method, make sure your Neovim config is not committed to a public dotfiles repository — the cookie would grant full access to your Overleaf account.
 
To get the cookie manually: open overleaf.com in your browser → DevTools (F12) → Application → Cookies → `www.overleaf.com` → find `overleaf_session2` → copy the cookie value (starts with `overleaf_session2=s%3A...`).
 
## Usage
 
### Commands
 
| Command | Description |
|---------|-------------|
| `:Overleaf` | Connect (or show status if connected) |
| `:Overleaf connect` | Connect to Overleaf |
| `:Overleaf disconnect` | Disconnect |
| `:Overleaf compile` | Compile LaTeX project |
| `:Overleaf tree` | Toggle file tree |
| `:Overleaf open` | Open a document |
| `:Overleaf projects` | Switch project |
| `:Overleaf status` | Show connection status |
| `:Overleaf preview` | Preview binary file (images, etc.) |
| `:Overleaf new [name]` | Create a document in the folder you are pointing at (see [Context-aware file management](#context-aware-file-management)) |
| `:Overleaf mkdir [name]` | Create a folder in the folder you are pointing at |
| `:Overleaf delete` | Delete the entry you are pointing at (asks for confirmation) |
| `:Overleaf rename` | Rename file/folder |
| `:Overleaf upload [paths]` | Upload one or more local files, globs, or a path containing spaces (tab-completes) |
| `:Overleaf main` | Set the project's main `.tex` file |
| `:Overleaf search [pattern]` | Search across all documents |
| `:Overleaf comments` | List all comments |
| `:Overleaf comments refresh` | Refresh comments from server |
| `:Overleaf history` | View project history |
| `:Overleaf sync` | Sync all documents to/from disk |
| `:Overleaf sync import` | Import external changes from disk to Overleaf |
| `:Overleaf sync export` | Export all documents to disk |
 
### Default Keymaps
 
| Key | Description |
|-----|-------------|
| `<leader>oc` | Connect |
| `<leader>od` | Disconnect |
| `<leader>ob` | Build (compile) |
| `<leader>ot` | Toggle file tree |
| `<leader>oo` | Open document picker |
| `<leader>op` | Preview file |
| `<leader>or` | Read comment at cursor |
| `<leader>oR` | Reply to comment |
| `<leader>ox` | Resolve/reopen comment |
| `<leader>of` | Find in project (search) |
 
### Tree Keymaps
 
| Key | Description |
|-----|-------------|
| `Enter` | Open document |
| `a` | New document (in the folder under the cursor) |
| `A` | New folder (in the folder under the cursor) |
| `d` | Delete |
| `r` | Rename |
| `u` | Upload file (into the folder under the cursor) |
| `m` | Set as main `.tex` |
| `R` | Refresh tree |
| `q` | Close tree |
 
### Undo
 
Overleaf buffers use their own undo stack instead of Vim's. Vim's undo restores old text for whole regions, which would also revert your collaborators' edits. Here:
 
- `u` and `<C-r>` (buffer-local, counts like `3u` work) only undo and redo **your own** changes
- Consecutive typing, and consecutive insert-mode deletions, are grouped into one step; a collaborator's edit starts a new step
- Each step is checked before it runs. If a collaborator has edited the exact text a step would change, the step is skipped with a message instead of overwriting their work
- Vim's native undo is turned off for these buffers, so `:undo`, `:redo` and `U` do nothing there
- The undo history is per session and is not saved to disk. A full buffer replacement (for example after a rejoin) makes older steps unusable; they are skipped safely
### Context-aware file management
 
`:Overleaf new`, `:Overleaf mkdir`, `:Overleaf delete`, and the tree keys `a`, `A`, `d` and `u` work on what you are pointing at:
 
- **In the tree window:** the entry under the cursor. On a folder, new items go inside it. On a file, they go in that file's folder. On a root-level file, they go in the project root.
- **In an Overleaf buffer:** the folder of the file you are editing (for delete: that file).
- **Anywhere else:** new items go to the project root, and `:Overleaf delete` shows a picker.
Delete always asks for `y/N` confirmation first.
 
### Uploading files
 
`:Overleaf upload` takes one or more paths, glob patterns, or a single path containing spaces, and tab-completes local paths:
 
```
:Overleaf upload Pictures/*.png
:Overleaf upload ~/figures/plot1.png ~/figures/plot2.png
```
 
- If a file lives inside the sync directory, it is uploaded into the matching Overleaf folder. Files outside it go to the project root (or the folder you pick in the tree with `u`).
- Uploads run two at a time. A single summary line reports how many were uploaded, skipped, or failed.
- A file whose path already exists in the project is skipped, unless `upload_overwrite` is set.
- A file whose folder does not exist in the project is skipped with a warning. The plugin does not create folders for you.
- Text files such as `.tex` should be created as normal documents by Overleaf's upload endpoint; check that a new one opens in the web editor.
#### Auto-upload
 
Set `auto_upload = true` and the plugin watches the sync directory for new local files — for example a figure your script just saved into `Pictures/` — and uploads them to the matching Overleaf folder.
 
- It waits until the file stops growing, so partially written files are not uploaded.
- It ignores hidden files, editor swap and temp files, LaTeX build output (`.aux`, `.log`, `.out`, `.toc`, `.xdv`, `.bbl`, `.synctex.gz`, ...), and a PDF that sits next to a `.tex` of the same name (your own compile output).
- `auto_upload_ext` restricts it to certain extensions.
- One watcher runs per project folder. Folders created after you connected are picked up by the next `:Overleaf sync`.
### Collaborator renames and moves
 
When someone renames or moves a file or folder on Overleaf, the plugin applies the change locally:
 
- the file tree updates, with entries placed under their new folder
- the file or directory is renamed or moved on disk, including everything inside a moved folder
- open buffers keep working: their path, buffer name and file watcher are updated
If the target already exists on disk, the plugin leaves the old path in place and warns instead of overwriting anything.
 
### Sync and rejoin behavior
 
**Downloading the project.** On connect (and on `:Overleaf sync`) every text document is fetched and written to disk, and binary files such as images are downloaded if they are not on disk yet. Document fetches run three at a time and each is retried up to three times. If any still fail, a warning lists exactly which files.
 
**Rejoin.** If the editor and the server get out of step (a version mismatch or a failed update), the plugin rejoins the document. Edits you typed but had not yet synced are not thrown away:
 
- If their surroundings can be found unambiguously in the server's text, they are merged on top of it and sent again.
- Otherwise your version of the file is saved to `~/.local/state/nvim/overleaf-conflicts/<path>.<timestamp>.bak` and you get a warning with the path.
**Concurrent edits.** Multi-part edits (such as replace = delete + insert) and edits that overlap a collaborator's are transformed correctly, and any not-yet-processed local keystroke is folded in before a remote edit is applied, so the buffer and the server's view stay aligned.
 
### Logging
 
- **Log file:** everything (debug and up) is written in full to `~/.local/state/nvim/overleaf.log` (`vim.fn.stdpath('state') .. '/overleaf.log'`). Follow it with `tail -f`, or run `:lua require('overleaf.config').show_log()` to open it in a split.
- **On screen:** only messages at or above `log_level` (default `warn`) are shown, and they never trigger "Press ENTER":
  - info and debug appear as one short, truncated line
  - warnings and errors show their **full text**: a short one as a normal notification, a long or multi-line one in a floating popup in the top-right corner that closes itself after `popup_ms` (default 12 seconds)
## Configuration
 
```lua
require('overleaf').setup({
  -- Path to .env file containing OVERLEAF_COOKIE (default: '.env')
  env_file = '.env',
 
  -- Session cookie (overrides .env)
  cookie = nil,
 
  -- Path to Node.js binary (default: 'node')
  node_path = 'node',
 
  -- Overleaf instance URL (default: 'https://www.overleaf.com')
  base_url = 'https://www.overleaf.com',
 
  -- PDF viewer command (nil = auto-detect: 'open' on macOS, 'xdg-open' on Linux)
  pdf_viewer = nil,
 
  -- PDF output directory (nil = system temp directory)
  pdf_dir = nil,
 
  -- Local file sync directory for external tools and local compilation (default: nil = disabled)
  -- When set: all documents are mirrored to disk, latexmk compiles locally, and external changes sync back
  sync_dir = '~/.overleaf',
 
  -- Minimum level shown on screen: 'debug', 'info', 'warn', 'error' (default: 'warn')
  log_level = 'warn',
 
  -- Minimum level written to the log file; 'off' disables the file (default: 'debug')
  log_file_level = 'debug',
 
  -- Log file location (nil = stdpath('state')/overleaf.log)
  log_file = nil,
 
  -- How long a long warning/error popup stays open, in milliseconds (default: 12000)
  popup_ms = 12000,
 
  -- Watch sync_dir and upload new local files automatically (default: false)
  auto_upload = false,
 
  -- Only auto-upload these extensions (nil = any file that is not ignored)
  auto_upload_ext = { 'png', 'jpg', 'jpeg', 'pdf', 'svg', 'eps', 'csv', 'bib', 'tex', 'sty' },
 
  -- Upload even if the path already exists in the project (default: false = skip)
  upload_overwrite = false,
 
  -- Set to false to disable default keymaps
  keys = true,
})
```
 
### Okular Inverse Search Setup
 
To enable inverse search (Shift+Click in PDF to jump to source), configure Okular's editor:
 
1. Open Okular → Settings → Editor
2. Set Command to: `nvim --remote-expr "OlInverseSearch('{file}',{line})"`
3. Save and restart Okular
The plugin auto-configures Okular as the vimtex viewer with synctex support when compilation is enabled.
 
## Workflow
 
1. `:Overleaf` — authenticate and select a project
2. File tree appears — press `Enter` to open a document
3. Edit normally — changes sync to Overleaf in real-time
4. `:w` — triggers local compilation (if sync_dir is enabled) and opens PDF in Okular
5. Use Okular's inverse search (Shift+Left-Click) to jump back to Neovim at a specific PDF location
6. `:Overleaf tree` — switch between documents
## External Tool Integration (Claude Code, etc.)
 
By default, Overleaf documents exist only as virtual buffers — they have no files on disk. This means external tools like Claude Code cannot read or edit them.
 
Set `sync_dir` to enable local file mirroring:
 
```lua
require('overleaf').setup({
  sync_dir = '~/.overleaf',  -- or any directory
})
```
 
When connected to a project, all text documents are synced to `~/.overleaf/<project-name>/`. External tools can read and edit these files — changes are automatically detected and synced back to Overleaf.
 
### How it works
 
- **On connect**: all documents and binary files are fetched and written to disk
- **Neovim edits**: debounced writes keep disk files up to date
- **Remote edits**: disk files are updated when collaborators make changes
- **Remote renames and moves**: disk files and folders are renamed or moved to match
- **External edits**: file watchers detect changes and sync them to Overleaf via OT
  - For open documents: buffer is updated, triggering the normal OT pipeline
  - For closed documents: changes are sent directly via the bridge
- **New local files**: uploaded automatically if `auto_upload` is enabled
### Commands
 
- `:Overleaf sync` — re-sync all documents (fetch from Overleaf and write to disk)
- `:Overleaf sync import` — import all external disk changes to Overleaf
- `:Overleaf sync export` — export all documents to disk
### Usage with Claude Code
 
```bash
# Start Claude Code in the sync directory
cd ~/.overleaf/My\ Project
claude
```
 
Claude Code can now read all your LaTeX files and make edits that sync back to Overleaf in real-time.
 
## Troubleshooting
 
- **Compile fails with `File ... not found`:** check the path in the `.tex` file first. A bare file name only resolves if `\graphicspath` covers its folder; otherwise use the full path from the project root (for example `Pictures/B/plot.png`).
- **Compile fails with a font error from `fontspec`:** the font exists on Overleaf but not on your machine. Install it, or use a metric-compatible free font (for example Tinos or Liberation Serif for Times New Roman).
- **A warning says documents could not be downloaded:** the warning lists them. Run `:Overleaf sync` to retry, and check the log file for the error.
- **"Rejoin replaced unsynced edits":** your text was saved under `~/.local/state/nvim/overleaf-conflicts/`; copy back what you need.
- **Anything else:** the full details, including debug output, are in `~/.local/state/nvim/overleaf.log`.
## How It Works
 
The plugin spawns a Node.js bridge process that connects to Overleaf's real-time collaboration server via Socket.IO. Edits in Neovim are converted to OT operations and sent to the server. Remote edits from other collaborators are transformed and applied to your buffer in real-time.
 
When `sync_dir` is enabled, documents are mirrored to disk and compilation runs locally with latexmk, supporting pdfTeX, XeLaTeX, and LuaTeX. Changes from external tools or other users are automatically detected and synced bidirectionally. Compilation results are shown via vim.diagnostic, and Okular's forward and inverse search integrate with vimtex for seamless PDF navigation.
 
## Disclaimer
 
This is an **unofficial** plugin and is not affiliated with, endorsed by, or supported by [Overleaf](https://www.overleaf.com). It relies on Overleaf's internal real-time collaboration protocol, which is undocumented and may change at any time without notice. Such changes could cause the plugin to stop working, or in the worst case, lead to document corruption or data loss.
 
Overleaf maintains version history for all projects, so you can restore previous versions from the Overleaf web interface if anything goes wrong.
 
**Use this plugin at your own risk.** Always keep important work backed up.
 
## Acknowledgments
 
This project was developed with reference to the following projects for understanding Overleaf's real-time collaboration protocol:
 
- [AirLatex.vim](https://github.com/dmadisetti/AirLatex.vim) (MIT) — Neovim plugin for Overleaf by David Hartmann. Referenced for Chrome cookie extraction approach and Socket.IO connection patterns.
- [Overleaf-Workshop](https://github.com/iamhyc/Overleaf-Workshop) (AGPL-3.0) — VS Code extension for Overleaf. Referenced for protocol details including the v2 connection scheme, OT update hashing, and joinDoc parameters.
The code in this repository is an independent implementation in Lua/Node.js. No source code was directly copied from either project.
 
## License
 
MIT
 
