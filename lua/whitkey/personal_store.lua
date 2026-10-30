-- hidden、created、pinned、picked 和统计文件都从这里读写。
-- user_records 按文件顺序执行设置、删除并整理记录，这里不处理候选排序或显示。
-- 多词索引的内部存法也由 user_records 负责。这里通过 words、contains、word_index 读取，不拆自己的存法分支。

local core = require "whitkey.core"
local records = require "whitkey.user_records"
local M = {}

local set_cache, created_cache, pinned_cache, picked_cache = {}, {}, {}, {}
local shapes = core.shape_list()

local function release(cache, path)
  local item = path and cache[path]
  if not item then return end
  item.refs = item.refs - 1
  if item.refs <= 0 then cache[path] = nil end
end

-- 正式文件存在就使用它，空文件也有效。只有正式文件不存在时才恢复 .bak。
-- .tmp 可能还没写完，不能把它当成已保存的数据。
local function file_exists(path)
  local file, err, code = io.open(path, "rb")
  if file then
    file:close()
    return true
  end
  if code == 2 then return false end
  return nil, err
end

local function recover_file(path)
  local exists, err = file_exists(path)
  if exists == nil then return false, err end
  if exists then return true end
  local backup = path .. ".bak"
  local backed, backup_err = file_exists(backup)
  if backed == nil then return false, backup_err end
  if not backed then return true end
  local restored, restore_err = os.rename(backup, path)
  if not restored then return false, "无法恢复数据备份：" .. tostring(restore_err), backup end
  return true
end

local function read_recoverable(path, binary)
  local ready, recovery_err, backup = recover_file(path)
  -- 恢复时改名失败，仍允许读取备份，但把错误交给调用方，并禁止继续写入。
  local file, read_err, code
  if ready or backup then file, read_err, code = io.open(backup or path, binary and "rb" or "r") end
  local err = recovery_err or (not file and code ~= 2 and read_err) or nil
  if err and log and log.error then
    log.error("纯白键道：读取个人数据失败，保留原文件和备份：" .. tostring(err))
  end
  return file, err
end

-- 先完整写入 .tmp，再把正式文件改名为 .bak，最后把 .tmp 改成正式文件。
-- 这是几次操作，不是一步原子替换。任何一步失败，都尽量留下正式文件或备份供后续恢复。
local function replace_file(path, writer)
  local ready, recovery_err = recover_file(path)
  if not ready then return false, recovery_err end
  local temporary, backup = path .. ".tmp", path .. ".bak"
  local file, open_err = io.open(temporary, "wb")
  if not file then return false, open_err or "无法创建临时文件" end

  local called, ok, write_err = pcall(writer, file)
  local close_ok, close_err = file:close()
  if not called or not ok or not close_ok then
    os.remove(temporary)
    return false, (not called and ok) or write_err
        or close_err or "无法写入临时文件"
  end

  local had_original, check_err = file_exists(path)
  if had_original == nil then
    os.remove(temporary)
    return false, check_err
  end
  if had_original then
    local removed, remove_err, remove_code = os.remove(backup)
    if not removed and remove_code ~= 2 then
      os.remove(temporary)
      return false, remove_err
    end
    local backed, backup_err = os.rename(path, backup)
    if not backed then
      os.remove(temporary)
      return false, backup_err
    end
  end

  local replaced, replace_err = os.rename(temporary, path)
  if not replaced then
    if had_original then
      local restored, restore_err = os.rename(backup, path)
      if not restored then
        return false, tostring(replace_err)
            .. "；备份仍保留，恢复失败：" .. tostring(restore_err)
      end
    end
    os.remove(temporary)
    return false, replace_err
  end
  if had_original then os.remove(backup) end
  return true
end

function M.resolve(filename)
  return core.user_path(filename)
end

function M.load(path, kind, record_type, config)
  local threshold = config and config:get_int("personal_records/compact_stale_records") or 100
  return records.load(path, kind, {
    open = function(value) return read_recoverable(value, true) end,
    ready = recover_file,
    replace = replace_file,
    report = function(err)
      core.report(nil, "个人词条已保存，整理暂未完成", err)
    end,
  }, record_type, math.max(1, threshold))
end

M.change = records.change
M.compact = records.compact

-- hidden 为每个编码保存一组需要隐藏的词。
function M.acquire_hidden(path, config)
  local item = set_cache[path]
  if not item then
    item = M.load(path, "set", "hidden", config)
    if item.load_error then
      core.report(nil, "隐藏词表无法读取，保留原文件", item.load_error)
    end
    set_cache[path] = item
  end
  item.refs = item.refs + 1
  return item
end

function M.release_hidden(path)
  release(set_cache, path)
end

function M.hidden_contains(item, text, code)
  return text ~= "" and code ~= "" and records.contains(item, code, text)
end

function M.hide(item, text, code)
  text, code = core.clean_text(text), core.clean_code(code, true)
  if text == "" or code == "" then return false, "词语或编码为空" end
  if records.contains(item, code, text) then return true, "existing" end
  local ok, err = records.change(item, "设置", code, text)
  if not ok then return false, err end
  return true, "added"
end

-- created 同码可以保存多个词，新保存的词排在前面。
function M.acquire_created(filename, config)
  local path = M.resolve(filename or "white_replace/whitkey_created.txt")
  local item = created_cache[path]
  if not item then
    item = M.load(path, "list", "created", config)
    item.symbols = core.read_created_symbols(config)
    if item.load_error then
      core.report(nil, "自造词文件无法读取，保留原文件", item.load_error)
    end
    created_cache[path] = item
  end
  item.refs = item.refs + 1
  return item, path
end

function M.release_created(path)
  release(created_cache, path)
end

function M.created_lookup(item, code)
  -- 返回值只供查询。添加或删除必须走写盘接口，不能改这个数组，否则磁盘记录不会跟着变。
  return records.words(item, code)
end

function M.created_contains(item, text, code)
  return records.contains(item, code, text)
end

function M.created_add(item, text, code)
  if item.load_error then return false, item.load_error end
  text, code = core.clean_text(text), core.clean_code(code)
  if text == "" or code == "" then return false, "词语或编码为空" end
  if M.created_contains(item, text, code) then return true, "existing" end
  local ok, err = records.change(item, "设置", code, text)
  if not ok then return false, err end
  return true, "added"
end

function M.created_remove(item, text, code)
  if item.load_error then return false, item.load_error end
  text, code = core.clean_text(text), core.clean_code(code)
  local index = records.word_index(item, code, text)
  if not index then return false, "not_found" end
  local ok, err = records.change(item, "删除", code, text)
  if not ok then return false, err end
  return true, "removed", index
end

-- 纯汉字三字词保存为“三声码＋首字第一笔形码”，补全时只查五个形码对应的现成记录。
-- 按正式保存码查，不随当前符号设置重算旧词。每个结果保留正式码，三声短码只是入口，避免旧词找不到或删不掉。
function M.created_completions(item, code)
  if not core.is_sound_code(code, 3) then return nil end
  local rows
  for _, shape in ipairs(shapes) do
    local full_code = code .. shape
    for _, text in ipairs(records.words(item, full_code) or {}) do
      rows = rows or {}
      rows[#rows + 1] = {text=text, code=full_code}
    end
  end
  return rows
end

-- 找钉选别名的正式记录时，先查精确绑定，再检查合法的三声补全。
function M.created_code(item, text, query_code)
  if M.created_contains(item, text, query_code) then return query_code end
  if not core.is_sound_code(query_code, 3) then return nil end
  for _, shape in ipairs(shapes) do
    local code = query_code .. shape
    if M.created_contains(item, text, code) then return code end
  end
end

-- 恢复需要同时处理词序、有效词数和索引存法，统一交给 user_records，避免两处各改一半。
M.restore_word = records.restore_word

function M.acquire_picked(config)
  local path = M.resolve(config:get_string('picked_export/file') or 'white_replace/whitkey_picked.txt')
  local pool = picked_cache[path]
  if not pool then
    pool = M.load(path, 'list', 'picked', config)
    if pool.load_error then
      core.report(nil, '自组词文件无法读取，保留原文件', pool.load_error)
    end
    picked_cache[path] = pool
  end
  pool.refs = pool.refs + 1
  return pool
end

function M.release_picked(pool)
  if pool then release(picked_cache, pool.path) end
end

function M.picked_lookup(pool, code)
  return records.words(pool, code)
end

function M.picked_contains(pool, text, code)
  return records.contains(pool, code, text)
end

function M.picked_remove(pool, word, code)
  local index = records.word_index(pool, code, word)
  if not index then return false, 'not_found' end
  local ok, err = M.change(pool, '删除', code, word)
  return ok, err, index
end

function M.picked_put(pool, word, code)
  if pool.load_error then return false, pool.load_error end
  if type(word) ~= 'string' or word:find('[\t\r\n]') or core.utf8_length(word) < 2
      or type(code) ~= 'string' or not code:match('^[a-z]+$') then
    return false, '自组词或编码格式错误'
  end
  if M.picked_contains(pool, word, code) then return true end
  return M.change(pool, '设置', code, word)
end

-- pinned 每码只保留一个词。同码同词再钉选一次就取消，钉选其他词则替换原来的词。
function M.acquire_pinned(filename, config)
  local path = M.resolve(filename or "white_replace/whitkey_pinned.txt")
  local item = pinned_cache[path]
  if not item then
    item = M.load(path, "map", "pinned", config)
    if item.load_error then
      core.report(nil, "钉选文件无法读取，保留原文件", item.load_error)
    end
    pinned_cache[path] = item
  end
  item.refs = item.refs + 1
  return item, path
end

function M.release_pinned(path)
  release(pinned_cache, path)
end

function M.pinned_get(item, code)
  -- pinned 是 map，每码始终只有一个字符串，不使用 list／set 的多词存法。
  code = core.clean_code(code, true)
  return code ~= "" and item and item.by_code[code] or nil
end

function M.pinned_toggle(item, text, code)
  text, code = core.clean_text(text), core.clean_code(code, true)
  if not item or text == "" or code == "" then return false, "词语或编码为空" end
  if item.load_error then return false, item.load_error end
  local old = item.by_code[code]
  local action = old == text and "removed" or (old and "replaced" or "added")
  local ok, err
  if old == text then ok, err = records.change(item, "删除", code)
  else ok, err = records.change(item, "设置", code, text) end
  if not ok then return false, err end
  return true, action
end

-- 统计等小文件也使用同一套文件恢复和替换步骤。
function M.read_snapshot(path, limit, binary)
  local file, open_err = read_recoverable(path, binary)
  if not file then return nil, open_err end
  local text, read_err = file:read((limit or 4096) + 1)
  local close_ok, close_err = file:close()
  if read_err then return nil, read_err end
  if not close_ok then return nil, close_err or "关闭数据文件失败" end
  if text and #text > (limit or 4096) then return nil, "状态文件超过大小上限" end
  return text or "", open_err
end

function M.write_snapshot(path, text)
  return replace_file(path, function(file)
    local ok, err = file:write(text)
    return ok ~= nil, err
  end)
end

return M
