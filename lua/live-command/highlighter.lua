local M = {}

---@class livecmd.Highlight
---@field line number
---@field column number
---@field length number
---@field kind string

local logger = require("live-command.logger")

-- Inserts str_2 into str_1 at the given position.
local function string_insert(str_1, str_2, pos)
  return str_1:sub(1, pos - 1) .. str_2 .. str_1:sub(pos)
end

-- Inserts a newline character after each character of s and returns the table of characters.
local function splice(s)
  local chars = {}
  for i = 1, #s do
    chars[2 * i - 1] = s:sub(i, i)
    chars[2 * i] = "\n"
  end
  return table.concat(chars)
end

local function add_inline_highlights(line, old_lines, new_lines, undo_deletions, highlights)
  local line_a = splice(old_lines[line])
  local line_b = splice(new_lines[line])
  local line_diff = vim.diff(line_a, line_b, { result_type = "indices" })

  logger.trace(function()
    return ("Changed lines (line %d):\nOriginal: '%s' (len=%d)\nUpdated:  '%s' (len=%d)\n\nInline hunks: %s"):format(
      line,
      old_lines[line],
      #old_lines[line],
      new_lines[line],
      #new_lines[line],
      vim.inspect(line_diff)
    )
  end)

  local col_offset = 0

  for _, line_hunk in ipairs(line_diff) do
    local start_a, count_a, start_b, count_b = unpack(line_hunk)
    local hunk_kind = (count_a == 0 and "insertion") or (count_b == 0 and "deletion") or "change"

    local function push_hl(kind, ln, col, len)
      table.insert(highlights, { kind = kind, line = ln, column = col, length = len })
    end

    if hunk_kind == "insertion" then
      -- insertion: highlight the new text at start_b (no +1)
      push_hl("insertion", line, start_b + col_offset, count_b)
    elseif hunk_kind == "deletion" then
      if undo_deletions then
        -- deletion-only: start_b is position *before* deletion, so add +1
        local insert_pos = col_offset + start_b + 1
        local deleted_part = old_lines[line]:sub(start_a, start_a + count_a - 1)
        new_lines[line] = string_insert(new_lines[line], deleted_part, insert_pos)
        push_hl("deletion", line, insert_pos, count_a)
        col_offset = col_offset + #deleted_part
      end
    else -- "change"
      if undo_deletions then
        -- change: treat as deletion then insertion.
        -- start_b points at the new text's first char, so DO NOT add +1 here.
        local insert_pos = col_offset + start_b
        local deleted_part = old_lines[line]:sub(start_a, start_a + count_a - 1)

        -- Insert deleted text before the new text
        new_lines[line] = string_insert(new_lines[line], deleted_part, insert_pos)

        -- Deleted (old) chunk: highlight at insert_pos
        push_hl("deletion", line, insert_pos, count_a)

        -- Inserted (new) chunk: right after the deleted chunk
        push_hl("insertion", line, insert_pos + count_a, count_b)

        -- update offset for later hunks
        col_offset = col_offset + #deleted_part
      else
        -- fallback: only show the new text (original behaviour)
        push_hl("change", line, start_b + col_offset, count_b)
      end
    end
  end
end


--- @param old_lines string[]
--- @param new_lines string[]
--- @param line_range {start:number, end:number}
--- @param inline_highlighting boolean
--- @param undo_deletions boolean
--- @return livecmd.Highlight[], string[]
M.get_highlights = function(diff, old_lines, new_lines, line_range, inline_highlighting, undo_deletions)
  local highlights = {}
  for i, hunk in ipairs(diff) do
    logger.trace(function()
      return ("Hunk %d/%d: %s"):format(i, #diff, vim.inspect(hunk))
    end)

    local start_a, count_a, start_b, count_b = hunk[1], hunk[2], hunk[3], hunk[4]
    local hunk_kind = (count_a < count_b and "insertion") or (count_a > count_b and "deletion")
    if hunk_kind then
      local start_line, end_line
      if hunk_kind == "insertion" then
        start_line = start_b + count_a
        end_line = start_a + (count_b - count_a)
      else
        start_line = start_a + count_b
        end_line = start_line + (count_a - count_b) - 1
      end

      logger.trace(function()
        return ("Lines %d-%d:\nOriginal: %s\nUpdated: %s"):format(
          start_line,
          end_line,
          vim.inspect(vim.list_slice(old_lines, start_line, end_line)),
          vim.inspect(vim.list_slice(new_lines, start_line, end_line))
        )
      end)

      for line = start_line, end_line do
        -- Outside of visible area, skip current or all hunks
        if line > line_range[2] then
          return highlights, new_lines
        end

        if line >= line_range[1] then
          if hunk_kind == "deletion" and undo_deletions then
            -- Hunk was deleted: reinsert lines
            table.insert(new_lines, line, old_lines[line])
          end
          if new_lines[line] == "" then
            -- Make empty lines visible
            new_lines[line] = " "
          end
          table.insert(highlights, { kind = hunk_kind, line = line, column = 1, length = -1 })
        end
      end
    else
      -- Change edit
      for line = start_b, start_b + count_b - 1 do
        -- Outside of visible area, skip current or all hunks
        if line > line_range[2] then
          return highlights, new_lines
        end

        if line >= line_range[1] then
          if inline_highlighting then
            -- Get diff for each line in the hunk
            add_inline_highlights(line, old_lines, new_lines, undo_deletions, highlights)
          else
            -- Use a single highlight for the whole line
            table.insert(highlights, { kind = "change", line = line, column = 1, length = -1 })
          end
        end
      end
    end
  end
  return highlights, new_lines
end

return M
