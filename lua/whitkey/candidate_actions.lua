-- 这里处理当前候选的 Tab 上屏、删除、钉选和“候选＋数字”。
-- 普通输入、追加形码和顶功继续交给后面的 input。

local core = require "whitkey.core"
local store = require "whitkey.data_store"
local personal = require "whitkey.personal_store"
local meta = require "whitkey.candidate"
local state = require "whitkey.input"
local M = {}

---@class CandidateActionsEnv: Env
---@field english_enabled boolean
---@field english_tab_key KeyEvent
---@field page_size integer
---@field english_dictionary table|nil
---@field english_dictionary_path string
---@field hidden table
---@field hidden_path string
---@field created table
---@field created_path string
---@field picked_pool table
---@field fixed_sources table[]
---@field fixed_paths string[]
---@field pinned table
---@field pinned_path string
---@field candidate_remove_trigger KeyEvent
---@field delete_created_trigger KeyEvent
---@field pinned_trigger KeyEvent
---@field unique_digit_enabled boolean
---@field static_memory Memory|nil 仅删除 user_table 候选时创建，用于区分静态词和自组词。

-- Tab 只在当前页找 mix 词库中的候选。直接提交英文，不写入 userdb 或 picked。
local function english_tab(key, env)
  if not env.english_enabled or not key:eq(env.english_tab_key) then return nil end
  local context = env.engine.context
  if state.is(context, state.CREATED_WORD) or not context:has_menu() then return nil end
  local segment, segmentation = state.current_segment(context)
  if not segment or not segment:has_tag("abc") then return nil end
  -- 直接提交会跳过前面已确认的分段，因此这里只处理一个分段覆盖整次输入的情况。
  if not segmentation or segmentation.size ~= 1
      or segment.start ~= 0 or segment._end ~= #(context.input or "") then return nil end
  local code = core.clean_code(state.read_input(context).raw, true)
  if code == "" then return nil end
  -- 第一次处理 Tab 时才读取 Mix 成员表。如果查询模块已加载过同一路径，就直接共用，不再读文件。
  if not env.english_dictionary then
    env.english_dictionary = store.acquire_dictionary(env.english_dictionary_path)
  end
  local selected = tonumber(segment.selected_index) or 0
  local first = math.floor(selected / env.page_size) * env.page_size
  for index = first, first + env.page_size - 1 do
    local candidate = segment:get_candidate_at(index)
    if not candidate then break end
    local info = meta.describe(candidate, code, env.created.symbols)
    local text, assigned, completion = meta.dictionary_query(info)
    if store.dictionary_contains(env.english_dictionary, text, assigned, completion) then
      env.engine:commit_text(candidate.text)
      context:clear()
      return core.kAccepted
    end
  end
  return nil
end

-- Rime 普通用户词使用原编码作键，编码器生成的词会多一个前置标记。
-- 两种键都要精确查找，不能漏掉其中一种，也不需要扫描整个用户词典。
local function native_entries(dictionary, text, codes)
  local entries = {}
  for _, code in ipairs(codes) do
    for _, prefix in ipairs({"", "\127enc\31"}) do
      for entry in dictionary:lookup_words(prefix .. code, false, 0):iter() do
        if entry.text == text then entries[#entries + 1] = entry end
      end
    end
  end
  return entries
end

local function delete_native_word(env, text, codes)
  -- user_dict 的底层对象由 Memory 持有，查找、删除和复查完成后才能 disconnect。
  -- 提前释放 Memory 后再用 user_dict，可能使客户端崩溃。
  local memory = Memory(env.engine, env.engine.schema, "translator")
  local dictionary = memory.user_dict
  if not dictionary then
    memory:disconnect()
    return false, "原生用户词典不可用"
  end
  -- 负学习一次就把该词条标成删除，不是每次只减少一次使用次数。
  local ok, result, err = pcall(function()
    for _, entry in ipairs(native_entries(dictionary, text, codes)) do
      if not dictionary:update_entry(entry, -1, "", dictionary.name) then
        return false, "原生用户词删除失败"
      end
    end
    if #native_entries(dictionary, text, codes) ~= 0 then return false, "原生用户词仍然存在" end
    return true
  end)
  memory:disconnect()
  if not ok then return false, result end
  return result, err
end

-- user_table 可能是普通自组词，也可能是静态词的调频记录。删除这类候选时，先查它的完整词典码。
-- 如果它本来就在静态词典中，就写 hidden；只删调频记录，静态词仍会显示。
local function static_member(env, text, code)
  if not env.static_memory then
    env.static_memory = Memory(env.engine, env.engine.schema, "static_lookup")
  end
  local ok, result = pcall(function()
    if not env.static_memory:dict_lookup(code, false, 0) then return false end
    for entry in env.static_memory:iter_dict() do
      if entry.text == text and (tonumber(entry.remaining_code_length) or 0) == 0 then
        return true
      end
    end
    return false
  end)
  if not ok then return nil, result end
  return result
end

local function delete_personal_word(env, pool, remove, text, code, codes)
  local removed, err, original_index = remove(pool, text, code)
  if not removed then return false, err end
  local deleted, delete_err = delete_native_word(env, text, codes)
  if deleted then return true end
  -- 原生删除失败时，尝试把 TXT 记录放回原来的位置。
  -- 已经删除的原生词频不能完整恢复，因此这一步只能恢复 TXT，不是全部撤销的原子事务。
  local restored, restore_err = personal.restore_word(pool, text, code, original_index)
  return false, restore_err or delete_err or (not restored and "恢复绑定失败")
end

local function related_pin_codes(query_code, storage_code, personal_word, created_word)
  local codes, seen = {}, {}
  local function add(code)
    if code ~= "" and not seen[code] then codes[#codes + 1], seen[code] = code, true end
  end
  add(query_code)
  if personal_word then add(storage_code) end
  -- created 的三声入口从保存的正式码取得。后来即使改了符号设置，删除时也要清掉旧入口上的相关钉选。
  if created_word
      and core.matches_sound_shape(storage_code, 3, 1) then add(storage_code:sub(1, 3)) end
  return codes
end

local function restore_pins(env, text, codes, original_error)
  local err = original_error
  for index = #codes, 1, -1 do
    local code = codes[index]
    local ok, restore_err = personal.pinned_toggle(env.pinned, text, code)
    if not ok then
      err = tostring(err or "删除失败") .. "；钉选恢复失败（" .. code .. "）："
          .. tostring(restore_err)
    end
  end
  return err
end

local function detach_pins(env, text, codes)
  local detached = {}
  for _, code in ipairs(codes) do
    if personal.pinned_get(env.pinned, code) == text then
      local ok, err = personal.pinned_toggle(env.pinned, text, code)
      if not ok then return false, detached, restore_pins(env, text, detached, err) end
      detached[#detached + 1] = code
    end
  end
  return true, detached
end

-- Ctrl+Q 处理当前候选，Shift+Delete 只处理 created。
local function remove_candidate(key, env)
  local created_only = key:eq(env.delete_created_trigger)
  if not created_only and not key:eq(env.candidate_remove_trigger) then return nil end
  local context = env.engine.context
  if created_only and state.is(context, state.CREATED_WORD) then return nil end
  if not context:has_menu() then return nil end
  local segment = state.current_segment(context)
  if not segment or not (segment:has_tag("abc") or segment:has_tag("emoji_mode")) then
    return nil
  end
  local selected = context:get_selected_candidate()
  if not selected then return nil end
  local query_code = core.clean_code(state.read_input(context).raw, true)
  local info = meta.describe(selected, query_code, env.created.symbols)
  local source = info.source
  if info.type == "entry_word" then return created_only and nil or core.kAccepted end
  local storage_code = core.clean_code(info.storage_code or info.code, true)
  local text = source and source.text or ""
  if info.type == "emoji_only" then text = meta.emoji_identity(text) end
  if text == "" or storage_code == "" then return nil end

  local is_created = info.type == "created_word"
      or personal.created_contains(env.created, text, storage_code)
  if created_only and not is_created then return nil end
  local is_picked = not is_created and (info.type == "picked_word"
      or personal.picked_contains(env.picked_pool, text, storage_code))
  local personal_word = is_created or is_picked
  local codes = related_pin_codes(query_code, storage_code, personal_word, is_created)
  local pin_ok, detached, pin_err = detach_pins(env, text, codes)
  if not pin_ok then
    core.report(context, "候选删除或隐藏失败", pin_err)
    return core.kAccepted
  end

  local ok, err
  if is_created then
    ok, err = delete_personal_word(env, env.created, personal.created_remove, text, storage_code, codes)
  elseif is_picked then
    ok, err = delete_personal_word(env, env.picked_pool, personal.picked_remove, text, storage_code, codes)
  elseif info.prepicked and not info.static then
    ok, err = delete_native_word(env, text, {storage_code})
  elseif info.type == "user_table" then
    local static, lookup_err = info.static
    if not info.bucket then static, lookup_err = static_member(env, text, storage_code) end
    if static == nil then
      ok, err = false, lookup_err
    elseif static then
      ok, err = personal.hide(env.hidden, text, query_code)
    else
      ok, err = delete_native_word(env, text, {storage_code})
    end
  else
    ok, err = personal.hide(env.hidden, text, query_code)
  end
  if not ok then
    err = restore_pins(env, text, detached, err)
    core.report(context, "候选删除或隐藏失败", err)
    return core.kAccepted
  end
  context:refresh_non_confirmed_composition()
  return core.kAccepted
end

local function toggle_pin(key, env)
  if not key:eq(env.pinned_trigger) then return nil end
  local context = env.engine.context
  if state.is(context, state.CREATED_WORD) or not context:has_menu() then return nil end
  local segment = state.current_segment(context)
  if not segment or not segment:has_tag("abc") then return nil end
  local candidate = context:get_selected_candidate()
  if candidate and meta.source(candidate).type == "entry_word" then return core.kAccepted end
  local code = core.clean_code(state.read_input(context).raw, true)
  if not candidate or not candidate.text or candidate.text == "" or code == "" then return nil end
  local source = meta.source(candidate)
  local text = source and source.text or candidate.text
  if not text or text == "" or core.utf8_length(text) == 1 then return nil end
  local candidate_type = (source and source.type) or candidate.type or ""
  if meta.is_fixed_type(candidate_type)
      or store.fixed_sources_contains(env.fixed_sources, text, code) then return nil end
  if candidate._end < segment._end then return nil end
  local ok = personal.pinned_toggle(env.pinned, text, code)
  if not ok then
    core.report(context, "候选记录保存失败")
    return core.kAccepted
  end
  context:refresh_non_confirmed_composition()
  return core.kAccepted
end

-- 普通逐字组词即将由 selector 完成时，先把已确认前段改回 kSelected，Rime 才能学习整个词。
local function prepare_learning(key, env)
  local keycode = key.keycode
  local digit = type(keycode) == "number" and keycode >= string.byte("0")
      and keycode <= string.byte("9")
  if not core.is_space(key) and not digit then return end
  local context = env.engine.context
  if state.is(context, state.CREATED_WORD) or not context:has_menu() then return end
  state.prepare_word_creation(context)
end

-- “唯一候选＋数字”只用于一简、630、2625 和 A/U 入口，普通音码候选不使用这个功能。
local function unique_digit(key, env)
  if key:release() or key:shift() or key:ctrl() or key:alt()
      or key:super() or key:caps() then return nil end
  local keycode = key.keycode
  if type(keycode) ~= "number" or not (keycode == string.byte("0")
      or (keycode >= string.byte("2") and keycode <= string.byte("9"))) then return nil end
  local context = env.engine.context
  if not context:has_menu() or state.is(context, state.CREATED_WORD) then return nil end
  local segment, segmentation = state.current_segment(context)
  local input = context.input or ""
  if not segment or not segmentation or segmentation.size ~= 1
      or segment.start ~= 0 or segment._end ~= #input then return nil end
  local candidate = context:get_selected_candidate()
  if not candidate or candidate._end ~= segment._end then return nil end
  local source = meta.source(candidate)
  local text = (source and source.text) or candidate.text or ""
  local code = core.clean_code(state.read_input(context).raw or input, true)
  local entry = source and source.type == "entry_word" and (input == "a" or input == "u")
  local one_sound = core.is_sound_code(code, 1) and core.utf8_length(text) == 1
  local fixed_word = store.fixed_contains(env.fixed_sources[1], text, code)
      or store.fixed_contains(env.fixed_sources[3], text, code)
  if not entry and not one_sound and not fixed_word then return nil end
  if segment:get_candidate_at(1) then return nil end
  state.prepare_word_creation(context)
  local committed = context:confirm_current_selection()
  if committed and context.input ~= "" then committed = context:commit() end
  if not committed then
    core.report(context, "候选与数字上屏失败")
    return core.kAccepted
  end
  env.engine:commit_text(string.char(keycode))
  return core.kAccepted
end

local function install_picked(env)
  local pool = env.picked_pool
  env.picked_connection = env.engine.context.commit_notifier:connect(function(context)
    -- U 提交时，whitkey_explicit_commit 保留到 commit 完成。
    -- 即使模式已经 reset，picked 仍可用这个标记认出 U 提交，避免把自造词另存成普通自组词。
    if state.is(context, state.CREATED_WORD)
        or context:get_property('whitkey_explicit_commit') == '1' then return end
    local current_composition = context.composition
    local segmentation = current_composition and current_composition:toSegmentation()
    local segments = segmentation and segmentation:get_segments() or {}
    if #segments ~= 1 then return end -- 刚逐字组成时先由 Rime 学习，不在这里写 picked。
    local segment, candidate = segments[1], context:get_selected_candidate()
    if not segment:has_tag('abc') or not candidate or candidate.start ~= segment.start
        or candidate._end ~= segment._end or candidate.text ~= context:get_commit_text() then return end
    local info = meta.describe(candidate, state.read_input(context).raw, env.created.symbols)
    -- 第一次逐字组成的词先交给 Rime 学习，后来再次完整选择，才写入 picked TXT。
    -- 已经从 TXT 读出的词不重复保存，补全候选也不另按当前短码保存一遍。
    if info.type == 'picked_word' or info.completion or info.length < 2 then return end
    local bucket = info.bucket
    if bucket ~= 'prepicked' and bucket ~= 'picked' then return end
    local code = core.clean_code(info.code, true)
    local word = info.source and info.source.text or candidate.text
    local ok, err = personal.picked_put(pool, word, code)
    if not ok then core.report(context, '文字已上屏，但自组词保存失败', err) end
  end)
end


function M.init(env)
  local config = env.engine.schema.config
  env.english_enabled = config:get_bool("english_tab/enabled") ~= false
  env.english_tab_key = KeyEvent(config:get_string("english_tab/hotkey") or "Tab")
  env.page_size = math.max(1, config:get_int("menu/page_size") or 6)
  env.english_dictionary_path = store.resolve(
      config:get_string("english_tab/dictionary_file") or "white_dicts/mix.dict.yaml")
  env.hidden_path = personal.resolve(config:get_string("hidden_candidate/store_file")
      or "white_replace/whitkey_hidden.txt")
  env.hidden = personal.acquire_hidden(env.hidden_path, config)
  env.candidate_remove_trigger = KeyEvent(config:get_string("candidate_remove/hotkey") or "Control+q")
  env.delete_created_trigger = KeyEvent("Shift+Delete")
  env.created, env.created_path = personal.acquire_created(
      config:get_string("created_word/store_file") or "white_replace/whitkey_created.txt", config)
  env.picked_pool = personal.acquire_picked(config)
  local _, sources, paths = store.acquire_fixed_sources(config)
  env.fixed_sources, env.fixed_paths = sources, paths
  env.pinned, env.pinned_path = personal.acquire_pinned(
      config:get_string("pinned_candidate/store_file") or "white_replace/whitkey_pinned.txt", config)
  env.pinned_trigger = KeyEvent(config:get_string("pinned_candidate/hotkey") or "Control+p")
  env.unique_digit_enabled = config:get_bool("unique_digit/enabled") ~= false
  install_picked(env)
end

function M.func(key, env)
  if not key or key:release() then return core.kNoop end
  local context = env.engine.context
  if context:get_option("ascii_mode") then return core.kNoop end
  local segment = state.current_segment(context)
  if segment and segment:has_tag("styled_english") then return core.kNoop end
  local result
  if env.unique_digit_enabled then
    result = unique_digit(key, env)
    if result then return result end
  end
  local code = key.keycode
  if code >= 0xffb0 and code <= 0xffb9 then
    local candidate = context:get_selected_candidate()
    local input = context.input
    if candidate and meta.source(candidate).type == "entry_word" then
      if input == "a" then return core.kAccepted end
      if input == "o" then
        context:push_input(tostring(code - 0xffb0))
        return core.kAccepted
      end
    end
  end
  result = english_tab(key, env)
  if result then return result end
  result = remove_candidate(key, env)
  if result then return result end
  result = toggle_pin(key, env)
  if result then return result end
  prepare_learning(key, env)
  return core.kNoop
end

function M.fini(env)
  env.picked_connection:disconnect()
  env.picked_connection = nil
  if env.static_memory then env.static_memory:disconnect() end
  env.static_memory = nil
  if env.english_dictionary then store.release_dictionary(env.english_dictionary_path) end
  personal.release_hidden(env.hidden_path)
  personal.release_created(env.created_path)
  personal.release_picked(env.picked_pool)
  store.release_fixed_sources(env.fixed_paths)
  personal.release_pinned(env.pinned_path)
  env.english_dictionary, env.hidden, env.created, env.picked_pool = nil, nil, nil, nil
  env.fixed_sources, env.fixed_paths, env.pinned = nil, nil, nil
end

return M
