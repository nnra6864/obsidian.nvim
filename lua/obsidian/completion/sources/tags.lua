local completion = require "obsidian.completion.tags"
local search = require "obsidian.search"
local api = require "obsidian.api"
local tag_module = require "obsidian.tag"
local BufferDocument = require "obsidian.document"

local M = {}

---@type lsp.CompletionList
local EMPTY_RESPONSE = {
  isIncomplete = true,
  items = {},
}

--- Runs a generalized version of the complete (nvim_cmp) or get_completions (blink) methods
---@param callback fun(resp: lsp.CompletionList)
---@param request obsidian.completion.Request
function M.process_completion(callback, request)
  local can_complete, term, in_frontmatter = completion.can_complete(request)

  -- A `tags:` list item can't be mistaken for anything else, so it lists every tag
  -- before anything is typed (like Obsidian's tag property).
  if not (can_complete and term ~= nil and (in_frontmatter or #term >= Obsidian.opts.completion.min_chars)) then
    callback(EMPTY_RESPONSE)
    return
  end

  ---@cast term -nil

  local path = vim.api.nvim_buf_get_name(request.bufnr)
  local document = BufferDocument.get(request.bufnr)
  -- The note's own tags come from the buffer, which may be ahead of the file on disk,
  -- without the one being typed.
  local own = {}
  local present = {}
  for _, occurrence in ipairs(tag_module.extract(document.lines, { document = document })) do
    if occurrence.range.start_row ~= request.line then
      own[#own + 1] = occurrence
      if occurrence.source == "frontmatter" then
        present[tag_module.normalize(occurrence.tag)] = true
      end
    end
  end

  search.find_tags_async(term, function(tag_locs)
    local tags = {}
    local locs = {}
    for _, tag_loc in ipairs(tag_locs) do
      if vim.fs.normalize(tostring(tag_loc.path)) ~= vim.fs.normalize(path) then
        locs[#locs + 1] = tag_loc
      end
    end
    for _, occurrence in ipairs(own) do
      if tag_module.matches(occurrence.tag, term, "prefix") then
        locs[#locs + 1] = occurrence
      end
    end
    for _, tag_loc in ipairs(locs) do
      local key = tag_module.normalize(tag_loc.tag)
      -- A note lists each tag once in its frontmatter
      if in_frontmatter and present[key] then
        goto continue
      end
      local item = tags[key]
      if item then
        item.count = item.count + 1
      else
        tags[key] = { name = tag_loc.tag, count = 1 }
      end
      ::continue::
    end

    local items = {}
    for _, tag_item in pairs(tags) do
      local tag, count = tag_item.name, tag_item.count
      -- Generate context-appropriate text
      local insert_text, label_text
      if in_frontmatter then
        -- Frontmatter: insert tag without # (YAML format)
        insert_text = tag
        label_text = "Tag: " .. tag
      else
        -- Document body: insert tag with # (Obsidian format)
        insert_text = "#" .. tag
        label_text = "Tag: #" .. tag
      end

      -- Calculate the range to replace (the entire #tag pattern)
      local cursor_before = request.cursor_before_line
      local hash_start = string.find(cursor_before, "#[^%s]*$")
      local _, dash_end = string.find(cursor_before, "%-%s")
      local insert_start = hash_start and (hash_start - 1) or dash_end
      local insert_end = #cursor_before
      -- A bare "-" gets the space before the tag too
      if not insert_start then
        insert_start = insert_end
        insert_text = " " .. insert_text
      end

      items[#items + 1] = {
        sortText = tag,
        filterText = hash_start and "#" .. tag or tag,
        label = label_text,
        kind = vim.lsp.protocol.CompletionItemKind.Keyword,
        documentation = {
          kind = "markdown",
          value = string.format("`#%s` — %d occurrence%s", tag, count, count == 1 and "" or "s"),
        },
        textEdit = {
          newText = insert_text,
          range = {
            ["start"] = {
              line = request.line,
              character = insert_start,
            },
            ["end"] = {
              line = request.line,
              character = insert_end,
            },
          },
        },
      }
    end

    callback {
      isIncomplete = true,
      items = items,
    }
  end, { dir = api.resolve_workspace_dir(vim.api.nvim_buf_get_name(request.bufnr)), match = "prefix" })
end

return M
