-- 先读数字和括号，再处理一元正负号、乘除和加减，每一步只处理自己的优先级。
-- 输入只当算式解析，不作为 Lua 代码执行。

local M = {}
-- 限制算式长度、嵌套深度和运算次数，避免异常长输入引起卡顿或栈溢出。
local MAX_EXPRESSION_LENGTH, MAX_PARSE_DEPTH, MAX_OPERATIONS = 512, 64, 256

local function skip_spaces(state)
  while state.pos <= state.length and state.text:sub(state.pos, state.pos):match("%s") do
    state.pos = state.pos + 1
  end
end

-- NaN 和正负无穷不作为正常结果上屏。计算得到这些值时返回失败，不生成候选。
local function finite(value)
  return value == value and value ~= math.huge and value ~= -math.huge
end

local function operation(state)
  state.operations = state.operations + 1
  if state.operations > MAX_OPERATIONS then return false, "too many operations" end
  return true
end

-- 从当前位置读取十进制整数或小数，再把 state.pos 移到这个数字后面。
local function parse_number(state)
  skip_spaces(state)
  local start, has_digit = state.pos, false
  while state.pos <= state.length and state.text:sub(state.pos, state.pos):match("%d") do
    state.pos, has_digit = state.pos + 1, true
  end
  if state.text:sub(state.pos, state.pos) == "." then
    state.pos = state.pos + 1
    while state.pos <= state.length and state.text:sub(state.pos, state.pos):match("%d") do
      state.pos, has_digit = state.pos + 1, true
    end
  end
  if not has_digit then return nil, "number expected" end
  -- 把数值明确转成浮点数。Lua 5.3 及以上的整数运算越界会回绕，这里避免产生这种错误结果。
  local value = tonumber(state.text:sub(start, state.pos - 1))
  if value then value = value + 0.0 end
  if not value or not finite(value) then return nil, "invalid number" end
  return value
end

local parse_expression

-- 读取普通数字，或者括号中的完整算式，同时检查括号嵌套是否超过上限。
local function parse_primary(state)
  skip_spaces(state)
  if state.text:sub(state.pos, state.pos) ~= "(" then return parse_number(state) end
  state.pos, state.depth = state.pos + 1, state.depth + 1
  if state.depth > MAX_PARSE_DEPTH then
    state.depth = state.depth - 1
    return nil, "expression is nested too deeply"
  end
  local value, err = parse_expression(state)
  state.depth = state.depth - 1
  if value == nil then return nil, err end
  skip_spaces(state)
  if state.text:sub(state.pos, state.pos) ~= ")" then
    return nil, "closing parenthesis expected"
  end
  state.pos = state.pos + 1
  return value
end

-- 处理数字前的一元 + 和 -，包括 --2 或 -(1+2) 这样的输入。
local function parse_unary(state)
  skip_spaces(state)
  local operator = state.text:sub(state.pos, state.pos)
  if operator ~= "+" and operator ~= "-" then return parse_primary(state) end
  local ok, err = operation(state)
  if not ok then return nil, err end
  state.pos, state.depth = state.pos + 1, state.depth + 1
  if state.depth > MAX_PARSE_DEPTH then
    state.depth = state.depth - 1
    return nil, "expression is nested too deeply"
  end
  local value
  value, err = parse_unary(state)
  state.depth = state.depth - 1
  if value == nil then return nil, err end
  return operator == "-" and -value or value
end

-- 这一层计算乘除。除数为 0 时返回失败，不生成无穷值候选。
local function parse_term(state)
  local value, err = parse_unary(state)
  if value == nil then return nil, err end
  while true do
    skip_spaces(state)
    local operator = state.text:sub(state.pos, state.pos)
    if operator ~= "*" and operator ~= "/" then break end
    local ok
    ok, err = operation(state)
    if not ok then return nil, err end
    state.pos = state.pos + 1
    local right
    right, err = parse_unary(state)
    if right == nil then return nil, err end
    if operator == "*" then
      value = value * right
    elseif right == 0 then
      return nil, "division by zero"
    else
      value = value / right
    end
    if not finite(value) then return nil, "result is outside the supported range" end
  end
  return value
end

-- 最外层处理加减，先通过 parse_term 算右侧乘除，再做加减，所以乘除仍先于加减。
parse_expression = function(state)
  local value, err = parse_term(state)
  if value == nil then return nil, err end
  while true do
    skip_spaces(state)
    local operator = state.text:sub(state.pos, state.pos)
    if operator ~= "+" and operator ~= "-" then break end
    local ok
    ok, err = operation(state)
    if not ok then return nil, err end
    state.pos = state.pos + 1
    local right
    right, err = parse_term(state)
    if right == nil then return nil, err end
    value = operator == "+" and value + right or value - right
    if not finite(value) then return nil, "result is outside the supported range" end
  end
  return value
end

function M.evaluate(expression)
  if type(expression) ~= "string" or #expression == 0
      or #expression > MAX_EXPRESSION_LENGTH then return nil, "invalid length" end
  local state = { text = expression, pos = 1, length = #expression, depth = 0, operations = 0 }
  local value, err = parse_expression(state)
  if value == nil then return nil, err end
  skip_spaces(state)
  if state.pos <= state.length then return nil, "unsupported character or operator" end
  return value
end

-- 结果保留约 15 位有效数字，不显示无意义的末尾零。
function M.format_number(value)
  return value == 0 and "0" or string.format("%.15g", value)
end

return M
