-- U 显性自造词先用空格或数字选字，最后按 Enter 上屏并保存。
-- 允许哪些符号、符号显示什么和怎样取码，都读取 Custom 的 created_word/symbols。
-- v 后接数字时输入数字正文，空格选中这一串数字。每位数字独立取码，不按整个数值转换读音。

local core = require "whitkey.core"
local personal = require "whitkey.personal_store"
local composition = require "whitkey.input"
local meta = require "whitkey.candidate"
local M = {}

-- 数字固定按零、一、二、三、四、五、六、七、八、九取完整音码。
-- 例如 50 使用“五”和“零”的音码，不使用“五十”的音码。
local digit_codes = {
  ["0"]="lg", ["1"]="yk", ["2"]="xj", ["3"]="sf", ["4"]="sk",
  ["5"]="wj", ["6"]="lq", ["7"]="qk", ["8"]="bs", ["9"]="jq",
}

local function digit_key(key)
  if key:shift() then return nil end
  local code = key.keycode
  if code >= 0x30 and code <= 0x39 then return string.char(code) end
  if code >= 0xffb0 and code <= 0xffb9 then return tostring(code - 0xffb0) end
end

-- v 的活动正文为空或全是数字时，数字键写入正文；字母菜单仍用数字选词。
-- 范围只读当前分段，不能把前面已经选好的汉字或字母一起检查。
local function digit_segment(context)
  local segment = composition.current_segment(context)
  if not segment or segment.status == "kSelected" or segment.status == "kConfirmed"
      or context.caret_pos < segment._end then return nil end
  local input = context.input:sub(segment.start + 1, segment._end)
  -- 空的 v 入口还没有 eng_quick_mode 标签，但可以接收第一位数字。
  if input == "v" or segment:has_tag("eng_quick_mode") and input:match("^[0-9]*$") then
    return segment
  end
end

-- 为显性自造词选编码时，先找与选字输入码相符的反查码。同样符合时优先选较长的码。
-- 没有相符项也选较长的码，这样才能取到后面的形码。
local function matches_hint(code, hint)
  if hint == "" then return false end
  for i = 1, math.min(#code, #hint) do
    local char = hint:sub(i, i)
    if char ~= "`" and char ~= code:sub(i, i) then return false end
  end
  return true
end

local function choose_code(reverse, character, hint)
  -- 反引号占一个省略码位，清理时要保留。直接删掉会把后面的形码移到音码位置。
  hint = core.clean_code(hint, true)
  local best, score = nil, -1
  for code in core.reverse_codes(reverse, character):gmatch("[a-z;]+") do
    local matches = matches_hint(code, hint)
    local value = #code + (matches and 100000 or 0)
    if value > score then best, score = code, value end
  end
  return best
end

function M.encode(text, hints, reverse, max_length, letter_map, symbols)
  local chars = core.split_chars(text)
  local codes, mixed = {}, false
  -- hints 与原正文中的字符位置一一对应。取码跳过空编码符号时，只跳过该符号的编码。
  -- 后面的汉字仍读取原位置的 hint，避免使用错位的选字音码。
  for index, character in ipairs(chars) do
    local symbol_code = symbols.codes[character]
    if symbol_code ~= "" then
      local letter = core.ascii_letter(character)
      local code
      if symbol_code then
        code = symbol_code
        mixed = true
      elseif digit_codes[character] then
        code = digit_codes[character]
        mixed = true
      elseif letter then
        code = letter_map[letter]
        mixed = true
      else
        code = choose_code(reverse, character, hints[index])
      end
      if not code or code == "" then return nil end
      codes[#codes + 1] = code
    end
  end

  local length = #codes
  if length < 2 or (max_length and max_length > 0 and length > max_length) then return nil end

  -- 每位数字和每个有编码的符号各算一个取码单位，写了两位编码也仍是一个单位。两个单位各取最多两码。
  -- 三个单位各取首码，全为汉字时再补首字第一笔形码；四个及以上取前三单位和末单位的首码。
  if length == 2 then return codes[1]:sub(1, 2) .. codes[2]:sub(1, 2) end
  local prefix = codes[1]:sub(1, 1) .. codes[2]:sub(1, 1) .. codes[3]:sub(1, 1)
  if length == 3 then return prefix .. (mixed and "" or codes[1]:sub(3, 3)) end
  return prefix .. codes[#codes]:sub(1, 1)
end

function M.is_active(context)
  return composition.is(context, composition.CREATED_WORD)
end

local function reset(context)
  if M.is_active(context) then composition.reset(context) end
end

local function begin(context)
  return composition.begin(context, composition.CREATED_WORD)
end

local function cancel(context, clear)
  if clear then composition.cancel(context) else reset(context) end
end

-- u 后还没有造词正文时，只有 Enter 直接上屏入口字母 u。
local function commit_u(env)
  local context = env.engine.context
  composition.cancel(context)
  env.engine:commit_text("u")
  return true
end

-- 提交前记录每个已选字符当时的输入码。多字候选不能把输入逐字对应，就给各字留空 hint，之后从 ReverseLookup 取码。
local function selected_hint(env, candidate, source, raw)
  local info = meta.describe(candidate)
  if info.source_code then return info.source_code end
  local entry = meta.entry(candidate, source)
  if not entry or not entry.code or not raw:sub(1, 2):find("`", 1, true) then return raw end
  -- 静态 Phrase 可能只有数字码，custom_code 为空，这时按需解码选中词典项。
  -- 这样在省略声码或同字同形不同音时，仍能保留选中的读音。这个 Memory 不连接用户词典。
  if not env.created_decode_memory then
    env.created_decode_memory = Memory(env.engine, env.engine.schema, "static_lookup")
  end
  local codes = env.created_decode_memory:decode(entry.code)
  local code = #codes == 1 and core.clean_code(codes[1]) or ""
  return core.is_sound_code(code:sub(1, 2), 2) and code or raw
end

local function capture_hints(context, env)
  local hints, originals = {}, {}
  local full_input = context.input or ""
  local composition_obj = context.composition
  local segmentation = composition_obj and composition_obj:toSegmentation() or nil
  if not segmentation or not segmentation.get_segments then return hints end
  for _, segment in ipairs(segmentation:get_segments()) do
    -- phony 分段不产生正文，例如输入字母或数字时的 v 前缀，所以跳过它。
    -- 孤立的末尾 v 没有这个标签，仍是未完成输入，不能跳过。
    if segment._end > segment.start and not segment:has_tag("phony") then
      local raw = core.clean_code(full_input:sub(segment.start + 1, segment._end), true)
      local candidate = segment:get_candidate_at(segment.selected_index or 0)
      local source = meta.source(candidate)
      -- 保存时，每个正文分段都要有覆盖完整范围的候选。未选原码可以上屏，但不能作为选好的正文保存。
      if not source or candidate._end ~= segment._end then return hints end
      originals[#originals + 1] = source.text
      local count = core.utf8_length(source.text)
      if count == 1 then
        -- 省略声码可能命中不同读音，词典项有编码就用选中项的码。
        -- 没有时再用保留省略位置的输入匹配反查，最终仍按原有整词规则取码。
        hints[#hints + 1] = selected_hint(env, candidate, source, raw)
      else
        for _ = 1, count do hints[#hints + 1] = "" end
      end
    end
  end
  return hints, table.concat(originals)
end

local function finish(env)
  local context = env.engine.context
  local input = context.input or ""
  if input == "" then return commit_u(env) end
  -- 确认候选可能触发通知并改变拆码范围，所以先完成选择，再从更新后的状态读取文字和提示码。
  if context:has_menu() and context:get_selected_candidate() then
    context:confirm_current_selection()
  end
  local hints, source_text = capture_hints(context, env)
  composition.prepare_word_creation(context)
  -- Rime 负责上屏文字，保存和取码使用底层原文，不受简繁显示转换影响。
  local text = source_text or context:get_commit_text()
  -- 尚未选出的原码仍可以按 Enter 上屏，但不能当成已选英文字母写入自造词文件。
  local code = source_text and M.encode(source_text, hints, env.created_reverse,
      env.created_max_phrase_length, env.created_letter_map, env.created_store.symbols)
  -- commit 会触发 picked 的提交监听。提交前加上显性造词标记，让监听器跳过本次 U 提交，避免同一词写入 created 和 picked。
  context:set_property("whitkey_explicit_commit", "1")
  local ok, committed = pcall(function() return context:commit() end)
  context:set_property("whitkey_explicit_commit", "")
  if not ok or committed == false then
    if log and log.error then log.error("自造词提交失败，保留当前输入") end
    M.result(context, false)
    return false
  end
  reset(context)
  if code and code ~= "" then
    local saved, err = personal.created_add(env.created_store, text, code)
    if not saved and log and log.error then log.error(tostring(err)) end
    M.result(context, saved == true)
  else
    M.result(context, false)
  end
  return true
end

-- 先清除上一次的成功或失败状态，再通过 Rime 原生开关发出本次结果，前端显示 schema 中的文字。
-- 连续两次结果相同时，也能发出新的通知。
function M.result(context, success)
  local option = success and "created_success" or "created_failure"
  context:set_option("created_success", false)
  context:set_option("created_failure", false)
  context:set_option(option, true)
end

-- 正式造词时，翻页等候选导航键继续交给 key_binder。其他未配置的 ASCII 标点不进入正文，也不触发保存。
local function is_navigation_punctuation(key, context)
  if not context:has_menu() or key:shift() then return false end
  local char = core.ascii_key(key)
  return char == "-" or char == "="
end

local function is_literal_punctuation(key, env)
  local char = core.ascii_key(key)
  return char and not env.created_alphabet[char] and char:match("%p") ~= nil
end

-- 符号仍由原生 punct 分段，filter_symbols 再按 Custom 替换候选文字。
-- 不使用 punctuator 的直接 commit，以免提前上屏；先生成候选，再确认到造词正文。
local function insert_symbol(context, key, replace_entry)
  if not replace_entry then
    local segment = composition.current_segment(context)
    if segment and segment.status ~= "kSelected" and segment.status ~= "kConfirmed"
        and segment._end > segment.start then
      if not context:has_menu() then return core.kAccepted end
      context:confirm_current_selection()
    end
  end
  if replace_entry then
    begin(context)
    context.input = key
  else
    context:push_input(key)
  end
  if context:has_menu() then context:confirm_current_selection() end
  return core.kAccepted
end

-- 这里只处理标点分段，不做普通中文排序。U 以外的标点候选原样通过。
-- U 中每个符号键只显示 Custom 指定的符号，不混入原生配对引号等其他候选。
function M.filter_symbols(translation, context, segment, symbols)
  local key = context.input:sub(segment.start + 1, segment._end)
  local text = M.is_active(context) and symbols.keys[key]
  if text then
    local candidate = Candidate("created_symbol", segment.start, segment._end, text, "")
    candidate.preedit = text
    yield(candidate)
    return
  end
  for candidate in translation:iter() do yield(candidate) end
end

-- pipeline/before 先接收符号，再处理 U 按键，两者共用同一个 env。translator 生成字母与数字候选，使用自己的 env。
-- 两边不读取对方私有字段，模式由 input 管理，最终提交用显性标记通知 picked 跳过。
function M.init(env, config, stage)
  config = config or env.engine.schema.config
  env.stage = stage
  env.entry = composition.entry_text(config, "u")
  if stage == "translator" then
    local _
    _, env.letters_by_code = core.build_letter_maps(config)
    return
  end
  env.created_store, env.created_store_path = personal.acquire_created(
      config:get_string("created_word/store_file") or "white_replace/whitkey_created.txt", config)
  env.created_alphabet = core.string_to_set(config:get_string("speller/alphabet")
      or "abcdefghijklmnopqrstuvwxyz`")
  env.created_dictionary = config:get_string("created_word/dictionary")
      or config:get_string("translator/dictionary") or "enabled_dicts"
  env.created_max_phrase_length = config:get_int("created_word/max_phrase_length") or 0
  env.created_reverse = core.acquire_reverse(env.created_dictionary)
  env.created_letter_map = core.build_letter_maps(config)
end

-- before 在 ascii_composer 前接收符号，避免 Caps Lock 或 Shift 先把造词正文上屏。
-- 后面的 process 处理提交和退出，普通选字与编辑仍交给 Rime。
function M.before(key, env)
  local context = env.engine.context
  if context:get_option("ascii_mode") then return core.kNoop end
  local mode = composition.mode(context)
  local entry, active = mode == composition.CREATED_ENTRY, mode == composition.CREATED_WORD
  if not active and not entry then return core.kNoop end
  if key:release() or key:ctrl() or key:alt() or key:super() then return core.kNoop end
  local symbol_key = core.ascii_key(key)
  if symbol_key and env.created_store.symbols.keys[symbol_key] then
    return insert_symbol(context, symbol_key, entry)
  end
  if is_literal_punctuation(key, env) and not is_navigation_punctuation(key, context) then
    return core.kAccepted
  end
  local code = key.keycode
  if active and ((code >= 0xffe1 and code <= 0xffee) or code == 0xff30) then return core.kAccepted end
  return core.kNoop
end

function M.process(key, env)
  local symbol_result = M.before(key, env)
  if symbol_result ~= core.kNoop then return symbol_result end
  local context = env.engine.context
  if context:get_option("ascii_mode") or key:release() then return core.kNoop end

  if key:ctrl() or key:alt() or key:super() then return core.kNoop end
  local entry = composition.is(context, composition.CREATED_ENTRY)
  local active = M.is_active(context)
  if key:caps() and not entry and not active then return core.kNoop end
  local input = context.input or ""
  if not active and not key:shift() and key.keycode == string.byte("u") and input == "" then
    if env.entry ~= "" then
      composition.begin(context, composition.CREATED_ENTRY)
      context:push_input("u")
      return core.kAccepted
    end
    return begin(context) and core.kAccepted or core.kNoop
  end
  if composition.is(context, composition.CREATED_ENTRY) then
    if core.is_return(key) then
      commit_u(env)
      return core.kAccepted
    end
    if core.is_space(key) then
      context:commit()
      return core.kAccepted
    end
    -- U 入口的数字继续向后传，candidate_actions 先检查“唯一候选＋数字”，再交给原生选字。
    if key.keycode >= 0x30 and key.keycode <= 0x39 and context:has_menu() then return core.kNoop end
    if key.keycode == 0xff08 or key.keycode == 0xff1b or key.keycode == 0xffff then
      composition.cancel(context)
      return core.kAccepted
    end
    local char = key.keycode >= 0x20 and key.keycode < 0x7f and string.char(key.keycode) or ""
    if core.is_sound_code(char, 1) or char == "v" or char == "`" then
      -- 第一个正文字符直接替换 u 入口，不先清空输入，避免发出一次空输入通知。
      -- 正式正文仍从位置 0 开始。
      begin(context)
      context.input = char
      return core.kAccepted
    end
    return core.kAccepted
  end
  if not M.is_active(context) then return core.kNoop end

  if key.keycode == 0xff1b or key.keycode == 0xffff then
    cancel(context, true)
    return core.kAccepted
  end
  if key.keycode == 0xff08 then
    if input == "" then
      cancel(context, false)
      return core.kAccepted
    end
    return key:caps() and composition.native_control(key, env) or core.kNoop
  end
  if core.is_return(key) then
    finish(env)
    return core.kAccepted
  end

  -- U 中空格只选择当前候选。没有候选时拦住空格，不改正文，也不提交整词。
  if core.is_space(key) then
    if context:has_menu() then return key:caps() and composition.native_control(key, env) or core.kNoop end
    return core.kAccepted
  end

  -- U 中 v 后接数字时，把主键盘和小键盘数字统一写成半角正文。
  -- v 后接字母时仍是字母菜单，数字交给原生选择，超出候选数量也不写入正文。
  local digit = digit_key(key)
  if digit then
    if digit_segment(context) then
      context:push_input(digit)
    elseif context:has_menu() then
      composition.native_control(KeyEvent(digit), env)
    end
    -- 选完一段后没有活动菜单时，不让 editor 把数字当成提交键。
    return core.kAccepted
  end

  -- 数字选字、翻页和普通编码继续交给 Rime。符号已经由 before 处理。
  -- 其他 ASCII 标点既不结束造词，也不写入正文。
  if is_navigation_punctuation(key, context) then return core.kNoop end
  if is_literal_punctuation(key, env) then return core.kAccepted end
  if key:caps() and (key.keycode >= 0xff00 or key.keycode >= 0x30 and key.keycode <= 0x39) then
    return composition.native_control(key, env)
  end
  return core.kNoop
end

function M.fini(env)
  if env.stage == "translator" then
    env.letters_by_code = nil
    return
  end
  local context = env.engine and env.engine.context
  if context then reset(context) end
  core.release_reverse(env.created_dictionary)
  if env.created_decode_memory then env.created_decode_memory:disconnect() end
  env.created_decode_memory = nil
  personal.release_created(env.created_store_path)
  env.native_controls = nil
  env.created_reverse, env.created_store, env.created_letter_map, env.created_alphabet = nil, nil, nil, nil
end

-- U 中的字母候选和数字正文候选都在这里生成，选择仍由 Rime 完成。
function M.translate(input, segment, env)
  if composition.is(env.engine.context, composition.CREATED_WORD)
      and input:match("^[0-9]+$") then
    local candidate = Candidate("mixed_digits", segment.start, segment._end, input, "数字")
    candidate.quality, candidate.preedit = 10000, input
    yield(candidate)
    return
  end
  -- 先按原顺序列出大写字母，再按同一顺序列出小写字母。例如 vs 显示 A、S、a、s。
  if type(input) == "string"
      and composition.is(env.engine.context, composition.CREATED_WORD)
      and input:match("^[a-z]$") then
    local letters = env.letters_by_code[input]
    if not letters then return end
    for variant = 0, 1 do
      for index, letter in ipairs(letters) do
        local text = variant == 0 and letter or letter:lower()
        local candidate = Candidate(
            "mixed_letter", segment.start, segment._end, text, "字母")
        candidate.quality = 10000 - variant * #letters - index
        candidate.preedit = text
        yield(candidate)
      end
    end
    return
  end

end

return M
