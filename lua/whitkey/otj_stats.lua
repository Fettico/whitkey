-- 先记录按键，在上屏时计算字数和击键，生成报告，再按保存条件写文件。
-- 这里只观察，不拦按键、不选候选、不改 composition。统计状态由这个 processor 管，O 翻译器从 Context property 取报告，不另存全局报告，也不逐键写文件。
local core = require "whitkey.core"
local store = require "whitkey.personal_store"
local state = require "whitkey.input"
local meta = require "whitkey.candidate"
local M = {}

-- 这里写统计计算的默认值。保存间隔和峰值最短时间，在 init 中读取部署后的配置。
local RULE = {
  average_gap = 5000,
  average_min = 1000,
  total_min = 15000,
  peak_gap = 2000,
  peak_min = 15000,
  max_speed_chars = 10,
  save_ms = 60000,
  save_chars = 200,
}
local REPORT = "whitkey_otj_stats_report"
local FIELDS = {"characters", "commits", "single", "keys", "lifetime",
  "average_chars", "average_ms", "average_keys", "peak_count", "peak1", "peak2"}
local pools = {}

local function copy(t)
  local result = {}
  for key, value in pairs(t or {}) do result[key] = value end
  return result
end

local function today()
  return os.date("%Y%m%d")
end

local function clock()
  if rime_api.get_time_ms then return math.floor(rime_api.get_time_ms()) end
  -- 旧客户端只能提供秒级时间，这时用 os.time。os.clock 是 CPU 耗时，不能拿它当真实打字时间。
  return os.time() * 1000
end

local function blank(day)
  local result = {day=day}
  for _, field in ipairs(FIELDS) do result[field] = 0 end
  return result
end

-- 整次上屏内容全是汉字时才计入。含英文、混输、数字、标点或 Emoji 的提交整次排除，汉字范围按指定的 Unicode 区间判断。
-- 这里只算字数，统计文件不保存上屏文字。
function M.chinese_count(text)
  return core.han_count(text)
end

-- 只保存最高和次高两个速度样本。相同速度也可以算两个样本，用来计算次高峰。
local function peak_add(d, speed)
  if speed >= d.peak1 then
    d.peak2, d.peak1 = d.peak1, speed
  elseif speed > d.peak2 then
    d.peak2 = speed
  end
  d.peak_count = math.min(2, d.peak_count + 1)
end

local function settle(d, sample, kind, rule)
  rule = rule or RULE
  if not sample.start or not sample.commit or (sample.chars or 0) < 2 then return end
  local elapsed = sample.commit - sample.start
  if kind == "average" and elapsed >= RULE.average_min then
    d.average_chars = d.average_chars + sample.chars
    d.average_ms = d.average_ms + elapsed
    d.average_keys = d.average_keys + (sample.keys or 0)
  elseif kind == "peak" and elapsed >= rule.peak_min then
    local speed = math.floor(sample.chars * 60000 / elapsed + 0.5)
    peak_add(d, math.max(0, math.min(2000, speed)))
  end
end

local function activity(trial, kind, now)
  local sample = trial[kind]
  local gap = kind == "average" and RULE.average_gap or RULE.peak_gap
  if sample.start and (now < sample.activity or now - sample.activity > gap) then
    settle(trial.delta, sample, kind, trial.rule)
    sample = {}
    trial[kind] = sample
  end
  if not sample.start then
    sample.start, sample.chars, sample.keys = now, 0, 0
  end
  sample.activity = now
end

local function merge(d, delta)
  for _, field in ipairs({"average_chars", "average_ms", "average_keys"}) do
    d[field] = d[field] + delta[field]
  end
  if delta.peak_count > 0 then peak_add(d, delta.peak1) end
  if delta.peak_count > 1 then peak_add(d, delta.peak2) end
end

local function end_samples(env)
  settle(env.pool.data, env.average, "average", env.rule)
  settle(env.pool.data, env.peak, "peak", env.rule)
  env.average, env.peak = {}, {}
end

local function new_trial(env)
  return {
    keys=0,
    average=copy(env.average),
    peak=copy(env.peak),
    delta=blank(env.pool.data.day),
    rule=env.rule,
  }
end

local function touch(p, now)
  activity(p, "average", now)
  activity(p, "peak", now)
end

-- 统计文件只存固定的数字字段。先检查格式和数值，文件损坏就保留原文件，不清零后覆盖保存。
function M.decode(text)
  if not text or text == "" then return nil, "统计文件为空" end
  local header, day, body = text:match(
      "^(whitkey%-statistics%-1)\n(%d%d%d%d%d%d%d%d)\n(.*)$")
  if not header then return nil, "统计文件格式不正确" end
  local d, seen = blank(day), {}
  for line in body:gmatch("[^\n]+") do
    local key, value = line:match("^([%w_]+)\t(%d+)$")
    local number = tonumber(value)
    if not key or d[key] == nil or key == "day" or seen[key]
        or not number or number > 1e15 then
      return nil, "统计字段损坏"
    end
    d[key], seen[key] = number, true
  end
  for _, field in ipairs(FIELDS) do
    if not seen[field] then return nil, "统计文件不完整" end
  end
  if d.lifetime < d.characters or d.single > d.characters or d.commits > d.characters
      or d.peak_count > 2 or d.peak1 > 2000 or d.peak2 > d.peak1 then
    return nil, "统计数值不一致"
  end
  return d
end

function M.encode(d)
  local lines = {"whitkey-statistics-1", d.day}
  for _, field in ipairs(FIELDS) do
    lines[#lines + 1] = field .. "\t" .. string.format("%.0f", d[field])
  end
  return table.concat(lines, "\n") .. "\n"
end

local function snapshot(pool)
  local d = copy(pool.data)
  for env in pairs(pool.users) do
    settle(d, env.average, "average", env.rule)
    settle(d, env.peak, "peak", env.rule)
  end
  return d
end

local function save(env, now, force)
  local p = env.pool
  local rule = env.rule or RULE
  if p.read_error or not p.dirty then return end
  if not force and now - p.saved_at < rule.save_ms and p.unsaved < rule.save_chars then
    return
  end
  -- 保存失败时继续保留内存中尚未保存的累计，并限制再次尝试的频率。
  -- 磁盘错误不能阻断正常输入。
  if p.failed_at and now - p.failed_at < rule.save_ms then return end
  local ok, err = store.write_snapshot(p.path, M.encode(snapshot(p)))
  if ok then
    p.dirty, p.unsaved, p.saved_at, p.failed_at = false, 0, now, nil
  else
    p.failed_at = now
    core.report(nil, "统计暂未保存，将重试", err)
  end
end

local function roll_day(env, day)
  local p = env.pool
  if p.data.day == day then return end
  local lifetime = p.data.lifetime
  for user in pairs(p.users) do
    user.average, user.peak = {}, {}
    if user.pending then
      user.pending.average, user.pending.peak = {}, {}
      user.pending.delta = blank(day)
    end
  end
  p.data = blank(day)
  p.data.lifetime = lifetime
  p.dirty = true
end

-- 按发行版代号取得客户端名称，统计报告只显示这个名称。
function M.client_name(code)
  local names = {
    weasel="小狼毫",
    squirrel="鼠须管",
    trime="同文输入法",
    hamster3="元书输入法",
    hamster="仓输入法",
    cobra="元书输入法",
    lyraime="灵韵输入法",
    xime="曦码输入法",
  }
  local normalized = (code or ""):lower():gsub("%s", ""):gsub("\226\128\139", "")
  return names[normalized] or "未知客户端"
end

function M.format(d, schema, client, line_ending)
  schema = (schema or "纯白键道"):gsub("%s+$", "")
  client = (client or "未知客户端"):gsub("%s+$", "")
  local enough = d.average_ms >= RULE.total_min
  local average = enough and math.floor(d.average_chars * 60000 / d.average_ms + 0.5) or nil
  local peak = d.peak_count > 0 and (d.peak_count == 1 and d.peak1 or d.peak2) or nil
  if peak and average and peak < average then
    peak = nil -- 峰值低于均速就不显示。
  end
  local single = d.characters > 0
      and math.floor(d.single * 100 / d.characters + 0.5) or 0
  local left = {
    tostring(average or "-"),
    tostring(single) .. "%",
    d.characters > 0 and string.format("%.2f", d.keys / d.characters) or "-",
  }
  -- 聊天窗口可能合并连续普通空格，这里使用不会被合并的排版空格保持对齐。
  -- 按半个数字宽度计算：数字占 2，小数点占 1，百分号占 3。
  local function units(value)
    local width = 0
    for character in value:gmatch('.') do
      width = width + (character == '.' and 1 or character == '%' and 3 or 2)
    end
    return width
  end
  local width = 0
  for _, value in ipairs(left) do width = math.max(width, units(value)) end
  local function row(label, value, right)
    local pad = string.rep(" ", width - units(value))
    return label .. " " .. pad .. value .. "  ·  " .. right:gsub(' ', ' ')
  end
  local date = d.day:sub(3, 4) .. "/" .. d.day:sub(5, 6) .. "/" .. d.day:sub(7, 8)
  local separator = string.rep("─", 10)
  local key_rate = enough and string.format("%.2f", d.average_keys * 1000 / d.average_ms)
      or "-"
  local phrases = d.characters > 0 and 100 - single or 0
  return table.concat({
    "⍣ 今日统计 · " .. date,
    separator,
    row("均速", left[1], "峰值 " .. tostring(peak or "-")),
    row("码长", left[3], "击键 " .. key_rate),
    row("单字", left[2], "词组 " .. phrases .. "%"),
    "今日 " .. string.format("%.0f", d.characters) .. " 字",
    "生涯 " .. string.format("%.0f", d.lifetime) .. " 字",
    separator,
    "⍣ " .. schema .. " · " .. client,
  }, line_ending or "\n")
end

local function publish(env)
  local newline = env.line_ending or "\n"
  local text = M.format(snapshot(env.pool), env.schema_name, env.client, newline)
  if env.pool.read_error then
    text = text .. newline .. "统计存档异常：本次数据暂不覆盖原文件"
  end
  if env.pool.failed_at then
    text = text .. newline .. "统计尚未保存：等待下次操作重试"
  end
  -- 删除报告末尾的普通空格、换行和已知 Unicode 空白，不加占位空格，避免复制上屏后多出字符。
  text = text:gsub("%s+$", "")
  while true do
    local cleaned = text:gsub(" $", ""):gsub(" $", ""):gsub(" $", ""):gsub("　$", ""):gsub("%s+$", "")
    if cleaned == text then break end
    text = cleaned
  end
  env.engine.context:set_property(REPORT, text)
end

local function cancel(env)
  -- 取消输入时，只结算此前已上屏的纯中文。
  -- 这次未上屏内容的按键、耗时和临时速度样本都丢弃。
  env.pending, env.event = nil, nil
  end_samples(env)
end

local function on_commit(env, context)
  local now = clock()
  roll_day(env, today())
  local pending = env.pending
  local event = env.event
  local input = context.input or ""
  -- 顶功先上屏旧词，再把刚按的键写进新输入。因此这个键算下一次输入，不算旧词的击键。
  local carry = event and event.encoding and input == event.before and not event.observed
  if carry and pending then pending.keys = math.max(0, pending.keys - 1) end
  local character_count = M.chinese_count(context:get_commit_text())
  -- 按 A 的第二键时，当前候选可能还是入口单字；鼠标选短语又不会产生选字按键。
  -- 所以提交时再检查实际候选，排除工具和快捷短语，不能只看上一按键时的候选。
  local candidate = context:get_selected_candidate()
  local source = candidate and meta.source(candidate)
  if source and (source.type == "custom_phrase" or source.type == "number"
      or source.type == "datetime" or source.type == "statistics"
      or source.type == "emoji_only") then character_count = 0 end
  if pending and pending.keys > 0 and character_count > 0 then
    touch(pending, now)
    local totals = env.pool.data
    totals.characters = totals.characters + character_count
    totals.lifetime = totals.lifetime + character_count
    totals.commits = totals.commits + 1
    totals.keys = totals.keys + pending.keys
    if character_count == 1 then totals.single = totals.single + 1 end
    local plausible_speed = character_count <= RULE.max_speed_chars
        and character_count <= math.max(4, pending.keys * 2)
    if plausible_speed then
      pending.average.chars = pending.average.chars + character_count
      pending.average.keys = pending.average.keys + pending.keys
      pending.average.commit = now
      pending.peak.chars = pending.peak.chars + character_count
      pending.peak.commit = now
      if now - pending.peak.start >= (env.rule or RULE).peak_min then
        settle(pending.delta, pending.peak, "peak", env.rule)
        pending.peak = {}
      end
      merge(totals, pending.delta)
      env.average, env.peak = pending.average, pending.peak
    else
      end_samples(env)
    end
    env.pool.dirty = true
    env.pool.unsaved = env.pool.unsaved + character_count
  else
    end_samples(env)
  end
  env.pending, env.event = nil, nil
  if carry then
    env.pending = new_trial(env)
    env.pending.keys = 1
    env.pending.carry = true
    touch(env.pending, now)
  end
  save(env, now, false)
end

function M.init(env)
  local config = env.engine.schema.config
  local context = env.engine.context
  env.rule = copy(RULE)
  env.rule.save_ms = math.max(1,
      config:get_int("input_stats/save_seconds") or 60) * 1000
  env.rule.save_chars = math.max(1,
      config:get_int("input_stats/save_characters") or 200)
  env.rule.peak_min = math.max(1,
      config:get_int("input_stats/peak_min_seconds") or 15) * 1000
  env.entry_a = state.entry_text(config, "a")
  env.entry_o = state.entry_text(config, "o")
  env.enabled = config:get_bool("input_stats/enabled") ~= false
  if not env.enabled then
    context:set_property(REPORT, "输入统计已关闭")
    return
  end

  local path = store.resolve(config:get_string("input_stats/file")
      or "white_replace/whitkey_otj_stats.txt")
  local pool = pools[path]
  if not pool then
    local text, err = store.read_snapshot(path, 4096)
    local data
    if text then
      local parse_error
      data, parse_error = M.decode(text)
      err = err or parse_error
    end
    pool = {
      path=path,
      data=data or blank(today()),
      read_error=err,
      users={},
      saved_at=clock(),
      unsaved=0,
    }
    pools[path] = pool
    if err then
      core.report(nil, "统计存档读取失败，禁止覆盖", err)
    end
  end

  env.pool = pool
  env.average, env.peak = {}, {}
  pool.users[env] = true
  env.event_buffer = {}
  env.schema_name = env.engine.schema.schema_name or "纯白键道"
  local override = config:get_string("input_stats/client_name")
  local name = rime_api and rime_api.get_distribution_code_name
      and rime_api.get_distribution_code_name() or ""
  env.client = override and override ~= "" and override or M.client_name(name)
  -- Windows 报告默认用 CRLF 换行，其他平台默认用 LF。统计存档本身仍固定使用 LF。
  -- 这里只改报告上屏的换行，不在行尾加占位字符。
  local ending = config:get_string("input_stats/line_ending") or "auto"
  local windows = name:lower() == "weasel" or package.config:sub(1, 1) == "\\"
  local endings = {lf="\n", crlf="\r\n"}
  env.line_ending = endings[ending] or (windows and "\r\n" or "\n")
  env.prefix = config:get_string("lua/input") or "o"
  env.phrase_prefix = config:get_string("custom_phrase_mode/prefix") or "a"
  env.alphabet = core.string_to_set(config:get_string("speller/alphabet")
      or "abcdefghijklmnopqrstuvwxyz`")
  env.connections = {
    context.commit_notifier:connect(function(ctx) on_commit(env, ctx) end),
    context.update_notifier:connect(function(ctx)
      local input = ctx.input or ""
      if env.event and input ~= env.event.before then env.event.observed = true end
      if env.pending and env.pending.carry and input ~= "" then env.pending.carry = nil end
      if input == "" and env.pending and not env.pending.carry
          and not state.is(ctx, state.CREATED_WORD) then
        cancel(env)
      end
    end),
  }
  roll_day(env, today())
  publish(env)
end

function M.func(key, env)
  if not env.enabled or not key or key:release() then return core.kNoop end
  if key["repeat"] == true then return core.kNoop end
  local context = env.engine.context
  env.event = nil
  if key:ctrl() or key:alt() or key:super() then return core.kNoop end
  local code = key.keycode
  if code >= 0xffe1 and code <= 0xffee then return core.kNoop end
  if code == 0xff1b then
    cancel(env)
    return core.kNoop
  end
  if context:get_option("ascii_mode") then
    cancel(env)
    return core.kNoop
  end
  local now = clock()
  local input = context.input or ""
  if input == "" and env.pending and not state.is(context, state.CREATED_WORD) then
    cancel(env)
  end
  local character = code >= 32 and code < 127 and string.char(code) or ""

  -- 从首键起识别 A 快捷短语和 O 工具，整次输入不统计。即使它们上屏的是纯汉字，也不计入字数或速度。
  local phrase_prefix = env.phrase_prefix
  local phrase_command = phrase_prefix and phrase_prefix ~= ""
      and (input:sub(1, #phrase_prefix) == phrase_prefix
        or (input == "" and character == phrase_prefix))
  local tool_command = input:sub(1, #env.prefix) == env.prefix
      or (input == "" and character == env.prefix)

  local starting_entry = input == "" and (
      (character == "a" and env.entry_a ~= "")
      or (character == "o" and env.entry_o ~= ""))
  local selecting_entry = false
  -- 只有 A/O 命令需要检查是否选了入口单字，普通中文按键不提前读取当前候选。
  if phrase_command or tool_command then
    local candidate = context:get_selected_candidate()
    local source = candidate and meta.source(candidate)
    local candidate_text = candidate and candidate.text or ""
    selecting_entry = candidate and (
        source.type == "entry_word"
        or (input == "a" and env.entry_a ~= "" and candidate_text == env.entry_a)
        or (input == "o" and env.entry_o ~= "" and candidate_text == env.entry_o))
  end

  -- 部分客户端在数字进入 selector 或 Lua 快捷提交前，还拿不到 entry_word 身份。
  -- 所以 A 的空格和数字、O 的空格，还要结合入口与按键识别快捷单字。
  local selecting_a_entry = input == "a" and env.entry_a ~= ""
      and (core.is_space(key) or character:match("%d"))
  local selecting_o_entry = input == "o" and env.entry_o ~= ""
      and core.is_space(key)
  selecting_entry = selecting_entry or selecting_a_entry or selecting_o_entry

  if not starting_entry and not selecting_entry and (phrase_command or tool_command) then
    cancel(env)
    local command = input .. character
    if input == env.prefix .. "tj" or command == env.prefix .. "tj" then
      roll_day(env, today())
      publish(env)
    end
    save(env, now, false)
    return core.kNoop
  end

  local editing = input ~= "" or state.is(context, state.CREATED_WORD)
  if not editing and not env.alphabet[character:lower()] then return core.kNoop end
  if (code == 0xff08 or code == 0xffff) and input == "" then
    return core.kNoop
  end
  if not env.pending then env.pending = new_trial(env) end
  local pending = env.pending
  pending.keys = pending.keys + 1
  touch(pending, now)
  local event = env.event_buffer
  event.before = input
  event.encoding = env.alphabet[character] == true
  event.observed = false
  env.event = event
  return core.kNoop
end

function M.fini(env)
  if not env.pool then return end
  for _, connection in ipairs(env.connections or {}) do connection:disconnect() end
  cancel(env)
  save(env, clock(), true)
  local pool = env.pool
  pool.users[env] = nil
  if not next(pool.users) then pools[pool.path] = nil end
  env.pool, env.connections = nil, nil
end

return M
