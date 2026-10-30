-- 这里记录当前是普通输入、U 造词还是 V 英文，查询和按键模块都从这里读取模式和输入。
-- 选过拆码首字后，这里清掉它用过的形码，退格撤销时再补回。buffered 和 _auto_commit 随模式一起变化，各模块仍保留自己的 env，不另设一套模式。

local core = require "whitkey.core"
local meta = require "whitkey.candidate"
local M = {}
local kSelected, kConfirmed = "kSelected", "kConfirmed"

M.NORMAL = "normal"
M.CREATED_WORD = "created_word"
M.CREATED_ENTRY = "created_entry"
M.LITERAL_ENTRY = "literal_entry"
M.LITERAL_ENGLISH = "literal_english"

local MODE_PROPERTY = "whitkey_input_mode"
local VALID_MODE = {
  [M.NORMAL] = true,
  [M.CREATED_WORD] = true,
  [M.CREATED_ENTRY] = true,
  [M.LITERAL_ENTRY] = true,
  [M.LITERAL_ENGLISH] = true,
}

---@class InputStateEnv: Env
---@field session_connections table[] 当前会话的通知连接，fini 时逐个断开。

-- 修改属性会再次触发通知。值没有变化就不重复设置，避免同一个回调反复执行。
local function set_property(context, name, value)
  if (context:get_property(name) or "") ~= value then
    context:set_property(name, value)
  end
end

local function set_option(context, name, value)
  if context:get_option(name) ~= value then context:set_option(name, value) end
end

local function sync_options(context, mode)
  local created = mode == M.CREATED_WORD
  set_option(context, "buffered", created)
  set_option(context, "_auto_commit", mode == M.NORMAL
      or mode == M.CREATED_ENTRY or mode == M.LITERAL_ENTRY)
end

-- 读取当前会话模式。尚未初始化或属性值不合法时，按普通输入处理。
function M.mode(context)
  if not context then return M.NORMAL end
  local mode = context:get_property(MODE_PROPERTY) or ""
  return VALID_MODE[mode] and mode or M.NORMAL
end

function M.is(context, expected)
  return M.mode(context) == expected
end

-- A/V/U/O 入口共用单字候选身份和配置读取，进入后的功能仍由各自的按键模块处理。
function M.entry_text(config, key)
  if config:get_bool("entry_candidate/enabled") == false then return "" end
  local text = config:get_string("entry_candidate/" .. key) or ""
  if text ~= "" and core.utf8_length(text) ~= 1 then return "" end
  return text
end

function M.emit_entry(text, segment, key)
  local candidate = Candidate("entry_word", segment.start, segment._end, text, "")
  candidate.preedit, candidate.quality = key, 1000000
  yield(candidate)
end

-- 只有模式发生变化时才更新 buffered 和 _auto_commit，不在每个按键前重复设置。
-- U 入口可以进入正式造词，V 入口和 V 正文可以互相切换。一次 composition 已进入 U 或 V 后，其他功能不能把它改成自己的模式。
function M.begin(context, mode)
  local previous = M.mode(context)
  local created_transition = previous == M.CREATED_ENTRY and mode == M.CREATED_WORD
  local literal_transition = (previous == M.LITERAL_ENTRY or previous == M.LITERAL_ENGLISH)
      and (mode == M.LITERAL_ENTRY or mode == M.LITERAL_ENGLISH)
  if previous ~= M.NORMAL and not created_transition and not literal_transition then return false end
  set_property(context, MODE_PROPERTY, mode)
  sync_options(context, mode)
  return true
end

function M.is_literal(context)
  local mode = M.mode(context)
  return mode == M.LITERAL_ENTRY or mode == M.LITERAL_ENGLISH
end

function M.reset(context)
  if not context then return end
  set_property(context, MODE_PROPERTY, M.NORMAL)
  sync_options(context, M.NORMAL)
end

-- 初始化时创建原生控制组件，再恢复当前模式对应的选项。express_editor 创建时会打开 _auto_commit。
-- 所以要在输入还为空时完成，不能等到选字时才创建，否则会改变当时的选项和候选。
function M.init_native_controls(env)
  env.native_controls = {
    Component.Processor(env.engine, "", "selector"),
    Component.Processor(env.engine, "", "navigator"),
    Component.Processor(env.engine, "", "express_editor"),
  }
  local context = env.engine.context
  sync_options(context, M.mode(context))
end

-- 先去掉 Caps Lock 的 Lock 标记，再把主键盘、小键盘和 ASCII 回车统一成 Return，Shift 等其他标记保留。
-- 随后按主方案顺序交给原生组件，避免同一个回车因客户端按键写法不同而失效。
function M.native_control(key, env)
  local repr = key:repr():gsub("Lock%+", "")
  if core.is_return(key) then repr = repr:gsub("[^+]+$", "Return") end
  local plain = KeyEvent(repr)
  for _, processor in ipairs(env.native_controls) do
    local result = processor:process_key_event(plain)
    if result ~= core.kNoop then return result end
  end
  return core.kNoop
end

-- 普通 Enter 原本只提交光标左边。这里先把光标移到输入末尾，让后面的原生流程提交完整输入。
-- 已选文字、未选原码和学习通知仍由 Rime 处理，U 正式保存也先用这里准备完整尾段。
function M.prepare_return(context)
  local input = context.input or ""
  if context.caret_pos ~= #input then context.caret_pos = #input end
end

-- 第一个返回值是最后一个活动分段。还要查看前面已选分段时，可以使用第二个返回值 segmentation。
function M.current_segment(context)
  local composition = context and context.composition
  local segmentation = composition and composition:toSegmentation() or nil
  return segmentation and segmentation:back() or nil, segmentation
end

-- 主动取消时，先恢复普通模式，再清空 Rime 的 composition。
function M.cancel(context)
  M.reset(context)
  context:clear()
end

-- 只看当前分段紧邻的已选候选，拆码关系直接读取查询时写入的身份。
-- 不根据旧分段的码长、字数或旁注猜测身份，避免把普通完整单字当成拆码首字。
local function preceding_split(segment, segmentation)
  if not segment or segmentation.size < 2 then return nil end
  local previous = segmentation:get_at(segmentation.size - 2)
  if previous._end ~= segment.start then return nil end
  if previous.status ~= kSelected and previous.status ~= kConfirmed then return nil end
  local candidate = previous:get_candidate_at(previous.selected_index or 0)
  local input = meta.split_input(candidate)
  if input then return previous, input end
end

-- 只有本次选择产生的拆码尾段才清理形码。nka 的“尼”是完整单字，没有拆码身份，不走这里。
function M.finish_split(context)
  local segment, segmentation = M.current_segment(context)
  local previous, original = preceding_split(segment, segmentation)
  if not original then return end
  local suffix = original:sub(5)
  if suffix == "" then return end
  local input = context.input
  if segment._end ~= previous.start + #original
      or input:sub(previous.start + 1, segment._end) ~= original then return end
  local caret, finish = context.caret_pos, segment._end
  context.caret_pos = finish
  context:pop_input(#suffix)
  context.caret_pos = math.min(caret, finish - #suffix)
end

-- 已选候选保留原查询码。撤销选择时，只恢复这次选择删掉的形码。
-- 用户改过尾段时先按普通退格处理，不恢复已经与当前输入无关的形码。
function M.restore_split(context)
  local segment, segmentation = M.current_segment(context)
  local previous, original = preceding_split(segment, segmentation)
  if not original then return false end
  local suffix = original:sub(5)
  local finish = previous.start + 4
  if suffix == "" or segment._end ~= finish or context.caret_pos ~= finish
      or context.input:sub(previous.start + 1, finish) ~= original:sub(1, 4) then
    return false
  end
  if not context:reopen_previous_selection() then return false end
  context:push_input(suffix)
  return true
end

function M.fini(env)
  for _, connection in ipairs(env.session_connections or {}) do connection:disconnect() end
  env.session_connections = nil
  env.topup_set, env.alphabet = nil, nil
  if env.engine and env.engine.context then M.reset(env.engine.context) end
end

-- Rime 要学习逐字组词时，需要把这次 composition 中已确认的前段改回“已选择”。
-- 准备提交整个组合，或让 selector 完成普通逐字组词时，才做这一步。
function M.prepare_word_creation(context)
  local composition = context and context.composition
  if not composition then return false end
  local segmentation = composition:toSegmentation()
  if not segmentation or not segmentation.get_segments then return false end
  local changed = false
  for _, segment in ipairs(segmentation:get_segments()) do
    if segment.status == kConfirmed then
      segment.status = kSelected
      changed = true
    end
  end
  return changed
end

-- 先清掉当前活动分段，保留前面已选的内容。活动分段就是整个输入时，才清空 context。
function M.clear_current(context, input)
  if not context or not input or input == "" then return end
  if #input < #(context.input or "") then
    context:pop_input(#input)
  else
    M.cancel(context)
  end
end

-- 显示用的预编辑文字由真实输入生成，不能反过来拿显示文字当查询码。
-- 四声码后的形码留在原始输入里，逐字尾段按“两声码＋形码”读取。两者共用预编辑格式，格式只改显示，不改查询或保存编码。
function M.shape_preedit(context, sound, shape)
  if shape == '' then return sound end
  local template = context:get_property('whitkey_shape_format')
  return (template:gsub('{sound}', function() return sound end)
      :gsub('{shape}', function() return shape end))
end

---@class InputView
---@field segment Segment|nil 当前分段，start 从 0 开始，_end 指向最后一个字符之后。
---@field raw string 当前分段的真实编码，不包含已选部分。
---@field sound string|nil 本次输入的音码部分。
---@field shape_suffix string 四声码后面追加的形码。
---@field tail_sound string|nil 有明确拆码身份的尾段音码。
---@field tail_shape string|nil 尾段形码，nil 表示不是拆码尾段，空串表示还没追加形码。

-- 查询时传入正在翻译的分段，处理按键时不传，直接读取 Rime 当前分段。
-- 这里只读状态。选择候选或修改 context 后，要重新读取，不能接着使用修改前的结果。
function M.read_input(context, segment, input, max_shape_length)
  local current, segmentation = M.current_segment(context)
  segment = segment or current
  if input == nil then
    input = segment and context.input:sub(segment.start + 1, segment._end) or ""
  end
  max_shape_length = max_shape_length or 4
  local sound, shape = core.sound_shape_parts(input)
  local full = sound ~= nil and #sound == 4 and #shape <= max_shape_length
  local previous = preceding_split(segment, segmentation)
  local tail = previous ~= nil and sound ~= nil
      and #sound == 2 and #shape <= max_shape_length
  return {
    segment=segment, raw=input,
    sound=sound,
    sound_length=sound and #sound or 0,
    shape=shape or "",
    shape_suffix=full and shape or "",
    full_composition=full,
    tail_sound=tail and sound or nil,
    tail_shape=tail and shape or nil,
    preedit=sound and #sound >= 3 and shape ~= ""
        and (#sound == 4 and M.shape_preedit(context, sound, shape) or input) or nil,
  }
end


local function current_view(env)
  return M.read_input(env.engine.context, nil, nil, env.shape_max_length)
end

-- 反引号继续占原来的省略码位，后面的形码也按这个结构追加。
-- 返回 nil 表示不走这个路径，返回 false 表示结构符合，但已不能继续补形。
local function shape_continuation(input, char, max_length)
  if char == "`" or input:find("`", 1, true) then
    if char ~= "`" and not core.is_shape_key(char) then return nil end
    local prior_sound, prior_shape = core.sound_shape_parts(input)
    if not prior_sound then prior_sound, prior_shape = core.omission_parts(input) end
    if prior_sound and #prior_sound == 2 and #prior_shape >= math.min(max_length, 6) then
      return false
    end
    local sound, shape = core.omission_parts(input .. char)
    if sound then return #shape <= max_length end
  elseif core.is_shape_key(char) then
    local sound, shape = core.sound_shape_parts(input)
    if sound then return #shape < max_length end
  end
  return nil
end

-- 开启死码拦截后，没有候选就保留原码。形码可以补到上限，其他普通字符先拦住。
local function block_dead(key, env, view)
  if not env.keep_dead_code or key:ctrl() or key:alt()
      or key:super() or key:caps() then return nil end
  local keycode = key.keycode
  if type(keycode) ~= "number" or keycode < 0x20 or keycode >= 0x7f then return nil end
  local context = env.engine.context
  if context:has_menu() then return nil end
  local input = view.raw
  local minimum = context:get_option("danzi_mode") and env.min_length_danzi or env.min_length
  if #input < minimum or (not core.is_sound_code(input:sub(1, 1), 1)
      and not core.omission_parts(input)) then return nil end
  local char = string.char(keycode)
  -- 还可以补形时让 speller 写入，达到上限后才拦住这个按键。省略码也按同样的规则处理。
  if shape_continuation(input, char, env.shape_max_length) then return nil end
  return core.kAccepted
end

-- 普通四声码和逐字尾段的形码都写进 context.input，不另存一份输入。
local function handle_shape(key, env, view)
  if key:ctrl() or key:alt() or key:super() or key:caps() then return nil end
  local keycode = key.keycode
  local char = type(keycode) == "number" and keycode >= 0x20 and keycode < 0x7f
      and string.char(keycode) or ""
  if not core.is_shape_key(char) and char ~= "`" and not key:eq(env.backspace_key) then return nil end
  local context = env.engine.context
  local input, segment = view.raw, view.segment
  local shape, tail_shape = view.shape_suffix, view.tail_shape

  if key:eq(env.backspace_key) then
    local suffix = tail_shape or shape
    if suffix ~= "" then
      -- 删逐字尾段的形码时，只删刚追加的字符。不能让 express_editor 先撤销前段选择。
      -- 拆码身份继续保留，下一次退格才知道该恢复首字选择前的哪些形码。
      if tail_shape ~= nil then
        context:pop_input(1)
        return core.kAccepted
      end
      return nil
    end
    if tail_shape == "" and M.restore_split(context) then return core.kAccepted end
    return nil
  end

  local continuation = shape_continuation(input, char, env.shape_max_length)
  if continuation == false then return core.kAccepted end
  if continuation == nil then return nil end
  if not segment or not segment:has_tag("abc") then return nil end
  if tail_shape ~= nil or view.full_composition then
    local length = tail_shape ~= nil and #tail_shape or #shape
    if length >= env.shape_max_length then return core.kAccepted end
    -- speller 的 BeginEditing 会重新打开已选前段，逐字尾段不能这样处理。
    -- 所以尾段直接追加形码，普通完整码仍交给 speller 写入。
    if tail_shape ~= nil then
      context:push_input(char)
      return core.kAccepted
    end
    return nil
  end
  return nil
end

local function commit_or_clear(env, input)
  local context = env.engine.context
  if context:has_menu() and context:get_selected_candidate() then
    local buffered = M.is(context, M.CREATED_WORD)
    if not buffered then M.prepare_word_creation(context) end
    context:confirm_current_selection()
    if not buffered then context:commit() end
  elseif env.auto_clear then
    M.clear_current(context, input)
  end
end

local function handle_topup(key, env, view)
  if key:ctrl() or key:alt() or key:super() or key:caps() then return nil end
  local keycode = key.keycode
  if type(keycode) ~= "number" or keycode < 0x20 or keycode >= 0x7f then return nil end
  local char, context = string.char(keycode), env.engine.context
  if not env.alphabet[char] then return nil end
  if view.segment and view.segment:has_tag("emoji_mode") then return nil end
  local input = view.raw
  if shape_continuation(input, char, env.shape_max_length) then return nil end
  local previous, first = input:sub(-1), input:sub(1, 1)
  if first == "" then first = char end
  if env.topup_command and env.topup_set[first] then return nil end
  local incoming, prior = env.topup_set[char] or false, env.topup_set[previous] or false
  local minimum = view.tail_sound and #view.tail_sound
      or (context:get_option("danzi_mode") and env.min_length_danzi or env.min_length)
  if (prior and not incoming) or (not prior and not incoming and #input >= minimum)
      or #input >= env.max_length then
    if env.keep_dead_code and core.is_sound_code(first, 1)
        and not context:has_menu() then return core.kAccepted end
    commit_or_clear(env, view.raw)
  end
  return nil
end

local function init_rules(env, config)
  env.backspace_key = KeyEvent("BackSpace")
  env.shape_max_length = math.max(1, config:get_int("shape_input/max_length") or 4)
  env.topup_set = core.string_to_set(config:get_string("topup/topup_with") or "avuio")
  env.alphabet = core.string_to_set(config:get_string("speller/alphabet")
      or "abcdefghijklmnopqrstuvwxyz`")
  env.min_length = math.max(1, config:get_int("topup/min_length") or 4)
  env.min_length_danzi = math.max(1,
      config:get_int("topup/min_length_danzi") or env.min_length)
  env.max_length = math.max(env.min_length, config:get_int("topup/max_length") or 6)
  env.auto_clear = config:get_bool("topup/auto_clear") or false
  env.keep_dead_code = config:get_bool("topup/keep_dead_code") ~= false
  env.topup_command = config:get_bool("topup/topup_command") or false
end

function M.process(key, env)
  if not key or key:release() then return core.kNoop end
  if env.engine.context:get_option("ascii_mode") then return core.kNoop end
  local view = current_view(env)
  local result = block_dead(key, env, view)
  if result then return result end
  result = handle_shape(key, env, view)
  if result then return result end
  return handle_topup(key, env, view) or core.kNoop
end


function M.init(env, config)
  config = config or env.engine.schema.config
  local context = env.engine.context
  local shape_format = config:get_string("shape_display/format") or "{sound} 形[{shape}]"
  if shape_format == "" then shape_format = "{sound} 形[{shape}]" end
  context:set_property("whitkey_shape_format", shape_format)
  local prompt = config:get_string("created_word/state_prompt") or "〔造词〕"
  local style_prompt = config:get_string("styled_english/state_prompt") or ""
  init_rules(env, config)
  M.reset(context)
  local last_input = context.input or ""
  local syncing = false
  env.session_connections = {}
  local function connect(notifier, callback)
    if notifier then
      env.session_connections[#env.session_connections + 1] = notifier:connect(callback)
    end
  end
  connect(context.commit_notifier, function(ctx) M.reset(ctx) end)
  local function update(ctx)
    local input = ctx.input or ""
    if input == "" and last_input ~= "" then M.reset(ctx) end
    -- 模式提示写在 Rime 分段的 prompt 中，没有候选也能显示，不会成为编码或上屏文字。
    local segment = M.current_segment(ctx)
    if segment then
      if M.is(ctx, M.CREATED_WORD) then segment.prompt = prompt
      elseif M.is(ctx, M.NORMAL) and input:match("^ov[A-Za-z ]*$") then
        -- 移动光标后，Rime 默认只查左边，但 OV 要转换整段英文。
        -- 所以把 OV 分段的 _end 移到完整输入末尾，避免选字体后还留下右半段去查中文。
        if segment.start == 0 then segment._end = #input end
        segment.prompt = style_prompt
      elseif segment.prompt == prompt or segment.prompt == style_prompt then
        segment.prompt = ""
      end
    end
    last_input = input
  end
  connect(context.update_notifier, function(ctx)
    if syncing then return end
    syncing = true
    local ok, err = pcall(update, ctx)
    syncing = false
    if not ok then core.report(nil, '输入状态更新失败', err) end
  end)
  connect(context.select_notifier, M.finish_split)
end


return M
