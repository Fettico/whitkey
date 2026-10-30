-- OB 继续补笔画时，把之前已当过首选的字往后放，让其他匹配字先出现。
-- 笔画仍由原生 table_translator 查询，这里只重排前十项，不删除候选。
local state = require "whitkey.input"
local M = {}
local WINDOW = 10

function M.init(env)
  env.enabled = env.engine.schema.config:get_bool("reverse_stroke_mode/postpone") == true
  if not env.enabled then return end
  env.history, env.input = {}, ""
  env.connection = env.engine.context.update_notifier:connect(function(context)
    -- 提交、退出、换模式或删回 ob 后，下次 OB 从头开始。
    -- 还没有 OB 历史时不做额外检查，普通输入也不反复创建空表。
    if env.input ~= "" and (not context.input:match("^ob[viuoa]+$")
        or not state.is(context, state.NORMAL)) then
      env.history, env.input = {}, ""
    end
  end)
end

function M.tags_match(segment, env)
  if not env.enabled or not segment:has_tag("reverse_stroke_mode") then return false end
  local context = env.engine.context
  return state.is(context, state.NORMAL) and context.input:match("^ob[viuoa]+$") ~= nil
      and context.caret_pos == #context.input
end

-- 按笔画长度记录当时的首选。同一个字后来再次成为首选，不覆盖较短码的记录。
-- 这样退格能恢复原顺序，同码刷新也不会继续轮换。
local function previous_firsts(input, env)
  local shared = 0
  while shared < math.min(#input, #env.input)
      and input:sub(shared + 1, shared + 1) == env.input:sub(shared + 1, shared + 1) do
    shared = shared + 1
  end
  for length = shared + 1, #env.input do env.history[length] = nil end
  env.input = input
  local known = {}
  for length = 1, #input - 1 do
    local text = env.history[length]
    if text then known[text] = length end
  end
  return known
end

function M.func(translation, env)
  local context = env.engine.context
  local segment = state.current_segment(context)
  local input = context.input:sub(3)
  local known = previous_firsts(input, env)
  local regular, postponed = {}, {}
  local count, flushed = 0, false

  local function flush()
    -- 先显示第一个尚未当过首选的字，再显示已当过首选的字，最后显示其余新字。
    -- 十项都当过首选时，最近一次的首选排在前面，不强行循环。
    table.sort(postponed, function(a, b) return known[a.text] > known[b.text] end)
    local first = regular[1] or postponed[1]
    env.history[#input] = first and first.text or nil
    flushed = true
    if regular[1] then yield(regular[1]) end
    for _, candidate in ipairs(postponed) do yield(candidate) end
    for index = 2, #regular do yield(regular[index]) end
  end

  for candidate in translation:iter() do
    if flushed then
      yield(candidate)
    elseif candidate._end < segment._end then
      -- 只重排覆盖当前整段输入的候选。部分匹配与后续候选保持原顺序。
      flush()
      yield(candidate)
    else
      local list = known[candidate.text] and postponed or regular
      list[#list + 1] = candidate
      count = count + 1
      if count == WINDOW then flush() end
    end
  end
  if not flushed then flush() end
end

function M.fini(env)
  if env.connection then env.connection:disconnect() end
  env.connection, env.history, env.input = nil, nil, nil
end

return M
