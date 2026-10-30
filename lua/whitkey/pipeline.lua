-- 这是主方案调用 Lua 的入口。按键按固定顺序传给功能模块，查询按分段标签传给对应模块。
-- 具体功能仍在 key_*、input 和 word_lookup 中。这里不保存个人词、不判断候选层级，也不重新实现 selector、speller 或 editor。

local core = require "whitkey.core"
local state = require "whitkey.input"
local actions = require "whitkey.candidate_actions"
local lookup = require "whitkey.word_lookup"
local key_a = require "whitkey.key_a"
local key_i = require "whitkey.key_i"
local key_o = require "whitkey.key_o"
local key_u = require "whitkey.key_u"
local key_v = require "whitkey.key_v"

local before, processor, translator, symbols = {}, {}, {}, {}

-- 原生识别的网址、邮箱和大写英文交给 Rime 处理原码。
-- 即使同时带 abc 标签，也不能再把它们当作中文编码查询或拦截。
local function native_literal(segment)
  return segment and (segment:has_tag("url") or segment:has_tag("email")
      or segment:has_tag("uppercase"))
end

-- U 造词、V 英文和 OV 正文先于 ascii_composer 处理。U 的符号、选字和提交共用一个按键 env。
-- 这样 Caps Lock 不会让前面的原生组件先接走控制键，中文顶功仍由后面的 input 处理。
function before.init(env)
  state.init_native_controls(env)
  env.key_u = {engine=env.engine}
  env.key_v = {engine=env.engine}
  env.key_o = {engine=env.engine}
  env.key_u.native_controls = env.native_controls
  env.key_o.native_controls = env.native_controls
  key_u.init(env.key_u, env.engine.schema.config, "processor")
  key_v.init(env.key_v, env.engine.schema.config, "processor")
end

function before.func(key, env)
  if not key then return core.kNoop end
  local context = env.engine.context
  local plain_return = not key:release() and not key:ctrl() and not key:alt() and not key:super()
      and not key:shift() and not context:get_option("ascii_mode") and core.is_return(key)
      and (context.input or "") ~= ""
  if plain_return then state.prepare_return(context) end
  local mode = state.mode(context)
  if mode == state.CREATED_ENTRY or mode == state.CREATED_WORD
      or context.input == '' and key.keycode == string.byte('u') then
    return key_u.process(key, env.key_u)
  end
  if state.is_literal(context)
      or context.input == '' and key.keycode == string.byte(env.key_v.prefix) then
    return key_v.process(key, env.key_v)
  end
  if key_o.is_styled(context) then return key_o.process(key, env.key_o) end
  -- 元书和电脑的回车码可能不同，只在这个原生接口边界统一一次。
  if plain_return and (key:caps() or key.keycode == 0xff8d or key.keycode == 0x0d) then
    return state.native_control(KeyEvent('Return'), env)
  end
  return core.kNoop
end

function before.fini(env)
  key_u.fini(env.key_u)
  key_v.fini(env.key_v)
  key_o.fini(env.key_o)
  env.key_u, env.key_v, env.key_o = nil, nil, nil
  env.native_controls = nil
end

-- recognizer 完成分段后，再处理依赖候选或标签的按键。依次调用候选动作、普通输入规则和 I 的无候选空格。
-- U 不重复处理专用按键；它放行的普通键继续走这里和原生组件。
-- U 入口数字先判断“唯一候选＋数字”，正式造词则只按普通选字处理。
function processor.init(env)
  local config = env.engine.schema.config
  state.init(env, config)
  env.actions = {engine=env.engine}
  env.key_i = {engine=env.engine}
  actions.init(env.actions)
  key_i.init(env.key_i, config, "processor")
end

function processor.func(key, env)
  if not key or key:release() then return core.kNoop end
  if env.engine.context:get_option("ascii_mode") then return core.kNoop end
  -- OV 的输入已由 before 处理，选择和编辑继续交给原生组件，不再走普通中文按键规则。
  if key_o.is_styled(env.engine.context) then return core.kNoop end
  if native_literal(state.current_segment(env.engine.context)) then return core.kNoop end

  local result = actions.func(key, env.actions)
  if result ~= core.kNoop then return result end
  result = state.process(key, env)
  if result ~= core.kNoop then return result end
  result = key_i.process(key, env.key_i)
  return result
end

function processor.fini(env)
  key_i.fini(env.key_i)
  actions.fini(env.actions)
  state.fini(env)
  env.actions, env.key_i = nil, nil
end

-- 所有 Lua 候选共用这个 translator 入口。普通 abc 仍调用 Rime table_translator。
-- Lua 再接入固定词、个人词和拆码候选，设置拆码范围，并安排这些候选的顺序。
function translator.init(env)
  local config = env.engine.schema.config
  env.entry_a = state.entry_text(config, "a")
  env.entry_u = state.entry_text(config, "u")
  env.lookup = {engine=env.engine}
  env.key_u = {engine=env.engine}
  env.key_v = {engine=env.engine}
  env.key_a = {engine=env.engine}
  env.key_i = {engine=env.engine}
  env.key_o = {engine=env.engine}
  lookup.init(env.lookup, config)
  key_u.init(env.key_u, config, "translator")
  key_v.init(env.key_v, config, "translator")
  key_a.init(env.key_a, config)
  key_i.init(env.key_i, config, "translator")
  key_o.init(env.key_o)
end

function translator.func(input, segment, env)
  local context = env.engine.context
  key_i.release_idle(env.key_i, context)
  if context.input == "a" and env.entry_a ~= "" and state.is(context, state.NORMAL) then
    return state.emit_entry(env.entry_a, segment, "a")
  end
  if context.input == "u" and env.entry_u ~= "" and state.is(context, state.CREATED_ENTRY) then
    return state.emit_entry(env.entry_u, segment, "u")
  end
  if state.is_literal(context) then return key_v.translate(input, segment, env.key_v) end
  if segment:has_tag("eng_quick_mode") then
    key_u.translate(input, segment, env.key_u)
    return key_v.translate(input, segment, env.key_v)
  end
  if segment:has_tag("custom_phrase_mode") then
    return key_a.translate(input, segment, env.key_a)
  end
  if segment:has_tag("emoji_mode") then
    return key_i.translate(input, segment, env.key_i)
  end
  -- O 命令也可能带 abc 标签，所以先检查专用 lua 标签，再决定是否查普通中文。
  if segment:has_tag("lua") or segment:has_tag("styled_english") then
    return key_o.translate(input, segment, env.key_o)
  end
  if native_literal(segment) then return end
  if segment:has_tag("abc") then return lookup.translate(input, segment, env.lookup) end
end

function translator.fini(env)
  key_o.fini(env.key_o)
  key_i.fini(env.key_i)
  key_a.fini(env.key_a)
  key_v.fini(env.key_v)
  key_u.fini(env.key_u)
  lookup.fini(env.lookup)
  env.lookup, env.key_u, env.key_v = nil, nil, nil
  env.key_a, env.key_i, env.key_o = nil, nil, nil
end

function symbols.init(env)
  env.symbols = core.read_created_symbols(env.engine.schema.config)
end
function symbols.tags_match(segment)
  return segment:has_tag('punct') or segment:has_tag('punct_number')
end
function symbols.func(translation, env)
  local context = env.engine.context
  return key_u.filter_symbols(translation, context, state.current_segment(context), env.symbols)
end
return {before=before, processor=processor, translator=translator, symbols=symbols}
