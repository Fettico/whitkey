-- 加载个人 TXT 时，从头到尾执行“设置”和“删除”，得出当前有效词表。查询只使用这份内存结果，不在每次按键时重新读文件。
-- 默认失效记录达到 100 条后，下次实际加载这张表时整理。map 每码一词，list 同码多词且新词在前，set 同码多项但不记录候选顺序。
local M = {}
local LIMIT = 16 * 1024 * 1024
local COMPACT_STALE = 100
-- 每种个人记录有自己的中文表头，整理后仍写回对应说明，不用一个通用表头替换所有文件。
local function header(lines)
  return table.concat(lines, '\n') .. '\n'
end

local HEADERS = {
  map = header {
    '# 纯白键道每码一词记录',
    '# 每行写一次设置或删除，读取时从上到下执行。',
    '# 设置<Tab>编码<Tab>词语',
    '# 同码再设置别的词，就用新词替换旧词。',
    '# 删除<Tab>编码',
    '# <Tab>表示制表符。',
  },
  picked = header {
    '# 纯白键道已确认普通自组词',
    '# 每行写一次设置或删除，读取时从上到下执行。',
    '# 同码可留多个词。新选过并确认的词放前面，再次确认已有词不改变位置。',
    '# 设置<Tab>编码<Tab>词语',
    '# 删除<Tab>编码<Tab>词语',
    '# <Tab>表示制表符。手工修改后重新加载方案。',
  },
  created = header {
    '# 纯白键道 U 自造词记录',
    '# 每行写一次设置或删除，读取时从上到下执行。',
    '# 取码时，每个汉字、每个英文字母、每位数字和每个有编码的符号各算一个位置。',
    '# code 留空的符号保留正文，但不占取码位置。两个位置各取最多两码。',
    '# 汉字取音码，英文字母取映射码，数字取自身读音的音码，符号取 Custom 指定码。',
    '# 三个位置各取首码。如果全是汉字，再补首字第一笔形码。',
    '# 四个及以上位置，取前三个和最后一个位置的首码。',
    '# 可以造中英混合词。正文保留字母大小写，取码使用键道字母映射。',
    '# 数字用 v 入口输入。例如 v2750，按空格选中 2750 后继续造词，v 不进入正文。',
    '# 数字音码：0零lg、1一yk、2二xj、3三sf、4四sk、5五wj、6六lq、7七qk、8八bs、9九jq。',
    '# 连续数字仍逐位取码。例如 2750块 的编码是 xqwk，V我50 的编码是 lwwl。',
    '# 符号在 Custom 的 created_word/symbols 修改。key 写键盘上的半角键，text 写正文留下的符号。',
    '# code 留空时，取码跳过这个符号；填了编码，就按上面的整词规则取码。',
    '# 例如 A我：A 映射为 s，我取 wl，最终编码是 swl。',
    '# 三声码加首字形码保存的词，也可只输三声码查到。改符号设置不会重算已经保存的码。',
    '# 设置<Tab>编码<Tab>词语',
    '# 删除<Tab>编码<Tab>词语',
    '# <Tab>表示制表符。手工修改后重新加载方案。',
  },
  list = header {
    '# 纯白键道同码多词记录',
    '# 每行写一次设置或删除，读取时从上到下执行。',
    '# 设置<Tab>编码<Tab>词语',
    '# 删除<Tab>编码<Tab>词语',
    '# <Tab>表示制表符。',
  },
  hidden = header {
    '# 纯白键道隐藏记录',
    '# 每行写一次设置或删除，读取时从上到下执行。',
    '# 每条只隐藏这个编码下的这个词，其他编码不受影响。同码可以隐藏多个词。',
    '# 设置<Tab>编码<Tab>词语',
    '# 删除<Tab>编码<Tab>词语',
    '# <Tab>表示制表符。手工修改后重新加载方案。',
  },
  set = header {
    '# 纯白键道同码多项记录',
    '# 每行写一次设置或删除，读取时从上到下执行。',
    '# 设置<Tab>编码<Tab>词语',
    '# 删除<Tab>编码<Tab>词语',
    '# <Tab>表示制表符。',
  },
  pinned = header {
    '# 纯白键道钉选记录',
    '# 每行写一次设置或删除，读取时从上到下执行。',
    '# 这里只记录允许钉选的普通多字候选。',
    '# 每码只留一个钉选词。再钉同码同词就取消，钉其他词就替换原来的词。',
    '# 设置<Tab>编码<Tab>词语',
    '# 删除<Tab>编码',
    '# <Tab>表示制表符。手工修改后重新加载方案。',
  },
}

local function header_for(p)
  if p.record_type and HEADERS[p.record_type] then return HEADERS[p.record_type] end
  return HEADERS[p.kind] or HEADERS.map
end

-- 同码只有一个词时，直接保存字符串，省去常驻的小表。出现第二个词才建表，删回一个词就收回小表。
-- by_code 没有词时是 nil。list 的多个词用有序数组，set 的多个词用集合；map 始终每码一词。
-- 这些存法只在本文件处理。外部读词用 words，查位置用 word_index，判断是否存在用 contains。
-- words 只供 list 读取：单词临时包装成数组，多词直接返回原数组。调用方不能修改返回值来保存词。
-- 增删走 change，失败恢复走 restore_word。改存法时，要一起核对 apply、load、compact 和恢复步骤。
function M.words(p, code)
  local value = p and p.by_code[code]
  if type(value) == 'string' then return {value} end
  return value
end

function M.word_index(p, code, word)
  local value = p and p.by_code[code]
  if type(value) == 'string' then return value == word and 1 or nil end
  for index, text in ipairs(value or {}) do
    if text == word then return index end
  end
end

function M.contains(p, code, word)
  local value = p and p.by_code[code]
  if type(value) == 'string' then return value == word end
  if p and p.kind == 'set' then return value ~= nil and value[word] == true end
  return M.word_index(p, code, word) ~= nil
end

local function apply(p, op, code, word)
  -- active 统计有效词数，不是编码数。同码增加第二个词，也要加一；重复设置不能重复计数。
  local old = p.by_code[code]
  if p.kind == 'map' then
    if op == '设置' then
      if not old then p.active = p.active + 1 end
      p.by_code[code] = word
    elseif old then
      p.by_code[code] = nil
      p.active = p.active - 1
    end
    return
  end

  if not old then
    if op == '设置' then
      p.by_code[code] = word
      p.active = p.active + 1
    end
  elseif type(old) == 'string' then
    if old == word then
      if op == '删除' then
        p.by_code[code] = nil
        p.active = p.active - 1
      end
    elseif op == '设置' then
      -- 添加第二个词时才建表。list 把新词放前面，set 不记录顺序。
      p.by_code[code] = p.kind == 'list' and {word, old} or {[old]=true, [word]=true}
      p.active = p.active + 1
    end
  elseif p.kind == 'set' then
    if op == '设置' and not old[word] then
      old[word] = true
      p.active = p.active + 1
    elseif op == '删除' and old[word] then
      old[word] = nil
      p.active = p.active - 1
      -- 走到这里时至少有两个词。删除后若只剩一个，直接存回这个词，不留下只有一项的集合。
      local remaining = next(old)
      if next(old, remaining) == nil then p.by_code[code] = remaining end
    end
  else
    local index = M.word_index(p, code, word)
    -- 已有词再次确认不换位置。删后重加才回到首位。
    if op == '设置' and not index then
      table.insert(old, 1, word)
      p.active = p.active + 1
    elseif op == '删除' and index then
      table.remove(old, index)
      p.active = p.active - 1
      -- 和集合一样，删回一个词就用字符串。最后一个词的删除由上面的字符串分支处理。
      if #old == 1 then p.by_code[code] = old[1] end
    end
  end
end

local function valid(p, code, word, deleting)
  local pattern = p.picked and '^[a-z]+$' or (p.kind == 'list' and '^[a-z;]+$' or '^[a-z;`]+$')
  if not code or not code:match(pattern) then return false end
  if deleting and p.kind == 'map' then return word == nil end
  if not word or word == '' or word:find('[\t\r\n]') then return false end
  if utf8.len(word) == nil then return false end
  if p.picked then
    local length = utf8.len(word)
    if not length or length < 2 then return false end
  end
  return true
end

function M.compact(p)
  local header = header_for(p)
  local bytes = #header
  local ok, err = p.backend.replace(p.path, function(f)
    local function write(code, word)
      local row = '设置\t' .. code .. '\t' .. word .. '\n'
      bytes = bytes + #row
      if bytes > LIMIT then return false, '个人词表超过大小上限' end
      return f:write(row)
    end

    local wrote, why = f:write(header)
    if not wrote then return false, why end
    for code, value in pairs(p.by_code) do
      -- 单个词要整词写一次。不能把字符串当数组遍历，也不能用 #value 统计词数。
      -- 内存存法不写进 TXT，磁盘上仍是一行“设置／删除”记录。
      if p.kind == 'map' or type(value) == 'string' then
        wrote, why = write(code, value)
        if not wrote then return false, why end
      elseif p.kind == 'list' then
        -- 加载时新记录会放到首位，所以整理写回时先写旧词，再写新词。这样下次读取后顺序与现在相同。
        for i = #value, 1, -1 do
          wrote, why = write(code, value[i])
          if not wrote then return false, why end
        end
      else
        for word in pairs(value) do
          wrote, why = write(code, word)
          if not wrote then return false, why end
        end
      end
    end
    return true
  end)
  if ok then
    p.bytes, p.records, p.newline = bytes, p.active, true
  end
  return ok, err
end

function M.load(path, kind, backend, record_type, compact_stale)
  local picked = record_type == 'picked'
  local p = {path=path, kind=kind, backend=backend, by_code={}, records=0,
    active=0, bytes=0, refs=0, picked=picked,
    record_type=record_type}
  local file, err = backend.open(path)
  if err then
    if file then file:close() end
    p.load_error = err
    return p
  end
  p.newline = true
  if not file then return p end
  local size, size_err = file:seek('end')
  if not size or size > LIMIT then
    file:close()
    p.load_error = size_err or '个人词表超过大小上限'
    return p
  end
  p.bytes = size
  if size > 0 then
    file:seek('set', size - 1)
    p.newline = file:read(1) == '\n'
  end
  local offset, seek_err = file:seek('set', 0)
  if not offset then
    file:close()
    p.load_error = seek_err
    return p
  end
  -- 加载 list 时先用 order 记顺序、live 定位有效词，避免每条历史记录都在同码数组里查找或移动。
  -- 这些表只在加载时使用。回放结束后生成查询索引，单词直接存字符串，多个词才建数组。
  local order, live
  if kind == 'list' then order, live = {}, {} end
  local function replay(op, code, word)
    if not order then
      apply(p, op, code, word)
      return
    end
    local words = live[code]
    local index = words and words[word]
    if op == '设置' and not index then
      if not words then
        words = {}
        live[code] = words
      end
      order[#order + 1] = word
      order[#order + 1] = code
      words[word] = #order - 1
      p.active = p.active + 1
    elseif op == '删除' and index then
      order[index], order[index + 1] = false, false
      words[word] = nil
      p.active = p.active - 1
      if not next(words) then live[code] = nil end
      -- 这里只压紧加载用的临时数组，不改磁盘文件。
      -- 删除留下的空位置至少 100 个，且数量不小于有效项时，才整理这个数组。
      local size = #order
      if size / 2 - p.active >= math.max(COMPACT_STALE, p.active) then
        local tail = 0
        for i = 1, size, 2 do
          local text, assigned = order[i], order[i + 1]
          if text then
            order[tail + 1], order[tail + 2] = text, assigned
            live[assigned][text] = tail + 1
            tail = tail + 2
          end
        end
        for i = tail + 1, size do order[i] = nil end
      end
    end
  end
  local first, consumed, line_number = true, 0, 0
  while true do
    local line, read_err = file:read('*l')
    if not line then
      if read_err then p.load_error = read_err end
      break
    end
    line_number = line_number + 1
    consumed = consumed + #line + 1
    if consumed > LIMIT + 1 then
      p.load_error = '个人词表超过大小上限'
      break
    end
    line = line:gsub('\r$', '')
    if first then
      line = line:gsub('^\239\187\191', '')
      first = false
    end
    if not line:match('^%s*#') and not line:match('^%s*$') then
      local op, code, word = line:match('^(设置)\t([^\t]+)\t([^\t]+)$')
      if not op then
        code, word = line:match('^删除\t([^\t]+)\t([^\t]+)$')
        if code then op = '删除' end
      end
      if not op then
        code = line:match('^删除\t([^\t]+)$')
        if code then op = '删除' end
      end
      -- 读取记录时只把编码转为小写。出现非法字符就报告错误并保留原文件，不替用户删字符。
      -- 否则一个写错的码可能被悄悄变成另一个有效码。
      code = code and code:lower()
      if not op or not valid(p, code, word, op == '删除') then
        local deletion = kind == 'map' and '删除<Tab>编码' or '删除<Tab>编码<Tab>词语'
        p.load_error = '个人词表格式错误：' .. path .. '，第 ' .. line_number
            .. ' 行。设置写成 设置<Tab>编码<Tab>词语，删除写成 ' .. deletion
            .. '。保留原文件，修正后重新加载方案。'
        break
      else
        replay(op, code, word)
        p.records = p.records + 1
      end
    end
  end
  local closed, close_err = file:close()
  if not closed then p.load_error = p.load_error or close_err end
  if order then
    -- 从后向前读取有效记录，使新词在前。这里和 apply 必须使用同一种存法，避免重新加载后结果变样。
    for i = #order - 1, 1, -2 do
      local word, code = order[i], order[i + 1]
      if word then
        local words = p.by_code[code]
        if not words then
          p.by_code[code] = word
        elseif type(words) == 'string' then
          p.by_code[code] = {words, word}
        else
          words[#words + 1] = word
        end
      end
    end
  end
  if p.load_error then return p end -- 坏文件已读出的有效记录还能查，但不再写入或整理。
  if p.records - p.active >= (compact_stale or COMPACT_STALE) then
    local ok, why = M.compact(p)
    if not ok then
      if backend.report then backend.report(why) end
    end
  end
  return p
end

-- 追加记录和紧急整理前，先检查文件是否被外部改动。这里只比较文件长度，同长度替换可能查不出来。
-- 所以手工改完 TXT，要退出并重新加载方案。
local function open_append(p)
  local ready, recovery_err = p.backend.ready(p.path)
  if not ready then return nil, recovery_err end
  local f, err = io.open(p.path, 'ab')
  if not f then return nil, err end
  local size = f:seek('end')
  if size ~= p.bytes then
    f:close()
    p.load_error = '词表已在外部改变，请重新加载方案'
    return nil, p.load_error
  end
  return f
end

function M.change(p, op, code, word)
  if p.load_error then return false, p.load_error end
  code = code and code:lower()
  if (op ~= '设置' and op ~= '删除') or not valid(p, code, word, op == '删除') then
    return false, '个人词条格式错误'
  end
  local row = op .. '\t' .. code .. (word and '\t' .. word or '') .. '\n'
  local prefix = (p.newline and '' or '\n') .. (p.bytes == 0 and header_for(p) or '')
  local f, err = open_append(p)
  if not f then return false, err end
  if p.bytes + #prefix + #row > LIMIT and p.records > p.active then
    local closed, close_err = f:close()
    if not closed then return false, close_err end
    local compacted, compact_err = M.compact(p)
    if not compacted then return false, compact_err end
    f, err = open_append(p)
    if not f then return false, err end
    prefix = ''
  end
  if p.bytes + #prefix + #row > LIMIT then
    f:close()
    return false, '有效词表达到大小上限，无法继续追加'
  end
  -- 文件已打开，Lua I/O 会用返回值报告写入或关闭失败，检查这些结果即可。
  -- 只有整条记录追加成功，才更新内存里的有效记录。
  local wrote, why = f:write(prefix .. row)
  local close_ok, close_err = f:close()
  if not wrote or not close_ok then
    p.load_error = '追加失败，请重新加载方案后检查词表'
    return false, why or close_err or p.load_error
  end
  p.bytes = p.bytes + #prefix + #row
  p.newline = true
  p.records = p.records + 1
  apply(p, op, code, word)
  -- 使用期间不会只因失效记录到达阈值就重写整表。文件达到 16 MB 容量上限时，才允许紧急整理。
  return true
end

-- created 与 picked 删除后，如果后续原生删除失败，就在这里恢复 TXT 记录及其内存索引。
-- 先放回原位置并整理文件。整理失败就撤回这次内存修改，再尝试追加设置；追加只能恢复到同码首位。
-- 返回 false 也可能表示“词已恢复，但位置变了”，具体看错误文字。调用方不能据此再次删除这个词。
function M.restore_word(item, word, code, index)
  local value = item.by_code[code]
  local words = type(value) == 'string' and {value} or value or {}
  for _, value in ipairs(words) do
    if value == word then return true end
  end
  index = math.max(1, math.min(index or 1, #words + 1))
  table.insert(words, index, word)
  item.by_code[code] = #words == 1 and words[1] or words
  item.active = item.active + 1
  local ok, err = M.compact(item)
  if ok then return true end
  -- 整理没成功，先恢复尝试前的词数和 nil／字符串／数组表示，再交给 change 写盘。
  -- 不先撤回的话，追加失败时内存就会多出一个并未保存成功的词。
  table.remove(words, index)
  item.active = item.active - 1
  if #words == 0 then item.by_code[code] = nil
  elseif #words == 1 then item.by_code[code] = words[1]
  else item.by_code[code] = words end
  local appended, append_err = M.change(item, "设置", code, word)
  if appended then
    return false, tostring(err) .. "；词语已恢复到同码首位"
  end
  return false, tostring(err) .. "；追加恢复也失败：" .. tostring(append_err)
end

return M
