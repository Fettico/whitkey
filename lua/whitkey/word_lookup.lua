-- 普通中文的完整查询流程：读取请求，取各来源，核对匹配，按规则合并，最后输出带身份的候选。
local core = require 'whitkey.core'
local store = require 'whitkey.data_store'
local personal = require 'whitkey.personal_store'
local state = require 'whitkey.input'
local meta = require 'whitkey.candidate'
local M = {}

---@class QueryPlan
---@field segment Segment
---@field code string 当前分段的完整真实编码。
---@field shape string 四声码后追加的形码，没有时为空串。三声补形由 compatibility_codes 处理。
---@field preedit string|nil 仅用于显示的预编辑文字。
---@field finish integer 当前分段结束位置。
---@field prefix_finish integer 拆码首字应消耗到的位置。
---@field split_sound string|nil 四声码的前两声码。
---@field tail_sound string|nil 已选拆码字后的尾段音码。
---@field compatibility_codes string[] 继续补形时需要回查的短精确码。

---@class QueryRecord
---@field candidate Candidate
---@field matched_code string 产生这条原生候选的实际查询码。
---@field finish integer|nil
---@field preedit string|nil
---@field compatible boolean|nil
---@field split_input string|nil

---@class WordLookupEnv: Env
---@field table_translator Translator
---@field fixed_sources table[]
---@field created table
---@field pinned table
---@field picked_pool table
---@field reverse table
---@field shape_max_length integer

function M.init(env, config)
  config = config or env.engine.schema.config
  env.picked_pool = personal.acquire_picked(config)
  env.table_translator = Component.Translator(env.engine, "translator", "table_translator")
  -- X 的首选来自 single 词典，追加项只在初始化时读取 Custom，按列表顺序显示。
  env.x_candidates = {}
  local extras = config:get_list("x_candidates/extra")
  if extras then
    local seen = {}
    for index = 0, extras.size - 1 do
      local value = extras:get_value_at(index)
      local text = value and value:get_string() or ""
      if core.utf8_length(text) == 1 and not seen[text] then
        env.x_candidates[#env.x_candidates + 1] = text
        seen[text] = true
      end
    end
  end
  env.shape_max_length = math.max(
      1, config:get_int("shape_input/max_length") or 4)

  env.dictionary = config:get_string("created_word/dictionary")
      or config:get_string("translator/dictionary") or "enabled_dicts"
  env.reverse = core.acquire_reverse(env.dictionary)
  env.two_part_enabled = config:get_bool("two_part/enabled") ~= false
  if env.two_part_enabled then
    env.two_part_pinyin_dictionary = config:get_string("two_part/pinyin_dictionary") or "pinyin_readings"
  end
  env.shape_cache, env.shape_fifo = {}, {}
  local _, sources, paths = store.acquire_fixed_sources(config)
  env.fixed_sources, env.fixed_paths = sources, paths
  env.created, env.created_path = personal.acquire_created(
      config:get_string("created_word/store_file") or "white_replace/whitkey_created.txt", config)
  env.pinned, env.pinned_path = personal.acquire_pinned(
      config:get_string("pinned_candidate/store_file") or "white_replace/whitkey_pinned.txt", config)
  env.created_quality = config:get_int("created_word/initial_quality") or 200000
  env.hidden_path = personal.resolve(config:get_string('hidden_candidate/store_file')
      or 'white_replace/whitkey_hidden.txt')
  env.hidden = personal.acquire_hidden(env.hidden_path, config)
  env.static_memory = Memory(env.engine, env.engine.schema, 'static_lookup')
  env.static_cache, env.static_fifo = {}, {}
  env.english_enabled = config:get_bool('english_tab/enabled') ~= false
  env.check_mix = not env.english_enabled
      or (config:get_string('candidate_comment/visibility/mix') or 'inherit') ~= 'inherit'
  env.english_dictionary_path = store.resolve(config:get_string('english_tab/dictionary_file')
      or 'white_dicts/mix.dict.yaml')
  env.focus_sources = {}
  if config:get_bool('focus/enabled') == true then
    for index, name in ipairs({'fixed_630', 'duo', 'fixed_2625'}) do
      if config:get_bool('focus/' .. name) ~= false then
        env.focus_sources[#env.focus_sources + 1] = env.fixed_sources[index]
      end
    end
  end

end

function M.fini(env)
  personal.release_hidden(env.hidden_path)
  env.static_memory:disconnect()
  env.static_memory, env.static_cache, env.static_fifo = nil, nil, nil
  if env.english_dictionary then store.release_dictionary(env.english_dictionary_path) end
  env.english_dictionary, env.focus_sources, env.hidden = nil, nil, nil
  personal.release_picked(env.picked_pool)
  env.picked_pool = nil
  store.release_fixed_sources(env.fixed_paths)
  env.fixed_sources, env.fixed_paths = nil, nil
  core.release_reverse(env.dictionary)
  if env.two_part_pinyin then core.release_reverse(env.two_part_pinyin_dictionary) end
  -- 客户端没有 disconnect 接口时，释放 Lua 引用，由原生生命周期回收资源。
  if env.two_part_memory and env.two_part_memory.disconnect then
    env.two_part_memory:disconnect()
  end
  personal.release_created(env.created_path)
  personal.release_pinned(env.pinned_path)
  env.pinned = nil
  env.table_translator, env.reverse, env.shape_cache, env.shape_fifo = nil, nil, nil, nil
  env.two_part_memory, env.two_part_pinyin = nil, nil
  env.created = nil
  env.x_candidates = nil
end

-- 第一步：读取当前编码、形码和分段范围，生成 QueryPlan。
---@param view InputView
---@return QueryPlan
local function build_query_plan(view)
  local prefix_length = 2
  local plan = {
    segment=view.segment, code=view.raw, shape=view.shape_suffix,
    preedit=view.preedit, finish=view.segment._end,
    prefix_finish=view.segment.start + prefix_length,
    compatibility_codes={},
  }
  if view.full_composition and #view.sound > prefix_length then
    plan.split_sound = view.sound:sub(1, prefix_length)
  end
  if view.tail_sound and view.tail_shape == '' then plan.tail_sound = view.tail_sound end
  if #plan.code >= 4 and #plan.code <= 6 and core.is_shape_key(plan.code:sub(-1)) then
    local sound, shape = view.sound, view.shape
    local shortest_prefix = math.max(3, #plan.code - 2)
    -- 三字词可在三声码后逐字补三位形码；输满六码时仍需回查三声基础码。
    if sound and #sound == 3 and #shape == 3 then shortest_prefix = 3 end
    for length = shortest_prefix, #plan.code - 1 do
      plan.compatibility_codes[#plan.compatibility_codes + 1] = plan.code:sub(1, length)
    end
  end
  return plan
end

-- 第二步：调用原生词典，检查追加形码是否匹配。
-- 五个形码按 core.shape_keys 顺序转换成二进制位。修改键位时只核对这一个来源，不在多个 Lua 各写一份列表。
local SHAPE_BITS = {}
do
  local bit = 1
  for i = 1, #core.shape_keys do
    SHAPE_BITS[core.shape_keys:sub(i, i)] = bit
    bit = bit * 2
  end
end

-- 学过的用户单字按 quality 排序，只在这些单字原来的位置上交换。其他候选不动，词组和静态候选不参与这次排序。
local function sort_learned_singles(rows)
  if #rows < 2 then return end
  local slots, singles = {}, {}
  for i, candidate in ipairs(rows) do
    if core.utf8_length(candidate.text) == 1 then
      slots[#slots + 1] = i
      singles[#singles + 1] = {candidate=candidate, order=i}
    end
  end
  table.sort(singles, function(a, b)
    if a.candidate.quality ~= b.candidate.quality then
      return a.candidate.quality > b.candidate.quality
    end
    return a.order < b.order
  end)
  for i, row in ipairs(singles) do rows[slots[i]] = row.candidate end
end

  -- 原生查询抛错时，记录错误并结束本次查询，下次输入仍可尝试。
local function query_dictionary(translator, input, segment)
  local ok, translation = pcall(function() return translator:query(input, segment) end)
  if not ok then
    core.report(nil, "词典查询失败", translation)
    return nil
  end
  if not translation or core.is_sound_code(input, 1) then return translation end
  -- TableTranslation 先给用户补全，再给静态补全，用 custom_code 是否为空来区分，不能凭 quality 猜是否学过。
  -- 用户补全可能超过一页，要收齐用户部分再排序，静态补全仍按需读取。
  return {iter=function()
    return coroutine.wrap(function()
      local pending, completed = nil, false
      local function flush()
        if not pending then return end
        sort_learned_singles(pending)
        for _, candidate in ipairs(pending) do coroutine.yield(candidate) end
        pending = nil
      end
      for candidate in translation:iter() do
        if not completed and meta.is_completion(candidate) then
          local entry = meta.entry(candidate)
          if entry and (entry.custom_code or '') ~= '' then
            pending = pending or {}
            pending[#pending + 1] = candidate
          else
            flush()
            completed = true
            coroutine.yield(candidate)
          end
        else
          coroutine.yield(candidate)
        end
      end
      flush()
    end)
  end}
end

-- 反查原始结果由 core 共享缓存，最多保留 256 项。
local function cached_reverse(env, text)
  return core.reverse_codes(env.reverse, text)
end

-- 先查首声母对应的一简精确项，再用完整反查码验证音码和形码。
-- 保留原生 Phrase 和两码消耗范围，后续编码器才能继续学习逐字组合。
local function query_short_singles(sound, shape, segment, env)
  local result = {}
  if not core.is_sound_code(sound, 2) then return result end
  local translation = query_dictionary(env.table_translator, sound:sub(1, 1), segment)
  if not translation then return result end
  for candidate in translation:iter() do
    if meta.is_completion(candidate) then break end
    if core.utf8_length(candidate.text) == 1 then
      for code in cached_reverse(env, candidate.text):gmatch("[a-z]+") do
        if #code >= #sound + #shape and code:sub(1, #sound + #shape) == sound .. shape then
          result[#result + 1] = {candidate=candidate,
              finish=segment.start + #sound,
              preedit=state.shape_preedit(env.engine.context, sound, shape), matched_code=sound:sub(1, 1)}
          break
        end
      end
    end
  end
  return result
end

-- 反查这个汉字的全部编码，把第三位形码汇总成位掩码，并按字缓存结果。
local function shape_mask(env, character)
  local cached = env.shape_cache[character]
  if cached ~= nil then return cached end
  local mask = 0
  local value, ok = core.reverse_codes(env.reverse, character)
  if not ok then return nil end -- 查询失败不缓存，这次先跳过形码匹配，下次再试。
  for code in value:gmatch("[a-z;]+") do
    local bit = SHAPE_BITS[code:sub(3, 3)]
    if bit and mask % (bit * 2) < bit then mask = mask + bit end
  end
  env.shape_cache[character] = mask
  local slot = (env.shape_cursor or 0) % 256 + 1
  local expired = env.shape_fifo[slot]
  if expired then env.shape_cache[expired] = nil end
  env.shape_fifo[slot], env.shape_cursor = character, slot
  return mask
end

-- 从缓存的位掩码检查这个字是否有指定的第一笔形码。
local function has_shape(env, character, shape)
  local bit = SHAPE_BITS[shape]
  if not bit then return false end
  local mask = shape_mask(env, character)
  return mask ~= nil and mask % (bit * 2) >= bit
end

-- 三字词可按每字一位补三位形码；其他词组最多补两位。
-- 这个限制用于词组逐字补形，不是单字补形的总上限。
local function valid_suffix(code, base_length)
  local suffix = code:sub(base_length + 1)
  local max_length = base_length == 3 and 3 or 2
  return core.is_shape_code(suffix, 1, max_length) and suffix or nil
end

-- 短码回查必须同时满足音码和形码。原生编码器会跳过缺失的码位，因此短来源码本身不能证明音码匹配。
-- 两字纯汉字词补足四声时，逐字核对完整双拼；三声三字词仍保留自己的简码规则。
local function matches_extended(text, full_code, assigned_code, env)
  local base_length = core.word_base_length(text)
  if not base_length or #full_code <= base_length then return false end
  local suffix = valid_suffix(full_code, base_length)
  if not suffix then return false end
  if #assigned_code < base_length and core.utf8_length(text) == 2
      and meta.text_class(text) == 'pure_han' then
    for index = 1, 2 do
      local expected = full_code:sub(index * 2 - 1, index * 2)
      local matched = false
      for _, sound in ipairs(core.sound_codes(env.reverse, core.character_at(text, index))) do
        if sound == expected then
          matched = true
          break
        end
      end
      if not matched then return false end
    end
  end
  for index = 1, #suffix do
    if not has_shape(env, core.character_at(text, index), suffix:sub(index, index)) then return false end
  end
  return true
end

-- 回查当前完整码之前的短精确码，只输出追加形码相符的兼容候选。词典和个人表共用后续排序与去重。
local function compatible_candidates(plan, env)
  return coroutine.wrap(function()
    local full_code = plan.code
    for _, code in ipairs(plan.compatibility_codes) do
      local translation = query_dictionary(env.table_translator, code, plan.segment)
      if translation then
        for candidate in translation:iter() do
          if meta.is_completion(candidate) then break end
          if matches_extended(candidate.text, full_code, code, env) then
            -- 候选覆盖当前整段输入，显示也要覆盖整段。四声码沿用形码格式，
            -- 其他兼容项显示完整查询码，不能沿用回查短码的 preedit。
            coroutine.yield({candidate=candidate,
                finish=plan.finish, preedit=plan.preedit or plan.code, compatible=true, matched_code=code})
          end
        end
      end
    end
  end)
end

-- 每条记录保留产生它的查询码。描述身份时不会把缺失的来源码冒充成当前完整输入。
local function emit_candidate(record)
  yield(record)
end

-- 第三步：依次取得各来源的候选记录，末尾统一检查、分类和去重。

local function emit_local(plan, env)
  for source_index, source in ipairs(env.fixed_sources) do
    local words = source.dict[plan.code]
    if words then
      for _, text in ipairs(words) do
        emit_candidate({candidate=Candidate(meta.fixed_type(source_index), plan.segment.start, plan.finish, text, ''),
            preedit=plan.preedit or plan.code})
      end
    end
  end
  local code = core.clean_code(plan.code)
  local created_words = code ~= '' and personal.created_lookup(env.created, code)
  if created_words or #plan.compatibility_codes > 0 then
    local created_seen = {}
    local function emit_created(storage_code, compatible, words)
      for index, text in ipairs(words or personal.created_lookup(env.created, storage_code) or {}) do
        local coding_text = core.created_code_text(text, env.created.symbols)
        if not created_seen[text]
            and (not compatible or matches_extended(coding_text, plan.code, storage_code, env)) then
          created_seen[text] = true
          local candidate = Candidate(meta.personal_type('created_word', storage_code),
              plan.segment.start, plan.finish, text, '')
          candidate.quality = env.created_quality - index
          emit_candidate({candidate=candidate,
              preedit=compatible and (plan.preedit or plan.code) or plan.preedit,
              compatible=compatible})
        end
      end
    end
    if created_words then emit_created(code, false, created_words) end
    -- 自造词也支持按现有保存码继续补形；只查当前编码对应的索引项，再核对新增形码。
    for index = #plan.compatibility_codes, 1, -1 do
      local prefix = plan.compatibility_codes[index]
      if prefix ~= code then emit_created(prefix, true) end
    end
  end
  -- TXT 精确词和补形相符的兼容词都先于原生补全输出。
  -- 先用当前完整码的记录，同一个 picked 词不重复输出。
  local picked_seen = {}
  local function emit_picked(code, compatible)
    for _, text in ipairs(personal.picked_lookup(env.picked_pool, code) or {}) do
      if not picked_seen[text] and (not compatible or matches_extended(text, plan.code, code, env)) then
        picked_seen[text] = true
        emit_candidate({candidate=Candidate(meta.personal_type('picked_word', code),
            plan.segment.start, plan.finish, text, ''),
            preedit=plan.preedit or plan.code, compatible=compatible})
      end
    end
  end
  emit_picked(plan.code, false)
  for _, code in ipairs(plan.compatibility_codes) do emit_picked(code, true) end
  local pinned = personal.pinned_get(env.pinned, plan.code)
  if pinned then
    -- 三声钉选只是另一个查询入口，created 候选仍携带正式保存码，删除时才能找到原记录。
    local saved = personal.created_code(env.created, pinned, plan.code)
    local kind = saved and 'created_word' or 'pinned'
    emit_candidate({candidate=Candidate(meta.personal_type(kind, saved or plan.code),
        plan.segment.start, plan.finish, pinned, ''),
        preedit=plan.preedit or plan.code})
  end
end

-- 普通拆码候选按需产生，保留原生 Phrase 和查询顺序。翻到后页时，才继续取得后面的候选。
local function single_stream(plan, env)
  return coroutine.wrap(function()
    if not plan.split_sound then return end
    local seen = {}
    for _, record in ipairs(query_short_singles(plan.split_sound, plan.shape, plan.segment, env)) do
      seen[record.candidate.text] = true
      coroutine.yield(record)
    end
    local translation = query_dictionary(env.table_translator, plan.split_sound .. plan.shape, plan.segment)
    if translation then
      for candidate in translation:iter() do
        if core.utf8_length(candidate.text) == 1 and not seen[candidate.text] then
          seen[candidate.text] = true
          coroutine.yield({candidate=candidate, matched_code=plan.split_sound .. plan.shape})
        end
      end
    end
  end)
end

-- 未追加形码时，把两码拆字分成精确项和补全项。Rime 先给精确项，再给 Completion，因此只先读精确部分。
-- 补全继续按需读取，不一次读完全部拆码单字。
local function split_single_streams(plan, env)
  local exact, seen = {}, {}
  if not plan.split_sound then return exact, function() return nil end end
  for _, record in ipairs(query_short_singles(plan.split_sound, '', plan.segment, env)) do
    seen[record.candidate.text] = true
    exact[#exact + 1] = record
  end
  local translation = query_dictionary(env.table_translator, plan.split_sound, plan.segment)
  if not translation then return exact, function() return nil end end
  local iterator, iterator_state, iterator_control = translation:iter()
  local function next_candidate()
    local candidate = iterator(iterator_state, iterator_control)
    iterator_control = candidate
    return candidate
  end
  local first_completion
  while true do
    local candidate = next_candidate()
    if not candidate then break end
    if core.utf8_length(candidate.text) == 1 and not seen[candidate.text] then
      seen[candidate.text] = true
      local record = {candidate=candidate, matched_code=plan.split_sound}
      if meta.is_completion(candidate) then
        first_completion = record
        break
      end
      exact[#exact + 1] = record
    end
  end
  -- 没有遇到第一个补全单字，说明上面已经读完全部候选。
  -- 这时返回空流，不能再调用已经结束的 coroutine。
  if not first_completion then return exact, function() return nil end end
  local completions = coroutine.wrap(function()
    coroutine.yield(first_completion)
    while true do
      local candidate = next_candidate()
      if not candidate then return end
      if core.utf8_length(candidate.text) == 1 and not seen[candidate.text] then
        seen[candidate.text] = true
        coroutine.yield({candidate=candidate, matched_code=plan.split_sound .. plan.shape})
      end
    end
  end)
  return exact, completions
end

-- 第一次合法两分查询时才创建两分 Memory 和 translator，没有用两分的会话不提前初始化它们。
local function ensure_two_part(env)
  if env.two_part_memory then return end
  env.two_part_memory = Memory(env.engine, env.engine.schema, "two_part")
  env.two_part_pinyin = core.acquire_reverse(env.two_part_pinyin_dictionary)
end

-- 两分只查完整四音码，不连接用户词典，候选覆盖完整输入。
-- 结果放在精确拆码单字后、补全拆码单字前。精确拆码已显示的字，两分不再重复输出。
local function emit_two_part(plan, env, seen)
  if not env.two_part_enabled or plan.shape ~= ''
      or not core.is_sound_code(plan.code, 4) then return end
  ensure_two_part(env)
  local rows = {}
  local ok, err = pcall(function()
    if not env.two_part_memory:dict_lookup(plan.code, false, 0) then return end
    for entry in env.two_part_memory:iter_dict() do
      local text = entry.text or ''
      if (tonumber(entry.remaining_code_length) or 0) == 0
          and core.utf8_length(text) == 1 and not seen[text] then
        seen[text] = true
        rows[#rows + 1] = {text=text, weight=tonumber(entry.weight) or 0}
      end
    end
  end)
  if not ok then
    core.report(nil, "两分查字失败", err)
    return
  end
  table.sort(rows, function(a, b)
    if a.weight ~= b.weight then return a.weight > b.weight end
    return a.text < b.text
  end)
  for _, row in ipairs(rows) do
    local pinyin = core.reverse_codes(env.two_part_pinyin, row.text)
    local candidate = Candidate('two_part', plan.segment.start, plan.finish,
        row.text, pinyin)
    candidate.quality = row.weight
    emit_candidate({candidate=candidate, matched_code=plan.code})
  end
end

local function emit_x_extras(plan, env)
  if plan.code ~= "x" then return end
  for _, text in ipairs(env.x_candidates) do
    emit_candidate({candidate=Candidate("single_key_extra", plan.segment.start,
        plan.finish, text, ""), preedit="x"})
  end
end

-- 带形码时先收集符合形码的拆码单字。这里要读完整条单字流，避免漏掉排在后面但符合形码的字。
local function collect_shape_singles(plan, env)
  if plan.shape == '' then return nil, nil end
  local records, allowed = {}, {}
  for record in single_stream(plan, env) do
    records[#records + 1] = record
    allowed[record.candidate.text] = true
  end
  local index = 0
  return function()
    index = index + 1
    return records[index]
  end, allowed
end

-- 当前逐字尾段和短码兼容词，先于当前完整码的查询结果输出。
local function emit_compatible(plan, env)
  if plan.tail_sound then
    for _, record in ipairs(query_short_singles(plan.tail_sound, '', plan.segment, env)) do
      record.compatible = true
      emit_candidate(record)
    end
  end
  for record in compatible_candidates(plan, env) do emit_candidate(record) end
end

-- 用完整当前码查 Rime。追加形码只筛选拆码单字。
-- 完整码直接查到的单字或词组，仍保留 Rime 的原查询结果。
local function emit_direct(plan, env, allowed)
  local direct = query_dictionary(env.table_translator, plan.code, plan.segment)
  local extras_emitted = false
  local created_rows = personal.created_completions(env.created, plan.code)
  local created_by_text
  if created_rows then
    created_by_text = {}
    for _, row in ipairs(created_rows) do created_by_text[row.text] = row.code end
  end
  local created_emitted = false
  local function emit_created()
    if not created_rows or created_emitted then return end
    created_emitted = true
    for _, row in ipairs(created_rows) do
      emit_candidate({candidate=Candidate(meta.personal_type('created_completion', row.code),
          plan.segment.start, plan.finish, row.text, '~' .. row.code:sub(#plan.code + 1)),
          preedit=plan.code})
    end
  end
  if direct then
    for candidate in direct:iter() do
      local completion = meta.is_completion(candidate)
      -- 先输出完精确候选，再输出 created 的三声补全，然后才到普通补全。
      if completion then emit_created() end
      -- 一简过滤遇到第一个补全就停止，因此 X 追加字必须在补全前输出，否则 Custom 中的追加字无法显示。
      if plan.code == "x" and not extras_emitted and completion then
        emit_x_extras(plan, env)
        extras_emitted = true
      end

      local single = plan.shape ~= '' and core.utf8_length(candidate.text) == 1
      local exact_single = false
      if single and not completion then
        for code in cached_reverse(env, candidate.text):gmatch("[a-z]+") do
          if code == plan.code then
            exact_single = true
            break
          end
        end
      end
      -- U 原生编码器有时也会生成三声记录，这些词由 created 统一输出，避免另显示成 prepicked。
      -- 已经有独立 picked 绑定时仍保留该绑定，静态 table 精确候选也照常输出。
      local native_copy = created_by_text and created_by_text[candidate.text]
          and candidate.type == 'user_table'
          and not personal.picked_contains(env.picked_pool, candidate.text, plan.code)
      if not native_copy and (plan.shape == '' or not single or exact_single
          or allowed[core.first_character(candidate.text)]) then
        if plan.shape ~= '' then
          candidate._end, candidate.preedit = plan.finish, plan.preedit
        end
        local split_input = plan.split_sound and candidate._end == plan.prefix_finish
            and core.utf8_length(candidate.text) == 1 and plan.code or nil
        emit_candidate({candidate=candidate, matched_code=plan.code, split_input=split_input})
      end
    end
  end
  if not extras_emitted then emit_x_extras(plan, env) end
  emit_created()
end

-- 完整候选输出后，依次接上拆码单字、两分字和拆码补全。
local function emit_split_singles(plan, env, singles)
  if plan.shape ~= '' then
    for record in singles do
      -- 拆码首字只消耗前两声码，Rime 会把剩余的后两声码和形码显示在后面。
      -- 这里明确写前两声码，不沿用单字查询的 candidate.preedit，避免形码重复拼接，出现 bbviemvi 这样的显示。
      record.finish, record.preedit = plan.prefix_finish, plan.split_sound
      record.split_input = plan.code
      emit_candidate(record)
    end
  else
    local exact, completions = split_single_streams(plan, env)
    local seen = {}
    for _, record in ipairs(exact) do
      seen[record.candidate.text] = true
      record.split_input = plan.code
      emit_candidate(record)
    end
    emit_two_part(plan, env, seen)
    for record in completions do
      record.split_input = plan.code
      emit_candidate(record)
    end
  end
end

local function cache_static(env, code)
  code = core.clean_code(code, true)
  if code == "" then return { texts={}, has_single=false } end
  if env.static_cache[code] then return env.static_cache[code] end
  local result = { texts={}, has_single=false }
  local ok, err = pcall(function()
    if env.static_memory:dict_lookup(code, false, 0) then
      for entry in env.static_memory:iter_dict() do
        if (tonumber(entry.remaining_code_length) or 0) == 0 and entry.text and entry.text ~= "" then
          result.texts[entry.text] = true
          if core.utf8_length(entry.text) == 1 then result.has_single = true end
        end
      end
    end
  end)
  if not ok then
    core.report(nil, "静态词典查询失败，将在下次查询时重试", err)
    return {texts={}, has_single=false}
  end
  env.static_cache[code] = result
  local slot = (env.static_cursor or 0) % 256 + 1
  local expired = env.static_fifo[slot]
  if expired then env.static_cache[expired] = nil end
  env.static_fifo[slot], env.static_cursor = code, slot
  return result
end

-- 原生 user_table 也可能是静态词的调频副本。只在这种不确定的来源上查静态成员。
local function static_exact(info, env)
  if info.completion then return false end
  if info.type == 'table' then return true end
  if info.type ~= 'user_table' then return false end
  return cache_static(env, info.code).texts[info.source.text] == true
end

local function english_member(info, env)
  if not env.english_dictionary then
    env.english_dictionary = store.acquire_dictionary(env.english_dictionary_path)
  end
  local text, code, completion = meta.dictionary_query(info)
  return store.dictionary_contains(env.english_dictionary, text, code, completion)
end

local function visible(info, plan, mode, env, static)
  local text = info.source.text
  if personal.hidden_contains(env.hidden, text, plan.code) then return false end
  local focused, at_fixed_code = false, false
  for _, source in ipairs(env.focus_sources) do
    if source.reverse[text] then
      focused = true
      if store.fixed_contains(source, text, plan.code) then
        at_fixed_code = true
        break
      end
    end
  end
  if focused and not at_fixed_code then return false end
  -- 关闭英文、覆盖 Mix 旁注，或判断两码精确英文时，才需要核对成员表。
  -- 用词语和实际编码查表，不根据文字外观猜来源。默认显示不为这一步提前加载 Mix 索引。
  local exact_word = info.length > 1 and not info.completion and not info.compatible
  if env.check_mix or (mode == 'single_code' and exact_word) then info.mix = english_member(info, env) end
  if info.mix and not env.english_enabled then return false end
  local exact = mode == 'three_sound' and not info.compatible and not info.completion
      and static.texts[text] == true
  return meta.allows(info, mode, plan.code, exact)
end

local function shape_rank(info, code, env)
  local text = info.source.text
  local coding_text = info.type == 'created_word' and core.created_code_text(text, env.created.symbols) or text
  local base = core.word_shape_suffix(coding_text, code)
  if not base then return nil end
  local shortest
  local function consider(assigned)
    if assigned and #assigned >= base and #assigned <= #code and code:sub(1, #assigned) == assigned then
      shortest = math.min(shortest or #assigned, #assigned)
    end
  end
  for assigned in cached_reverse(env, text):gmatch('[a-z]+') do consider(assigned) end
  consider(info.source_code)
  return shortest
end

-- 身份、是否允许显示和排序层在这一步一起确定。后续显示和候选动作不再各自推断。
local function describe(record, plan, mode, env, static)
  local candidate = record.candidate
  if record.finish then candidate._end = record.finish end
  if record.preedit then candidate.preedit = record.preedit end
  local matched_code = record.matched_code or plan.code
  local info = meta.describe(candidate, matched_code, env.created.symbols)
  info.compatible, info.split_input = record.compatible == true, record.split_input
  if not visible(info, plan, mode, env, static) then return nil end
  info.static = static_exact(info, env)
  info.bucket = meta.bucket(info, info.static,
      personal.created_contains(env.created, info.source.text, plan.code),
      personal.picked_contains(env.picked_pool, info.source.text, info.code))
  if info.source.text == personal.pinned_get(env.pinned, plan.code) and info.length > 1
      and info.bucket ~= 'fixed' and not store.fixed_sources_contains(env.fixed_sources, info.source.text, plan.code) then
    info.bucket = 'pinned'
    -- 同码有真实 Phrase 时用它学习，钉选别名只负责补足没有原生候选的情况。
    if info.type == 'pinned' then info.compatible = true end
  end
  if core.is_shape_key(plan.code:sub(-1)) then info.shape_rank = shape_rank(info, plan.code, env) end
  return info
end

local function raw_candidates(plan, env)
  return coroutine.wrap(function()
    emit_local(plan, env)
    local singles, allowed = collect_shape_singles(plan, env)
    emit_compatible(plan, env)
    emit_direct(plan, env, allowed)
    emit_split_singles(plan, env, singles)
  end)
end

function M.translate(input, segment, env)
  if input == '' then return end
  local view = state.read_input(env.engine.context, segment, input, env.shape_max_length)
  local plan = build_query_plan(view)
  local static = cache_static(env, plan.code)
  local mode = meta.resolve(plan.code, env.engine.context:get_option('danzi_mode'), static.has_single)
  local collector, emitted, flushed = meta.new_collector(), {}, false
  local function output(info)
    local identity = meta.identity(info.candidate)
    if emitted[identity] then return end
    emitted[identity] = true
    local candidate = meta.mark(info)
    core.decorate(candidate, env.engine.context)
    yield(candidate)
  end
  local function flush()
    if flushed then return end
    flushed = true
    for _, info in ipairs(meta.ordered(collector, core.is_shape_key(plan.code:sub(-1)))) do output(info) end
  end
  for record in raw_candidates(plan, env) do
    local info = describe(record, plan, mode, env, static)
    if info then
      local appended = info.length == 1 and #plan.code >= 4 and info.candidate._end < segment._end
      if info.completion or appended then flush() end
      if flushed then output(info) else meta.collect(collector, info) end
    elseif mode == 'one_sound' and meta.is_completion(record.candidate) then
      break
    end
  end
  flush()
end
return M
