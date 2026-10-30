-- 这里生成 O 键的日期、数字、算式、统计和 OV 字体候选。算式的解析与计算由 o_calculator 完成。

local calculator = require "whitkey.o_calculator"
local core = require "whitkey.core"
local display = require "whitkey.label"
local state = require "whitkey.input"
local M = {}

function M.is_styled(context)
  return state.is(context, state.NORMAL) and (context.input or ""):sub(1, 2) == "ov"
end

-- OV 的英文直接保存在 context.input，不另建缓冲区。大小写和正文空格在 ascii_composer 前接收，避免 Shift 把输入切成临时英文。
-- 选择、退格、导航、Esc 和 Enter 使用 Rime 原生接口和编辑组件。
function M.process(key, env)
  local context = env.engine.context
  if context:get_option("ascii_mode") or not M.is_styled(context) then return core.kNoop end
  local code = key.keycode
  if code == 0xffe5 then return core.kRejected end
  if (code >= 0xffe1 and code <= 0xffee) or code == 0xff30 then return core.kAccepted end
  if key:release() then return core.kNoop end
  if key:ctrl() or key:alt() or key:super() then return core.kAccepted end
  if core.is_return(key) then
    -- 普通 Enter 已由共用入口把光标移到末尾，OV 的 Shift+Enter 也先做同样处理。
    -- 所有回车都通过 native_control 统一按键写法，再交给原生 editor 上屏完整原码。
    if key:shift() then state.prepare_return(context) end
    return state.native_control(key, env)
  end
  if code >= 0x41 and code <= 0x5a or code >= 0x61 and code <= 0x7a then
    local char = string.char(code)
    if key:shift() or key:caps() then
      char = key:shift() ~= key:caps() and char:upper() or char:lower()
    end
    context:push_input(char)
    return core.kAccepted
  end
  if core.is_space(key) then
    if not key:shift() then
      context:push_input(" ")
      return core.kAccepted
    end
    -- Shift+空格调用原生确认接口，Caps Lock 开着也能选择当前高亮。
    -- 没有正文或正文全为空格时没有候选，这次按键不提交入口原码。
    if context:has_menu() then context:confirm_current_selection() end
    return core.kAccepted
  end
  local digit = code >= 0xffb0 and code <= 0xffb9 and code - 0xffb0
      or code >= 0x30 and code <= 0x39 and code - 0x30
  if digit then
    if not key:shift() and context:has_menu() then
      -- recognizer 的大写英文规则可能先接走数字，因此这里直接调用原生选择接口。
      -- 1～9 选前九项，0 选第十项，用绝对索引，翻页后含义也不变。不存在的位置由原生 select 检查，更多样式可用导航、鼠标或 Shift+空格选择。
      context:select(digit == 0 and 9 or digit - 1)
    end
    return core.kAccepted
  end
  if code >= 0xffaa and code <= 0xffaf then return core.kAccepted end
  if code >= 0x20 and code < 0x7f then return core.kAccepted end
  if key:caps() then return state.native_control(key, env) end
  return core.kNoop
end

-- 第一次显示 OV 候选时才读取样式，检查字母数量，再建立转换表。
-- 转换表保存在这个 translator 的 env 中，重新加载方案时一起释放。
local function letter_styles(env)
  if env.styles then return env.styles end
  local styles = {}
  local config = env.engine.schema.config
  local rows = config:get_list("styled_english/styles")
  if not rows and not config:is_null("styled_english/styles") then
    core.report(env.engine.context, "OV 样式配置无效", "styled_english/styles 必须是列表")
  end
  for index = 0, (rows and rows.size or 0) - 1 do
    local path = "styled_english/styles/@" .. index .. "/"
    local name = config:get_string(path .. "name") or ""
    local upper = config:get_string(path .. "upper") or ""
    local lower = config:get_string(path .. "lower") or ""
    if name ~= "" and core.utf8_length(upper) == 26 and core.utf8_length(lower) == 26
        and not upper:find("%s") and not lower:find("%s") then
      local style = {name=name, map={}}
      for position, char in ipairs(core.split_chars(upper)) do
        style.map[string.char(0x40 + position)] = char
      end
      for position, char in ipairs(core.split_chars(lower)) do
        style.map[string.char(0x60 + position)] = char
      end
      styles[#styles + 1] = style
    else
      core.report(env.engine.context, "OV 样式配置无效",
          "第 " .. (index + 1) .. " 项需要名称和按字母顺序填写的大写、小写各 26 个字符，字母串不含空白")
    end
  end
  env.styles = styles
  return styles
end

local function yield_styled(input, segment, env)
  if not M.is_styled(env.engine.context) or segment.start ~= 0 then return false end
  -- Rime 默认只翻译光标左侧，OV 要转换完整正文，因此读取完整 context.input。
  -- 候选的 _end 也设到输入末尾，避免光标在中间时只上屏前半段。
  local raw = env.engine.context.input
  local body = raw:sub(3)
  if not body:find("[A-Za-z]") or not body:match("^[A-Za-z ]+$") then return true end
  for _, style in ipairs(letter_styles(env)) do
    local text = body:gsub("[A-Za-z]", style.map)
    yield(Candidate("styled_english", segment.start, #raw, text,
        style.name))
  end
  return true
end

-- 逐字符日期模式中，s/b/q/w 对应十/百/千/万，n/y/r 对应年/月/日。
local datechars = {
  ["0"]="零", ["1"]="一", ["2"]="二", ["3"]="三", ["4"]="四",
  ["5"]="五", ["6"]="六", ["7"]="七", ["8"]="八", ["9"]="九",
  s="十", b="百", q="千", w="万", n="年", y="月", r="日",
}

-- 同一个数字依次生成简体小写、简体大写、繁体小写、繁体大写四个候选。
local confs = {
  { comment_key="number_lower", number={[0]="零","一","二","三","四","五","六","七","八","九"},
    suffix={[0]="","十","百","千"}, suffix2={[0]="","万","亿","万亿","亿亿"} },
  { comment_key="number_upper", number={[0]="零","壹","贰","叁","肆","伍","陆","柒","捌","玖"},
    suffix={[0]="","拾","佰","仟"}, suffix2={[0]="","万","亿","万亿","亿亿"} },
  { comment_key="number_trad_lower", number={[0]="零","一","二","三","四","五","六","七","八","九"},
    suffix={[0]="","十","百","千"}, suffix2={[0]="","萬","億","萬億","億億"} },
  { comment_key="number_trad_upper", number={[0]="零","壹","貳","參","肆","伍","陸","柒","捌","玖"},
    suffix={[0]="","拾","佰","仟"}, suffix2={[0]="","萬","億","萬億","億億"} },
}

-- 日期单位模式逐个字符转换为表中汉字，只接受表内的数字和单位简码。遇到未知字符就返回 nil。
local function to_date_chars(input)
  local result = ""
  for char in input:gmatch(".") do
    if not datechars[char] then return nil end
    result = result .. datechars[char]
  end
  return result
end

-- 从右向左读最多四位数字，先生成“个、十、百、千”的一个小节。
local function read_segment(conf, digits)
  local result, index, zero = "", 0, true
  while #digits > 0 do
    local digit = tonumber(digits:sub(-1))
    if digit ~= 0 then
      result, zero = conf.number[digit] .. conf.suffix[index] .. result, false
    else
      if not zero then result = conf.number[0] .. result end
      zero = true
    end
    index, digits = index + 1, digits:sub(1, -2)
  end
  return result
end

-- 每四位组成一节，再加万、亿、万亿等单位。节与节之间需要的零也在这里处理。
local function read_number(conf, digits)
  digits = digits:gsub("^0+", "")
  if digits == "" then return conf.number[0] end
  local groups = {}
  while #digits > 0 do
    table.insert(groups, 1, digits:sub(-4))
    digits = digits:sub(1, -5)
  end
  local result, skipped = "", false
  for position, group in ipairs(groups) do
    local value = tonumber(group)
    if value == 0 then
      if result ~= "" then skipped = true end
    else
      if result ~= "" and (skipped or value < 1000) then result = result .. conf.number[0] end
      local part = read_segment(conf, group:gsub("^0+", ""))
      result = result .. part .. conf.suffix2[#groups - position]
      skipped = false
    end
  end
  if conf.number[1] == "一" then result = result:gsub("^一十", "十") end
  return result
end

-- rq/sj/rs 分别生成日期、时间和日期时间，各给出中文格式与数字格式两个候选。
local function yield_datetime(command, segment)
  local values
  if command == "rq" then
    values = { os.date("%Y年%m月%d日"), os.date("%Y-%m-%d") }
  elseif command == "sj" then
    values = { os.date("%H时%M分%S秒"), os.date("%H:%M:%S") }
  elseif command == "rs" then
    values = { os.date("%Y年%m月%d日%H时%M分%S秒"), os.date("%Y-%m-%d %H:%M:%S") }
  end
  if not values then return false end
  for _, value in ipairs(values) do
    yield(Candidate("datetime", segment.start, segment._end, value, ""))
  end
  return true
end

function M.init(env)
  env.labels = display.read_labels(env.engine.schema.config)
  env.prefix = env.engine.schema.config:get_string("lua/input") or "o"
  env.entry = state.entry_text(env.engine.schema.config, "o")
end

-- 先检查 OV。其他 O 命令依次检查统计、日期时间、纯数字和逐字日期，最后才尝试计算器。
function M.translate(input, segment, env)
  if yield_styled(input, segment, env) then return end
  local prefix = env.prefix or "o"
  if input == prefix and env.entry ~= "" and state.is(env.engine.context, state.NORMAL) then
    return state.emit_entry(env.entry, segment, prefix)
  end
  if input:sub(1, #prefix) ~= prefix or #input <= #prefix then return end
  local command = input:sub(#prefix + 1)
  if command == "tj" then
    local report = env.engine.context:get_property("whitkey_otj_stats_report")
    if report and report ~= "" then
      local comment = display.comment("statistics", nil, env.labels)
      yield(Candidate("statistics", segment.start, segment._end, report, comment))
    end
    return
  end
  if yield_datetime(command, segment) then return end

  -- 纯数字最多接受 20 位，避免生成过长中文数字，也限制这一步的计算量。
  if command:match("^%d+$") and #command <= 20 then
    for _, conf in ipairs(confs) do
      yield(Candidate("number", segment.start, segment._end,
          read_number(conf, command), display.comment(conf.comment_key, nil, env.labels)))
    end
    return
  end

  -- 同时有数字和单位简码时，逐字符生成日期或数量表达。
  if command:match("^[0-9sbqwnyr]+$") and command:match("%d")
      and command:match("[sbqwnyr]") then
    local value = to_date_chars(command)
    if value then
      yield(Candidate("number", segment.start, segment._end, value, ""))
      if value:find("零", 1, true) then
        yield(Candidate("number", segment.start, segment._end,
            value:gsub("零", "〇"), ""))
      end
    end
    return
  end

  -- 其他 O 命令才按算式解析。先把 # 换成空格，供算式中需要分隔的位置使用。
  local expression = command:gsub("#", " ")
  local value = calculator.evaluate(expression)
  if value == nil then return end
  local result = calculator.format_number(value)
  yield(Candidate("number", segment.start, segment._end,
      expression .. " = " .. result, display.comment("equation", nil, env.labels)))
  yield(Candidate("number", segment.start, segment._end, result, display.comment("answer", nil, env.labels)))
  yield(Candidate("number", segment.start, segment._end, expression, display.comment("expression", nil, env.labels)))
end

function M.fini(env) env.prefix, env.labels, env.styles, env.native_controls = nil, nil, nil, nil end
-- M.func 用于单独注册 Lua translator。当前主方案由 pipeline 调用 translate。
M.func = M.translate
return M
