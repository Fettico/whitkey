-- 先读取候选身份，再决定显示哪个图标。图标只是身份的提示，不能反过来决定候选是什么。
-- 修改显示时保留底层 Phrase，让 Rime 继续学习原候选。
local core = require 'whitkey.core'
local meta = require 'whitkey.candidate'
local store = require 'whitkey.data_store'
local state = require 'whitkey.input'
local M = {}
local COMMENT_MODES = {all=true, two_part_only=true, none=true}
local COMPLETION_HINTS = {full=true, letter=true, none=true}
local HIDDEN_COMMENT = '\226\129\160' -- U+2060 看不见，用它遮住旁注，避免客户端重新显示底层补全提示。

local LABEL_NAMES = {'fixed_630', 'duo', 'fixed_2625', 'single', 'created', 'pinned', 'prepicked', 'picked'}
local COMMENT_NAMES = {'number_lower', 'number_upper', 'number_trad_lower', 'number_trad_upper',
  'equation', 'answer', 'expression', 'statistics', 'reverse_stroke'}

function M.read_labels(config)
  local settings = {icons={}, visibility={}, comments={}, code_formats={}}
  local mode = config:get_string('candidate_comment/mode') or 'all'
  settings.mode = COMMENT_MODES[mode] and mode or 'all'
  local hint = config:get_string('candidate_comment/completion_hint') or 'letter'
  settings.completion_hint = COMPLETION_HINTS[hint] and hint or 'letter'
  for _, name in ipairs(LABEL_NAMES) do
    settings.icons[name] = config:get_string('candidate_label/' .. name) or ''
    settings.visibility[name] = config:get_string('candidate_comment/visibility/' .. name) or 'inherit'
  end
  for _, name in ipairs({'mix', 'emoji', 'two_part', 'fixed_code', 'duo_code', 'fixed_2625_code'}) do
    settings.visibility[name] = config:get_string('candidate_comment/visibility/' .. name) or 'inherit'
  end
  for _, name in ipairs(COMMENT_NAMES) do
    settings.comments[name] = config:get_string('tool_labels/' .. name) or ''
  end
  settings.code_formats.fixed_code = config:get_string('candidate_label/fixed_code_format') or ''
  settings.code_formats.duo_code = config:get_string('candidate_label/duo_code_format') or ''
  settings.code_formats.fixed_2625_code = config:get_string('candidate_label/fixed_2625_code_format') or ''
  settings.two_part_format = config:get_string('candidate_label/two_part_format') or ''
  return settings
end
function M.init(env)
  local config = env.engine.schema.config
  env.labels = M.read_labels(config)
  env.fixed, env.fixed_sources, env.fixed_paths = store.acquire_fixed_sources(config)
  env.fixed_2625 = env.fixed_sources[3]
end
function M.shown(settings, name)
  local value = settings.visibility[name] or 'inherit'
  if value == 'show' then return true end
  if value == 'hide' then return false end
  return settings.mode == 'all' or (settings.mode == 'two_part_only' and name == 'two_part')
end
local function format(template, key, value)
  return (template:gsub('{' .. key .. '}', function() return value or '' end))
end
function M.comment(key, value, settings)
  local template = settings and settings.comments[key] or ''
  if value == '' then return '' end
  return format(template, 'value', value)
end

local function fixed_code_hints(env, text)
  local result
  local code = env.fixed.reverse[text]
  if code and M.shown(env.labels, 'fixed_code') then
    result = {{kind='fixed_code', code=code}}
  end
  code = env.fixed_sources[2].reverse[text]
  if code and M.shown(env.labels, 'duo_code') then
    result = result or {}
    result[#result + 1] = {kind='duo_code', code=code}
  end
  code = env.fixed_2625.reverse[text]
  if code and M.shown(env.labels, 'fixed_2625_code') then
    result = result or {}
    result[#result + 1] = {kind='fixed_2625_code', code=code}
  end
  return result
end

-- 调用方已经确定来源层和保存码，这里只改显示。不能从图标反推来源或删除编码。
-- 先读取全局设置，再读取类别的 show/hide，图标和补全码分别处理。最后应用 Mix 的 hide，清掉英文候选的全部后缀，身份保持不变。
function M.apply(candidate, bucket, fixed_codes, info, settings)
  local source = info.source or meta.source(candidate)
  local name = bucket == 'fixed' and (info.fixed_kind or 'fixed_630') or bucket
  local raw_comment = candidate.comment or ''
  local show_raw = settings.mode == 'all' or (info.mix and M.shown(settings, 'mix'))
  local comment = show_raw and raw_comment or ''
  -- 补全码提示不受全局旁注模式直接控制，先从原始旁注提取码尾。
  -- 如果先按 mode 清空旁注，letter/full 就拿不到要显示的码尾。
  if info.completion then
    local suffix = raw_comment:match('^~([a-z]+)$')
    if suffix then
      if settings.completion_hint == 'letter' then comment = suffix
      elseif settings.completion_hint == 'full' then comment = raw_comment
      else comment = '' end
    end
  end
  if info.type == 'two_part' then
    comment = M.shown(settings, 'two_part') and format(settings.two_part_format, 'pinyin', candidate.comment) or ''
  elseif info.type == 'emoji_only' then
    comment = M.shown(settings, 'emoji') and (candidate.comment or '') or ''
  elseif settings.icons[name] ~= nil then
    local icon = M.shown(settings, name) and settings.icons[name] or ''
    if name == 'prepicked' or name == 'picked' or info.created_completion then
      -- 三声 created 补全仍保留码尾，图标和补全提示各用自己的开关。
      -- 精确 created 没有未输入的码尾，只显示图标。
      comment = comment:gsub('☯️', ''):gsub('☯', ''):match('^%s*(.-)%s*$')
      comment = icon .. (icon ~= '' and comment ~= '' and ' ' or '') .. comment
    else
      comment = icon
    end
  end
  for _, fixed in ipairs(fixed_codes or {}) do
    if fixed.code then
      local extra = format(settings.code_formats[fixed.kind] or '', 'code', fixed.code)
      if extra ~= '' then comment = comment .. (comment ~= '' and ' ' or '') .. extra end
    end
  end
  -- Mix 的 hide 清掉英文候选的全部后缀，包括补全码、图标和固定码旁注。文字、选择和学习不变。
  -- show 只是允许显示，各项具体样式仍由自己的设置决定。
  if info.mix and not M.shown(settings, 'mix') then comment = '' end
  -- 旁注直接留空时，客户端或 uniquifier 可能重新显示底层旁注。
  -- 这里改用不可见的 U+2060 遮住底层提示，同时保留 Phrase，继续支持原生学习。
  if comment == '' and info.type ~= 'two_part'
      and (info.completion or (source.comment or '') ~= '') then
    comment = HIDDEN_COMMENT
  end
  if comment == (candidate.comment or '') and not info.bucket then return candidate end
  -- 两分不参与原生学习，可以重新生成独立候选，把原来的旁注清掉。
  local result
  if info.type == 'two_part' then
    result = Candidate(candidate.type, candidate.start, candidate._end, candidate.text, comment)
    result.preedit = candidate.preedit
  else
    result = ShadowCandidate(source, info.bucket and meta.tag(info) or candidate.type, candidate.text, comment, false)
  end
  result.start, result._end, result.quality = candidate.start, candidate._end, candidate.quality
  result.preedit = candidate.preedit
  return result
end
function M.tags_match(_) return true end
function M.func(input, env)
  local composition = env.engine.context.composition
  local segment = not composition:empty() and composition:back() or nil
  local ordinary = segment and segment:has_tag('abc')
  local code = ordinary and state.read_input(env.engine.context).raw or ''
  local multi_sound = core.matches_sound_shape(code, 3, 0) or core.matches_sound_shape(code, 4, 0)
  local emoji = segment and segment:has_tag('emoji_mode')
  local reverse_stroke = segment and segment:has_tag('reverse_stroke_mode')
  -- 后置 Lua 迭代可能提前读取候选，前面的 uniquifier 未必已看到上一条最终输出。
  -- 普通候选因此在这里再按显示文字和范围去重，保留第一条的底层原文，不改保存记录。
  local seen = ordinary and not segment:has_tag('styled_english') and {} or nil
  for candidate in input:iter() do
    -- Emoji 不经过普通候选分类，在最终显示出口应用自己的旁注开关。
    -- 只改后面的 [名称]，不改表情文字、顺序或查询结果。
    if emoji and candidate.type == 'emoji_only' then
      candidate = M.apply(candidate, 'other', nil, {type='emoji_only'}, env.labels)
    end
    -- 普通候选在查询时已带来源和排序层。这里读回身份，再一次性生成图标和旁注。
    -- 简繁可能加包装，所以用原生底层 Phrase 重建一层显示包装，消耗范围和身份都保留。
    if ordinary then
      local info = meta.describe(candidate)
      if info.bucket then
        local fixed_codes = multi_sound and info.type ~= 'two_part'
            and fixed_code_hints(env, info.source.text) or nil
        candidate = M.apply(candidate, info.bucket, fixed_codes, info, env.labels)
      end
    end
    if reverse_stroke then
      -- OB 的拼音由原生 reverse_lookup_filter 提供，这里只应用显示模板。
      local comment = M.comment('reverse_stroke', candidate.comment or '', env.labels)
      if env.labels.mode ~= 'all' then comment = '' end
      local result = Candidate(candidate.type, candidate.start, candidate._end, candidate.text, comment)
      result.quality = candidate.quality
      candidate = result
    end
    local identity = seen and meta.identity(candidate)
    if not seen or not seen[identity] then
      if seen then seen[identity] = true end
      yield(candidate)
    end
  end
end
function M.fini(env)
  store.release_fixed_sources(env.fixed_paths)
  env.fixed, env.fixed_sources, env.fixed_2625, env.fixed_paths = nil, nil, nil, nil
  env.labels = nil
end
return M
