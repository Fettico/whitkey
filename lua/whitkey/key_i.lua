-- 这里查询 i 后面的 Emoji 名称编码并生成表情候选。
-- 单独 i 的符号和 ia～iz 的拉丁扩展字母，由 Rime 读取方案配置生成。
local core = require "whitkey.core"
local store = require "whitkey.data_store"
local personal = require "whitkey.personal_store"
local meta = require "whitkey.candidate"
local composition = require "whitkey.input"
local M = {}
-- i＋完整码没有 Emoji 候选时，拦住空格，避免误把无效编码提交出去。
-- Enter 仍交给 Rime，因此 ime 这类原始输入可以按回车上屏。
function M.process(key, env)
  if key:ctrl() or key:alt() or key:super() or key:caps()
      or not core.is_space(key) then return core.kNoop end
  local context = env.engine.context
  local segment = composition.current_segment(context)
  if segment and segment:has_tag("emoji_mode") and not context:has_menu() then
    return core.kAccepted
  end
  return core.kNoop
end


-- 只释放 Emoji 文件数据和名称索引，当前配置、反查和隐藏表继续保留。
-- 下次查 Emoji 可以直接重新加载，不用把整个模块退出再初始化。
local function release_emoji(env)
  if env.emoji_path then store.release_emoji(env.emoji_path) end
  env.emoji_data, env.emoji_path, env.emoji_rows, env.emoji_index = nil, nil, nil, nil
  env.emoji_used_at = nil
end

-- Emoji 久未使用时，等下一次查询其他内容再释放，不开后台定时器，也不改正在输入的文字。
-- 当前仍在 I 输入或 Emoji 分段时先保留，避免翻页或选择过程中丢掉索引。
function M.release_idle(env, context)
  if not env.emoji_rows or env.emoji_idle_seconds == 0 then return end
  if os.time() - env.emoji_used_at < env.emoji_idle_seconds then return end
  if context.input:sub(1, 1) == "i" then return end
  local segment = composition.current_segment(context)
  if segment and segment:has_tag("emoji_mode") then return end
  release_emoji(env)
end

-- 第一次查 Emoji 时才读取文件、合并重复项，再按名称或第三列指定编码建立查询索引。
local function load_emoji(env)
  if env.emoji_rows then return env.emoji_rows end
  if not env.reverse then
    env.reverse = core.acquire_reverse(env.dictionary)
    env.letter_map = core.build_letter_maps(env.config)
    env.hidden = personal.acquire_hidden(env.hidden_path, env.config)
  end
  -- 反查还不可用时，先不建立索引，避免把缺少音码的名称当成完整数据。
  -- 共享反查恢复后，下次查询再取码。
  if not core.reverse_ready(env.reverse) then return nil end
  if not env.emoji_data then
    env.emoji_data, env.emoji_path = store.acquire_emoji(env.emoji_file)
  end
  local result = env.emoji_data.entries

  -- 多音字分别保留自己的音码，不预先列出所有读音组合。
  -- 名称先按码长和首键分组，查询只比较对应组中的完整码，不扫主词典或补全候选。
  local units_cache, index = {}, {}
  local function unit_for(character, initials)
    local cache_key = character .. (initials and "1" or "2")
    if units_cache[cache_key] then return units_cache[cache_key] end
    local letter = core.ascii_letter(character)
    local unit = {width=(letter or initials) and 1 or 2, codes={}}
    if letter then
      unit.codes[env.letter_map[letter]] = true
    else
      for _, sound in ipairs(core.sound_codes(env.reverse, character)) do
        unit.codes[initials and sound:sub(1, 1) or sound] = true
      end
    end
    units_cache[cache_key] = unit
    return unit
  end
  for _, entry in ipairs(result) do
    local text = entry.text
    local row = {text=text, values=entry.values, units={}}
    local length, valid = 0, true
    if entry.code ~= "" then
      row.units[1] = {width=#entry.code, codes={[entry.code]=true}}
      length = #entry.code
    else
      local chars = core.split_chars(text)
      local initials = #chars >= 3
      -- 自动取码时，三字取各字首声，四字以上只取前三字和末字首声。
      -- 中间不参与取码的字，不要求能查到音码。
      local positions = #chars > 3 and {1, 2, 3, #chars} or nil
      local position_count = positions and #positions or #chars
      for position = 1, position_count do
        local character_index = positions and positions[position] or position
        local unit = unit_for(chars[character_index], initials)
        if not next(unit.codes) then
          valid = false
          break
        end
        row.units[#row.units + 1] = unit
        length = length + unit.width
      end
    end
    if valid and length >= 2 then
      index[length] = index[length] or {}
      local seen_first = {}
      for sound in pairs(row.units[1].codes) do
        local first = sound:sub(1, 1)
        if not seen_first[first] then
          seen_first[first] = true
          index[length][first] = index[length][first] or {}
          table.insert(index[length][first], row)
        end
      end
    end
  end
  env.emoji_index, env.emoji_rows = index, result
  return result
end

-- 命中一行名称后，列出这一行的 emoji_only 候选。
-- 名称或表情被 Ctrl+Q 隐藏时跳过，同一轮查询中相同表情只显示一次。
local function yield_emoji_source(row, quality, code, segment, env, emoji_seen)
  local text, values = row.text, row.values
  if personal.hidden_contains(env.hidden, text, code) then return end
  for index, value in ipairs(values) do
    local identity = meta.emoji_identity(value)
    -- 旧隐藏记录可能带 FE0F，因此查询无 FE0F 的同一个单字符表情时，也检查旧写法是否已隐藏。
    local hidden = personal.hidden_contains(env.hidden, identity, code)
        or (utf8.len(identity) == 1 and personal.hidden_contains(env.hidden, identity .. "️", code))
    if not emoji_seen[identity] and not hidden then
      emoji_seen[identity] = true
      local candidate = Candidate(
          "emoji_only", segment.start, segment._end, value, "[" .. text .. "]")
      candidate.quality = quality - index * 0.001
      yield(candidate)
    end
  end
end

-- 形码来自名称中的汉字，不来自表情。反查结果沿用 core 的共享缓存，不另建整份形码词库。
local function character_matches_shape(character, shape, env)
  for code in core.reverse_codes(env.reverse, character):gmatch("[a-z]+") do
    local suffix = code:sub(3)
    if core.is_sound_code(code:sub(1, 2), 2) and core.is_shape_code(suffix, 1)
        and suffix:sub(1, #shape) == shape then return true end
  end
  return false
end

-- 单字名称按整字形码前缀筛选。词组逐字取第一笔：三字最多三位，其他词组最多两位。
-- 没追加形码就不查笔画；名称中需要筛形的字查不到编码时，只让这次补形查询不匹配。
local function matches_shape(text, shape, env)
  if shape == "" then return true end
  local length = core.utf8_length(text)
  local maximum = length == 1 and env.shape_max_length or (length == 3 and 3 or 2)
  if #shape > maximum then return false end
  if length == 1 then return character_matches_shape(text, shape, env) end
  for position = 1, #shape do
    if not character_matches_shape(core.character_at(text, position), shape:sub(position, position), env) then
      return false
    end
  end
  return true
end

-- 音码仍要求完整匹配。第三列指定码也作为完整音码使用，后面可以追加名称的形码。
function M.translate(input, segment, env)
  if type(input) ~= "string" or #input < 2
      or not env.engine.context:get_option("emoji_cn") then return end
  local sound, shape = core.sound_shape_parts(input)
  if not sound or #sound < 2 then return end
  if not load_emoji(env) then return end
  env.emoji_used_at = os.time()
  local by_length = env.emoji_index[#sound]
  local rows = by_length and by_length[sound:sub(1, 1)] or {}
  local emoji_seen = {}
  for index, row in ipairs(rows) do
    local offset, matches = 1, true
    for _, unit in ipairs(row.units) do
      if not unit.codes[sound:sub(offset, offset + unit.width - 1)] then
        matches = false
        break
      end
      offset = offset + unit.width
    end
    -- 同一个表情可能来自多个名称。先筛名称，再去重，避免前一个不匹配的名称占掉表情身份。
    -- 隐藏仍使用当前完整查询码（不带 i），不把追加形码误当成另一个名称的音码。
    if matches and matches_shape(row.text, shape, env) then
      yield_emoji_source(row, 1000000 - index, input, segment, env, emoji_seen)
    end
  end
end


function M.init(env, config, stage)
  config = config or env.engine.schema.config
  env.stage = stage
  if stage == "processor" then
    env.engine.context:set_option("emoji_cn", config:get_bool("emoji_cn/enabled") == true)
    return
  end
  env.dictionary = config:get_string("created_word/dictionary")
      or config:get_string("translator/dictionary") or "enabled_dicts"
  env.config = config
  env.hidden_path = personal.resolve(config:get_string("hidden_candidate/store_file")
      or "white_replace/whitkey_hidden.txt")
  env.emoji_file = config:get_string("emoji_cn/file") or "white_dicts/emoji.txt"
  env.emoji_idle_seconds = math.max(0, config:get_int("emoji_cn/idle_seconds") or 60)
  env.shape_max_length = math.max(1, config:get_int("shape_input/max_length") or 4)
end
function M.fini(env)
  if env.stage == "processor" then return end
  if env.reverse then core.release_reverse(env.dictionary) end
  if env.hidden then personal.release_hidden(env.hidden_path) end
  env.config, env.reverse, env.letter_map, env.hidden = nil, nil, nil, nil
  release_emoji(env)
  env.emoji_idle_seconds = nil
end

return M
