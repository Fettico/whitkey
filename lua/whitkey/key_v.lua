-- V 英文正文直接放在 context.input 中，不另存缓冲或占位串。
-- 只有入口 v 时可以选快捷单字；有正文后，空格、数字和标点都进入正文，最后按 Enter 提交。
local core = require "whitkey.core"
local state = require "whitkey.input"
local M = {}

local keypad = {
  KP_0="0", KP_1="1", KP_2="2", KP_3="3", KP_4="4",
  KP_5="5", KP_6="6", KP_7="7", KP_8="8", KP_9="9",
  KP_Add="+", KP_Subtract="-", KP_Multiply="*", KP_Divide="/", KP_Decimal=".",
}

-- 把 Windows 或 Rime 的按键事件还原成实际输入的半角 ASCII 字符。
local function key_to_char(key)
  if key:ctrl() or key:alt() or key:super() then return nil end
  if core.is_space(key) then return " " end
  local repr = core.key_repr(key)
  -- Caps Lock 不改变小键盘数字，先去掉 Lock 标记再读取键名。
  local keypad_char = keypad[(repr:gsub("Lock%+", ""))]
  if keypad_char then return keypad_char end
  local keycode = key.keycode
  if type(keycode) ~= "number" or keycode < 0x21 or keycode > 0x7e then return nil end
  local char = string.char(keycode)
  if char:match("[A-Za-z]") then
    -- 电脑可能发送小写字母加 Shift，手机可能直接发送没有 Shift 的大写字母，两种方式都要识别。
    if key:shift() or key:caps() then
      local upper = key:shift() ~= key:caps()
      return upper and char:upper() or char:lower()
    end
    return char
  end
  return core.ascii_key(key)
end

local function plain_trigger(key, prefix)
  return #prefix == 1 and key.keycode == string.byte(prefix)
      and not key:shift() and not key:ctrl() and not key:alt()
      and not key:super() and not key:caps()
end

local function set_input(context, prefix, body)
  -- 删回只剩 v 时，Rime 可能还保留已确认的 affix 前缀段。
  -- 先清掉旧分段，再建立入口，才能重新显示快捷单字，而不是留下空正文段。
  if body == "" and context.input ~= "" then context:clear() end
  state.begin(context, body == "" and state.LITERAL_ENTRY or state.LITERAL_ENGLISH)
  context.input = prefix .. body
end

function M.init(env, config, stage)
  config = config or env.engine.schema.config
  env.stage = stage
  env.prefix = config:get_string("eng_quick_mode/prefix") or "v"
  env.entry = state.entry_text(config, "v")
end

function M.process(key, env)
  local context, prefix = env.engine.context, env.prefix
  if context:get_option("ascii_mode") or state.is(context, state.CREATED_WORD) then return core.kNoop end
  if not state.is_literal(context) then
    if not key:release() and context.input == "" and plain_trigger(key, prefix) then
      set_input(context, prefix, "")
      return core.kAccepted
    end
    return core.kNoop
  end
  -- 外部清空输入时，input 会退出 V 模式。
  -- 如果外部直接换成其他输入，这里也退出，避免把新输入继续当成 V 正文。
  if context.input:sub(1, #prefix) ~= prefix then
    state.reset(context)
    return core.kNoop
  end
  if key.keycode == 0xffe5 or core.key_repr(key):match("Caps_Lock$") then return core.kRejected end
  if key:release() then return core.kAccepted end
  if key:ctrl() or key:alt() or key:super() then return core.kAccepted end

  local body = context.input:sub(#prefix + 1)
  if core.is_return(key) then
    local text = body == "" and prefix or body
    state.cancel(context)
    env.engine:commit_text(text)
    return core.kAccepted
  end
  if key.keycode == 0xff1b or key.keycode == 0xffff then
    state.cancel(context)
    return core.kAccepted
  end
  if body == "" and env.entry ~= "" and core.is_space(key) then
    context:commit()
    return core.kAccepted
  end
  if key.keycode == 0xff08 then
    if body == "" then state.cancel(context)
    else set_input(context, prefix, body:sub(1, -2)) end
    return core.kAccepted
  end
  local char = key_to_char(key)
  if char then set_input(context, prefix, body .. char) end
  -- 没有定义行为的导航键也留在 V 会话内，避免后面的 editor 意外提交正文。
  return core.kAccepted
end

function M.translate(input, segment, env)
  local context = env.engine.context
  if not state.is_literal(context) then return end
  -- affix 的前缀段不生成正文候选，避免同一正文显示两遍。
  local body = context.input:sub(#env.prefix + 1)
  if body ~= "" and segment._end <= #env.prefix then return end
  if body == "" and env.entry ~= "" then return state.emit_entry(env.entry, segment, env.prefix) end
  local text = body == "" and env.prefix or body
  local candidate = Candidate("eng_quick", segment.start, segment._end, text, "")
  candidate.quality, candidate.preedit = 10000, text
  yield(candidate)
end

function M.fini(env)
  if env.stage ~= "translator" then state.reset(env.engine.context) end
  env.prefix, env.entry = nil, nil
end
return M
