-- 这里读取 fixed、Mix、A 快捷短语和 Emoji 等只读词表，并让各模块共用加载结果。
-- 个人 TXT 的恢复、追加和整理交给 personal_store。这里的数组只保留词表顺序，最终候选顺序由查询和过滤模块决定，单字模式和三声码也由它们判断。

local core = require "whitkey.core"
local meta = require "whitkey.candidate"
local M = {}
local fixed_cache, dictionary_cache, shortcut_cache, emoji_cache = {}, {}, {}, {}

-- 同一路径只加载一份索引，多个模块共用。等所有使用者退出后再释放，避免一个模块退出就影响其他模块。
local function release(cache, path)
  local item = path and cache[path]
  if not item then return end
  item.refs = item.refs - 1
  if item.refs <= 0 then cache[path] = nil end
end

function M.resolve(filename)
  return core.user_path(filename)
end

-- 读取 fixed 固定词表。

-- 为每个词找出最短固定码，供 focus 和编码旁注使用。
local function reverse_fixed(dict)
  local reverse = {}
  for code, words in pairs(dict) do
    for _, word in ipairs(words) do
      local old = reverse[word]
      if not old or #code < #old or (#code == #old and code < old) then
        reverse[word] = code
      end
    end
  end
  return reverse
end

-- 固定 TXT 每行先写编码，按 Tab 后写词语，多个词用空格隔开。第一次使用时才读表。
-- 同码多行会合并，重复词保留最早的位置。这里只查完整编码，不导入原生词典，也不生成前缀补全。
function M.acquire_fixed(path)
  local item = fixed_cache[path]
  if not item then
    local dict, seen = {}, {}
    local file = io.open(path, "r")
    if file then
      for line in file:lines() do
        line = line:gsub("\r$", ""):gsub("^\239\187\191", "")
        local code, raw = line:match("^%s*([a-z;`]+)[ ]*\t(.+)$")
        if code and not line:match("^%s*#") then
          for word in raw:gmatch("%S+") do
            local key = code .. "\t" .. word
            if core.valid_text(word) and not seen[key] then
              seen[key] = true
              local words = dict[code]
              if not words then
                words = {}
                dict[code] = words
              end
              words[#words + 1] = word
            end
          end
        end
      end
      file:close()
    end
    item = { dict = dict, reverse = reverse_fixed(dict), refs = 0 }
    fixed_cache[path] = item
  end
  item.refs = item.refs + 1
  return item
end

-- 在 fixed 的同码词列表里找这个词，无需建立重复的成员表。
-- 找到只说明它属于这张表，后面还要检查 hidden 和输入模式，才能决定是否显示。
function M.fixed_contains(item, text, code)
  local words = item and item.dict[code]
  if not words then return false end
  for _, word in ipairs(words) do
    if word == text then return true end
  end
  return false
end

function M.release_fixed(path)
  release(fixed_cache, path)
end

-- 按 630、二简、2625 的顺序加载固定表。需要固定表的模块共用这组数据，不各读一份。
local FIXED_FILES = {
  {"fixed_file", "fixed/630.txt"},
  {"duo_file", "fixed/duo.txt"},
  {"fixed_2625_file", "fixed/2625.txt"},
}
function M.acquire_fixed_sources(config)
  local sources, paths = {}, {}
  for i, spec in ipairs(FIXED_FILES) do
    paths[i] = M.resolve(config:get_string("candidate_order/" .. spec[1]) or spec[2])
    sources[i] = M.acquire_fixed(paths[i])
  end
  return sources[1], sources, paths
end
function M.release_fixed_sources(paths)
  for _, path in ipairs(paths or {}) do M.release_fixed(path) end
end
function M.fixed_sources_contains(sources, text, code)
  for _, source in ipairs(sources) do
    if M.fixed_contains(source, text, code) then return true end
  end
  return false
end

-- 从 Rime 源词典读出词语和编码，后面的权重不读取。
-- Tab 上屏、英文开关和 Mix 后缀都用这份表判断候选是否来自 Mix。
function M.acquire_dictionary(path)
  local item = dictionary_cache[path]
  if not item then
    item = { by_text = {}, refs = 0 }
    local file = io.open(path, "r")
    if file then
      for line in file:lines() do
        line = line:gsub("\r$", ""):gsub("^\239\187\191", "")
        if line ~= "" and not line:match("^%s*#") then
          local text, code = line:match("^([^\t]+)\t([^\t]+)")
          text, code = core.clean_text(text), core.clean_code(code, true)
          if text ~= "" and code ~= "" then
            item.by_text[text] = item.by_text[text] or {}
            item.by_text[text][code] = true
          end
        end
      end
      file:close()
    end
    dictionary_cache[path] = item
  end
  item.refs = item.refs + 1
  return item
end

function M.release_dictionary(path)
  release(dictionary_cache, path)
end

-- 先检查完整编码。如果 Rime 已把候选标成补全项，也可以检查它的完整码是否以当前输入开头。
-- 这里只找这个词自己的编码，不扫整表。文字相同但编码不同，不能直接当成同一个 Mix 候选。
function M.dictionary_contains(item, text, code, allow_completion)
  local codes = item and item.by_text[text]
  if not codes then return false end
  if codes[code] then return true end
  if not allow_completion or code == "" then return false end
  for assigned in pairs(codes) do
    if #assigned > #code and assigned:sub(1, #code) == code then
      return true
    end
  end
  return false
end

-- 读取 A 快捷短语和 Emoji。

-- A_custom_phrases.txt 每行写“编码＋Tab＋顺序数字＋Tab＋文字”。
-- 同码先按数字从小到大排列，数字相同时保持文件里的顺序。
function M.acquire_shortcuts(filename)
  local path = M.resolve(filename or "white_replace/A_custom_phrases.txt")
  local item = shortcut_cache[path]
  if not item then
    local by_code, file_index = {}, 0
    local file = io.open(path, "r")
    if file then
      for line in file:lines() do
        file_index = file_index + 1
        line = line:gsub("\r$", ""):gsub("^\239\187\191", "")
        if line ~= "" and not line:match("^%s*#") then
          local code, rank, phrase = line:match("^([^\t]+)\t(%d+)\t(.+)$")
          code = code and code:gsub("^%s+", ""):gsub("%s+$", ""):lower() or ""
          rank = tonumber(rank)
          phrase = phrase and phrase:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\\n", "\n")
          if code:match("^[a-z]+$") and rank and phrase and phrase ~= ""
              and utf8.len(phrase) ~= nil then
            by_code[code] = by_code[code] or {}
            by_code[code][#by_code[code] + 1] = { phrase=phrase, rank=rank, file_index=file_index }
          end
        end
      end
      file:close()
    end
    for _, list in pairs(by_code) do
      table.sort(list, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.file_index < b.file_index
      end)
    end
    item = { by_code=by_code, refs=0, path=path }
    shortcut_cache[path] = item
  end
  item.refs = item.refs + 1
  return item, path
end

function M.release_shortcuts(path)
  release(shortcut_cache, path)
end

function M.shortcut_lookup(item, code)
  return item and item.by_code[code] or nil
end

-- Emoji 每行先写名称，按 Tab 后写表情，多个表情用空格隔开。第三列可以指定编码，留空时按名称取码，写错时跳过这一行。
-- 同名称、同指定编码的多行合并，重复表情只保留一次。相同名称用了不同编码时，各行保留自己的表情和查询码。
function M.acquire_emoji(filename)
  local path = M.resolve(filename or "white_dicts/emoji.txt")
  local item = emoji_cache[path]
  if not item then
    local entries, by_key, seen_by_key = {}, {}, {}
    local file = io.open(path, "r")
    if file then
      for line in file:lines() do
        line = line:gsub("\r$", ""):gsub("^\239\187\191", "")
        local text, raw, code = line:match("^([^\t]+)\t([^\t]+)\t?([^\t]*)$")
        if text and not line:match("^%s*#") and core.valid_text(text)
            and not text:find("%s")
            and (code == "" or #code >= 2 and core.is_sound_code(code)) then
          local key = text .. "\t" .. code
          local entry = by_key[key]
          if not entry then
            entry = {text=text, code=code, values={}}
            by_key[key], seen_by_key[key] = entry, {}
            entries[#entries + 1] = entry
          end
          for value in raw:gmatch("%S+") do
            -- 加载与查询、隐藏共用身份规则，不能删掉多字符表情内部的 FE0F。
            local identity = meta.emoji_identity(value)
            if core.valid_text(value) and not seen_by_key[key][identity] then
              seen_by_key[key][identity] = true
              entry.values[#entry.values + 1] = value
            end
          end
        end
      end
      file:close()
    end
    item = {entries=entries, refs=0, path=path}
    emoji_cache[path] = item
  end
  item.refs = item.refs + 1
  return item, path
end

function M.release_emoji(path)
  release(emoji_cache, path)
end

return M
