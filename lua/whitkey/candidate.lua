-- 候选身份、显示权限和排序规则。这里只处理传入的数据，不读文件，也不保存学习记录。
local core = require "whitkey.core"
local M = {}
local ENCODED_PREFIX = "\127enc\31"
local PERSONAL_SEPARATOR = "\31"
local FIXED_KINDS = {"fixed_630", "duo", "fixed_2625"}
local FIXED_TYPES = {fixed_630=true, duo=true, fixed_2625=true}

---@class CandidateInfo
---@field source Candidate 未被显示包装替换的底层候选。
---@field compatible boolean 是否来自继续补形时的短码兼容查询。
---@field type string 规范化后的来源类型。
---@field fixed_kind string|nil fixed_630、duo 或 fixed_2625。
---@field raw_type string 底层候选原始类型。
---@field storage_code string|nil created、picked、pinned 实际保存使用的编码。
---@field text string 当前显示文字。
---@field text_class string pure_han、latin、mixed 或 other。
---@field length integer Unicode 字符数量。created 分类时先跳过编码为空的符号。
---@field code string|nil 原生来源码、个人保存码，或产生此候选的明确查询码。
---@field matched_code string|nil 产生这条候选的实际查询码，不由显示文字推算。
---@field bucket string|nil 查询出口确定的排序层。
---@field split_input string|nil 拆码首字所属的完整原码。
---@field static boolean|nil 是否为静态精确词，删除时不能当作纯用户词移除。
---@field source_code string|nil 词典项携带的编码。
---@field prepicked boolean 是否属于尚未再次完整选择确认的普通自组词。
---@field created_completion boolean 三声补全仍指向 created 的正式保存码。
---@field mix boolean|nil 查询时确定的 Mix 成员身份。
---@field completion boolean 是否仍有未输入完的编码。
function M.fixed_type(index) return FIXED_KINDS[index] end
function M.is_fixed_type(kind) return kind == "fixed" or FIXED_TYPES[kind] == true end

-- 原生候选不能附加任意 Lua 字段。只在这个位置编码身份，跨简繁和选择时从同一个入口读回。
-- 旁注始终只用于显示。底层 Phrase 由 Shadow 保留，原生学习仍能取得原词典项。
local ID_PREFIX, ID_SEP = 'whitkey@', '\30'
local function decode_identity(value)
  if value:sub(1, #ID_PREFIX) ~= ID_PREFIX then return nil end
  local fields = {}
  for item in (value:sub(#ID_PREFIX + 1) .. ID_SEP):gmatch('(.-)' .. ID_SEP) do
    fields[#fields + 1] = item
  end
  local flags = fields[6]
  return {
    tag=value,
    type=fields[1], bucket=fields[2],
    source_code=fields[3] ~= '' and fields[3] or nil,
    matched_code=fields[4] ~= '' and fields[4] or nil,
    storage_code=fields[5] ~= '' and fields[5] or nil,
    compatible=flags:find('c', 1, true) ~= nil,
    completion=flags:find('p', 1, true) ~= nil,
    prepicked=flags:find('n', 1, true) ~= nil,
    created_completion=flags:find('t', 1, true) ~= nil,
    mix=flags:find('m', 1, true) ~= nil,
    static=flags:find('s', 1, true) ~= nil,
    split_input=fields[7] ~= '' and fields[7] or nil,
    length=tonumber(fields[8]),
    text_class=fields[9],
  }
end

function M.tag(info)
  -- 读回的身份没有改变，显示包装直接沿用查询时写下的标记。
  if info.tag then return info.tag end
  local flags = (info.compatible and 'c' or '') .. (info.completion and 'p' or '')
      .. (info.prepicked and 'n' or '') .. (info.created_completion and 't' or '')
      .. (info.mix and 'm' or '') .. (info.static and 's' or '')
  return ID_PREFIX .. table.concat({info.type, info.bucket, info.source_code or '',
      info.matched_code or '', info.storage_code or '', flags, info.split_input or '',
      tostring(info.length), info.text_class}, ID_SEP)
end

function M.mark(info)
  local kind = M.tag(info)
  local candidate = info.candidate
  local result = ShadowCandidate(info.source, kind, candidate.text, candidate.comment or '', false)
  result.start, result._end = candidate.start, candidate._end
  result.preedit, result.quality = candidate.preedit, candidate.quality
  return result
end

-- simplifier、uniquifier 和纯白的身份标记都可能包在候选外面。
-- 这里从外到内找一次，取出底层 Phrase、拆码原码和兼容标记，其他模块不用再各找一遍。
function M.unwrap(candidate)
  local current, split_input, compatible = candidate, nil, false
  local metadata
  for _ = 1, 16 do
    if not current then break end
    local candidate_type = current.type or ""
    local identity = decode_identity(candidate_type)
    if identity then
      split_input = split_input or identity.split_input
      compatible = compatible or identity.compatible
      metadata = metadata or identity
    end
    if not current.get_genuine then break end
    if current.get_dynamic_type then
      local kind = current:get_dynamic_type()
      if kind ~= "Shadow" and kind ~= "Uniquified" then break end
    end
    local source = current:get_genuine()
    if not source or source == current then break end
    current = source
  end
  return current, split_input, compatible, metadata
end

function M.source(candidate)
  return M.unwrap(candidate)
end

-- 只有提供 to_phrase 的原生候选才可能带有词典项。查询、过滤和按键模块都从这里读取，不各自拆候选。
function M.entry(candidate, source)
  source = source or M.source(candidate)
  if not source or not source.to_phrase then return nil end
  local phrase = source:to_phrase()
  return phrase and phrase.entry or nil
end

function M.is_completion(candidate)
  local source = M.source(candidate)
  if not source then return true end
  if source.type == "completion" or candidate.type == "completion"
      or (source.type or ""):match("^created_completion" .. PERSONAL_SEPARATOR) then return true end
  local entry = M.entry(candidate, source)
  if not entry then return false end
  local remaining = tonumber(entry.remaining_code_length)
  return remaining ~= nil and remaining > 0
end

-- Lua 生成个人候选时，把正式保存码写进内部 type，describe 再读出来源类型和保存码。
-- 删除或钉选直接使用保存码，不根据当前短输入猜测。
function M.personal_type(kind, code)
  return kind .. PERSONAL_SEPARATOR .. code
end

local function decode_personal_type(value)
  local kind, code = (value or ""):match("^([^" .. PERSONAL_SEPARATOR .. "]+)"
      .. PERSONAL_SEPARATOR .. "([a-z;`]+)$")
  if kind == "created_completion" then return "created_word", code, true end
  if kind == "created_word" or kind == "picked_word" or kind == "pinned" then
    return kind, code, false
  end
  return value or "", nil
end
function M.prepicked_code(code)
  if type(code) ~= "string" or code:sub(1, #ENCODED_PREFIX) ~= ENCODED_PREFIX then return nil end
  local value = core.clean_code(code:sub(#ENCODED_PREFIX + 1), true)
  return value ~= "" and value or nil
end

function M.split_input(candidate)
  local _, input = M.unwrap(candidate)
  return input
end

function M.identity(candidate)
  return (candidate.text or "") .. "\0" .. tostring(candidate.start) .. ":" .. tostring(candidate._end)
end

-- 单个 Emoji 后的可选 FE0F 只改变显示形式，去重和隐藏把这两种写法认成同一个表情。
-- 多字符序列仍完整保留，不拆掉 ZWJ、肤色或键帽组合。
function M.emoji_identity(text)
  if utf8.len(text) == 2 and text:sub(-3) == "️" then return text:sub(1, -4) end
  return text
end

-- 文字中只要有非汉字，就不属于 pure_han。
-- C盘、哆O、BGM、3D打印和带符号词因此不受纯汉字简码字数限制。
function M.text_class(text)
  if not core.valid_text(text) then return "other", 0 end
  local count, han_count, latin_count = 0, 0, 0
  for _, point in utf8.codes(text) do
    count = count + 1
    if core.is_han_codepoint(point) then
      han_count = han_count + 1
    elseif (point >= 0x41 and point <= 0x5A) or (point >= 0x61 and point <= 0x7A) then
      latin_count = latin_count + 1
    end
  end
  if count == 0 then return "other", 0 end
  if han_count == count then return "pure_han", count end
  if latin_count == count then return "latin", count end
  return "mixed", count
end

-- 把候选信息整理成 CandidateInfo，调用方直接读取这些字段。
---@return CandidateInfo
function M.describe(candidate, matched_code, symbols)
  local source, split_input, compatible, identity = M.unwrap(candidate)
  if identity then
    identity.source, identity.candidate = source, candidate
    identity.text, identity.raw_type = candidate.text, source.type
    identity.fixed_kind = FIXED_TYPES[source.type] and source.type or nil
    identity.code = identity.source_code or identity.storage_code or identity.matched_code
    return identity
  end
  local entry = M.entry(candidate, source)
  local custom_code, remaining = "", 0
  if entry then
    custom_code = entry.custom_code or ""
    remaining = tonumber(entry.remaining_code_length) or 0
  end
  local prepicked = M.prepicked_code(custom_code)
  local source_code = prepicked or core.clean_code(custom_code, true)
  if source_code == "" then source_code = nil end
  local raw_type = (source and source.type) or candidate.type or ""
  local candidate_type, storage_code, created_completion = decode_personal_type(raw_type)
  local text = candidate.text or ""
  local coding_text = candidate_type == "created_word" and core.created_code_text(text, symbols) or text
  local text_class, length = M.text_class(coding_text)
  local result = {
    source=source,
    compatible=compatible,
    type=M.is_fixed_type(candidate_type) and "fixed" or candidate_type,
    fixed_kind=FIXED_TYPES[candidate_type] and candidate_type or nil,
    raw_type=raw_type,
    storage_code=storage_code,
    text=text,
    text_class=text_class,
    length=length or 0,
    code=source_code or storage_code or matched_code,
    matched_code=matched_code,
    split_input=split_input,
    candidate=candidate,
    source_code=source_code,
    prepicked=prepicked ~= nil,
    completion=created_completion == true or candidate_type == "completion" or remaining > 0,
    created_completion=created_completion == true,
  }
  return result
end

-- 查 Mix 时优先使用候选自己的词典码或保存码，不拿更长的补形输入代替。
-- 钉选可能绑在较短前缀上，它仍算完整钉选候选，只在查 Mix 成员时允许匹配这个前缀。
function M.dictionary_query(info)
  local text = info.source and info.source.text or info.text
  local code = info.source_code or info.storage_code or info.code
  return text, code, info.completion or info.type == "pinned"
end

-- 候选放在哪个排序层，由这里统一决定。
-- 使用查询出口传入的静态、created 和 picked 查表结果，共用同一套来源规则。
function M.bucket(info, static_exact, created, picked)
  if info.type == "fixed" then return "fixed" end
  -- Custom 追加的 X 单字与词典一简放在同一层，追加字之间按 Custom 列表顺序显示。
  if info.type == "single_key_extra" then return "single" end
  if static_exact and info.length == 1 then return "single" end
  if info.type == "pinned" then return "pinned" end
  if info.type == "created_word" or created then return "created" end
  if info.type == "picked_word" or picked then
    -- picked 的身份与排序位置分开：直接命中和短码补形都排在静态精确词后，图标与删除仍按 picked 处理。
    return info.compatible and "picked_compatible" or "picked"
  end
  if static_exact then return "static" end
  if info.prepicked then return "prepicked" end
  -- 原生 userdb 中的词可能仍未确认。只有 picked TXT 中存在对应记录，才进入 picked 层。
  if info.type == "user_table" then return "prepicked" end
  return "other"
end

-- 先看是否开启单字模式，再看一简和两码精确单字。前面都没有决定时，才检查三声码。
-- 这个顺序不能随意调整，否则同码候选的显示规则会变化。
function M.resolve(code, single_only, has_single)
  if single_only then return "single_only" end
  if core.is_sound_code(code, 1) then return "one_sound" end
  if core.is_sound_code(code, 2) and has_single then return "single_code" end
  if core.matches_sound_shape(code, 3, 0, 1) then return "three_sound" end
  return "normal"
end

function M.allows(info, mode, code, exact_static)
  if mode == "one_sound" then return info.length == 1 and not info.completion end
  if mode == "single_only" then return info.length == 1 end
  -- 普通两码以单字为主，同时保留 Mix 精确词和正式保存码下的 created。
  -- 补全与短码回查不能借此放行。主动开启单字模式时，仍只显示单字。
  if mode == "single_code" then
    return info.length == 1 or (info.mix and not info.completion and not info.compatible)
        or (info.type == "created_word"
            and info.storage_code == code and not info.completion)
  end
  -- 主词典精确命中的三声短码按词典显示，例如 ykj 的“一键”。字数限制只用于其他纯汉字候选。
  -- 两字词的普通补全仍不能混进三声候选，中英混合词则不受这个字数限制。
  if mode == "three_sound" and info.text_class == "pure_han" then
    return exact_static or info.length >= 3
  end
  return true
end

local bucket_order = {
  -- 这是分层顺序，不把 picked 硬塞在第二项。没有静态精确词时，picked 仍可成为首选。
  "fixed", "single", "pinned", "created", "static", "picked",
  "picked_compatible", "prepicked", "other"
}

local bucket_priority = {}
for index, name in ipairs(bucket_order) do bucket_priority[name] = index end

function M.new_collector()
  return {rows={}, by_identity={}}
end

function M.collect(collector, info)
  local identity = M.identity(info.candidate)
  local old = collector.by_identity[identity]
  if old then
    local previous = old.info
    if bucket_priority[info.bucket] < bucket_priority[previous.bucket]
        or (info.bucket == previous.bucket and previous.compatible and not info.compatible) then
      old.info = info
    end
    return
  end
  local row = {info=info}
  collector.rows[#collector.rows + 1] = row
  collector.by_identity[identity] = row
end

-- 只有同一来源层中的补形项需要比较长度。其他候选保持原来的位置和次序。
local function sort_shapes(rows)
  local slots, ranked = {}, {}
  for index, info in ipairs(rows) do
    if info.shape_rank then
      slots[#slots + 1] = index
      ranked[#ranked + 1] = {info=info, order=index}
    end
  end
  table.sort(ranked, function(a, b)
    if a.info.shape_rank ~= b.info.shape_rank then return a.info.shape_rank > b.info.shape_rank end
    return a.order < b.order
  end)
  for index, row in ipairs(ranked) do rows[slots[index]] = row.info end
  local exact, compatible = {}, {}
  for _, info in ipairs(rows) do
    local group = info.compatible and compatible or exact
    group[#group + 1] = info
  end
  for _, info in ipairs(compatible) do exact[#exact + 1] = info end
  return exact
end

function M.ordered(collector, shaped)
  local groups = {}
  for _, name in ipairs(bucket_order) do groups[name] = {} end
  for _, row in ipairs(collector.rows) do
    local group = groups[row.info.bucket]
    group[#group + 1] = row.info
  end
  local result = {}
  for _, name in ipairs(bucket_order) do
    local group = groups[name]
    if shaped and name ~= 'fixed' and name ~= 'single' and name ~= 'pinned' then
      group = sort_shapes(group)
    end
    for _, row in ipairs(group) do result[#result + 1] = row end
  end
  return result
end

return M
