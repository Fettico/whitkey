-- 各模块用到的编码、字符和路径工具放在这里。反查词典也在这里加载，多个模块共用一份。

local M = {
  -- processor 返回 1：这个按键已经处理。返回 2：让后面的组件接着处理。
  kRejected = 0,
  kAccepted = 1,
  kNoop = 2,
  -- 声码键和形码键统一写在这里，其他 Lua 共用这两组定义。
  sound_keys = "bpmfdtnlgkhjqxzcsrywe",
  shape_keys = "viuoa",
}

local sound_set, shape_set = {}, {}
for i = 1, #M.sound_keys do sound_set[M.sound_keys:sub(i, i)] = true end
for i = 1, #M.shape_keys do shape_set[M.shape_keys:sub(i, i)] = true end

local shifted_punctuation = {
  ["1"]="!", ["2"]="@", ["3"]="#", ["4"]="$", ["5"]="%",
  ["6"]="^", ["7"]="&", ["8"]="*", ["9"]="(", ["0"]=")",
  ["-"]="_", ["="]="+", ["["]="{", ["]"]="}", ["\\"]="|",
  [";"]=":", ["'"]="\"", [","]="<", ["."]=">", ["/"]="?", ["`"]="~",
}

-- 电脑可能发送“基础键＋Shift”，手机可能直接发送符号。这里把两种按法还原成同一个 ASCII 符号。
-- 这里只处理 Shift 标点，字母大小写由当前输入模式处理。
function M.ascii_key(key)
  local code = key.keycode
  if code < 0x21 or code > 0x7e then return nil end
  local char = string.char(code)
  return key:shift() and shifted_punctuation[char] or char
end

-- 同一个词典只打开一份反查句柄，并记录有几个模块在用。打开失败时记下重试次数，后续查询可以再次尝试。
local reverse_cache = {}
local reverse_methods = {}
local reverse_mt = {__index=reverse_methods}

-- 英文字母按键道映射取码，A/I/O/U/V 换成声码键，其余字母使用自己的小写。
-- O 和 V 都对应 l，因此选择时会同时列出这两个字母。这样不会用形码键作为字母的首码。
local default_letter_overrides = { A="s", I="k", O="l", U="j", V="l" }

-- 先建立“字母对应哪个键”和“这个键对应哪些字母”两张表。
-- 后一张表先保留大写字母的顺序，U 造词再按这个顺序追加小写字母。
function M.build_letter_maps(config)
  local by_letter, by_code = {}, {}
  for byte = string.byte("A"), string.byte("Z") do
    local letter = string.char(byte)
    local fallback = default_letter_overrides[letter] or letter:lower()
    local configured = config and config:get_string("mixed_word/letter_map/" .. letter)
    local code = M.clean_code(configured or fallback):sub(1, 1)
    if code == "" then code = fallback end
    by_letter[letter] = code
    by_code[code] = by_code[code] or {}
    by_code[code][#by_code[code] + 1] = letter
  end
  -- 一个键对应多个字母时，先放换过键位的字母，再放原来就在这个键上的字母。
  -- 所以 vs 依次显示 A、S，vk 显示 I、K，vj 显示 U、J，vl 显示 O、V、L。
  for _, letters in pairs(by_code) do
    table.sort(letters, function(a, b)
      local a_special = by_letter[a] ~= a:lower()
      local b_special = by_letter[b] ~= b:lower()
      if a_special ~= b_special then return a_special end
      return a < b
    end)
  end
  return by_letter, by_code
end

function M.ascii_letter(value)
  if type(value) ~= "string" or not value:match("^[A-Za-z]$") then return nil end
  return value:upper()
end

-- 第一次加载 created 词表时读取 Custom 的符号设置，相关模块共用这份设置。
-- key 表示按哪个键，text 表示留下哪个符号，code 表示如何取码。code 留空时，取码跳过这个符号。
function M.read_created_symbols(config)
  local rules = {keys={}, codes={}, ignored={}}
  local rows = config:get_list("created_word/symbols")
  if not rows and not config:is_null("created_word/symbols") then
    M.report(nil, "自造词符号配置无效", "created_word/symbols 必须是列表")
  end
  local alphabet = config:get_string("speller/alphabet") or "abcdefghijklmnopqrstuvwxyz`"
  for index = 0, (rows and rows.size or 0) - 1 do
    local path = "created_word/symbols/@" .. index .. "/"
    local key = config:get_string(path .. "key") or ""
    local text = config:get_string(path .. "text") or ""
    local code = config:get_string(path .. "code")
    if code then code = code:lower() end
    local valid_key = key:match("^[%p]$") and key ~= "-" and key ~= "="
        and not alphabet:find(key, 1, true)
    local valid_text = M.valid_text(text) and utf8.len(text) == 1
        and not text:find("[%w%s%c]") and not M.is_han_codepoint(utf8.codepoint(text))
    local valid_code = code ~= nil and (code == "" or M.is_sound_code(code, #code))
    local conflicting = rules.keys[key] or (rules.codes[text] ~= nil and rules.codes[text] ~= code)
    if valid_key and valid_text and valid_code and not conflicting then
      rules.keys[key] = text
      rules.codes[text] = code
      if code == "" then rules.ignored[text] = "" end
    else
      M.report(nil, "自造词符号配置无效", "第 " .. (index + 1)
          .. " 项填写不正确。key 要填未占用的半角标点，text 要填一个符号，code 要留空或填声码。"
          .. "- 和 = 留给翻页。同一个 key 不能重复，同一个 text 不能配置不同编码。")
    end
  end
  return rules
end

-- 判断 created 的取码字数时，先去掉当前设置中 code 留空的符号。有编码的符号仍算一个字符。
-- 这里只为候选分类和形码排序准备文字，不改正文、统计字数，也不重算已保存词的正式编码。
function M.created_code_text(text, symbols)
  for character in pairs(symbols.ignored) do
    if text:find(character, 1, true) then return (text:gsub(utf8.charpattern, symbols.ignored)) end
  end
  return text
end

-- 写 TXT 前先清理词语里的换行和 Tab，避免一个词被拆成多行或多列。
function M.clean_text(value)
  if type(value) ~= "string" then return "" end
  if utf8.len(value) == nil then return "" end
  return (value:gsub("[\r\n\t]", ""))
end

function M.valid_text(value)
  return type(value) == "string" and value ~= "" and utf8.len(value) ~= nil
end

-- 候选分类和统计使用同一组 Unicode 汉字范围。部首区也算汉字，因为部首会出现在两分和单字候选中。
function M.is_han_codepoint(point)
  return (point >= 0x3400 and point <= 0x4DBF)
      or (point >= 0x4E00 and point <= 0x9FFF)
      or (point >= 0xF900 and point <= 0xFAFF)
      or (point >= 0x20000 and point <= 0x2A6DF)
      or (point >= 0x2A700 and point <= 0x2B73F)
      or (point >= 0x2B740 and point <= 0x2B81F)
      or (point >= 0x2B820 and point <= 0x2CEAF)
      or (point >= 0x2CEB0 and point <= 0x2EBEF)
      or (point >= 0x2EBF0 and point <= 0x2EE5F)
      or (point >= 0x2F800 and point <= 0x2FA1F)
      or (point >= 0x30000 and point <= 0x3134F)
      or (point >= 0x31350 and point <= 0x323AF)
      or (point >= 0x2E80 and point <= 0x2EFF)
      or (point >= 0x2F00 and point <= 0x2FDF)
end

-- 整段都是汉字时返回字数。只要混入英文、数字、标点或无效 UTF-8，就返回 0。
function M.han_count(text)
  if not M.valid_text(text) then return 0 end
  local count = 0
  for _, point in utf8.codes(text) do
    if not M.is_han_codepoint(point) then return 0 end
    count = count + 1
  end
  return count
end

-- 先把编码改成小写，再去掉不属于键道的字符。调用方明确允许反引号时，才保留派生码中的反引号。
function M.clean_code(value, allow_backtick)
  if type(value) ~= "string" then return "" end
  local pattern = allow_backtick and "[^a-z;`]" or "[^a-z;]"
  return (value:lower():gsub(pattern, ""))
end

function M.path_separator()
  return (package.config or "/"):sub(1, 1) == "\\" and "\\" or "/"
end

function M.join_path(directory, filename)
  if not directory or directory == "" then return filename end
  local last = directory:sub(-1)
  if last == "/" or last == "\\" then return directory .. filename end
  return directory .. M.path_separator() .. filename
end

-- 通过 rime_api 取得用户目录。小狼毫和元书都从这个目录读写方案文件。
function M.user_path(filename)
  return M.join_path(rime_api.get_user_data_dir(), filename)
end

function M.key_repr(key)
  return key and key:repr() or ""
end

-- 先看 keycode，再看按键名称，判断它是不是空格。
function M.is_space(key)
  return key and (key.keycode == 0x20 or M.key_repr(key) == "space")
end

-- 主键盘 Enter、小键盘 Enter、ASCII 回车和带 Lock 标记的回车，都按回车识别。
function M.is_return(key)
  if not key then return false end
  if key.keycode == 0x0d or key.keycode == 0xff0d or key.keycode == 0xff8d then return true end
  local repr = M.key_repr(key)
  return repr == "Return" or repr == "KP_Enter"
      or repr == "Lock+Return" or repr == "Lock+KP_Enter"
end

-- 把字符串里的每个字符记进集合。例如 viuoa 会得到 v、i、u、o、a 五项，后续可以直接查某个键是否在其中。
function M.string_to_set(value)
  local result = {}
  if type(value) ~= "string" then return result end
  for i = 1, #value do result[value:sub(i, i)] = true end
  return result
end

function M.is_shape_key(value)
  return type(value) == "string" and #value == 1 and shape_set[value] == true
end

-- 检查编码是不是全由声码键组成。传入 length 时，还要求长度与这个数字相同。
function M.is_sound_code(value, length)
  if type(value) ~= "string" or value == "" then return false end
  if length and #value ~= length then return false end
  for i = 1, #value do
    if not sound_set[value:sub(i, i)] then return false end
  end
  return true
end

-- 检查编码是不是全由形码键组成。调用方还可以指定最短和最长长度。
function M.is_shape_code(value, min_length, max_length)
  if type(value) ~= "string" then return false end
  min_length = min_length or 1
  max_length = max_length or math.huge
  if #value < min_length or #value > max_length then return false end
  for i = 1, #value do
    if not shape_set[value:sub(i, i)] then return false end
  end
  return true
end

-- 先读开头的声码，再读后面的形码，只有这个顺序才算有效。
-- 这样才能统一限制形码位数，而不是把前四位一律当成声码。
function M.sound_shape_parts(value)
  if type(value) ~= "string" then return nil end
  local sound = value:match("^[" .. M.sound_keys .. "]+")
  if not sound or #sound > 4 then return nil end
  local shape = value:sub(#sound + 1)
  if shape ~= "" and not M.is_shape_code(shape) then return nil end
  return sound, shape
end

-- 反引号表示省略原来的码位，只接受 algebra 派生的“两声码位＋最多六个形码位”。前两位尚未输完时仍可继续输入。
-- 四声词码或命令里的反引号不算形码，避免把其他输入误认成省略码。
function M.omission_parts(value)
  if type(value) ~= "string" or not value:find("`", 1, true) or #value > 8 then return nil end
  local sound, shape = value:sub(1, 2), value:sub(3)
  for i = 1, #sound do
    local char = sound:sub(i, i)
    if char ~= "`" and not M.is_sound_code(char, 1) then return nil end
  end
  for i = 1, #shape do
    local char = shape:sub(i, i)
    if char ~= "`" and not M.is_shape_key(char) then return nil end
  end
  return sound, shape
end

-- 检查“指定数量的声码＋若干形码”是否符合要求。多个模块都调用这里，不各写一套匹配规则。
function M.matches_sound_shape(value, sound_length, min_shape, max_shape)
  if type(value) ~= "string" or sound_length < 1 then return false end
  min_shape, max_shape = min_shape or 0, max_shape or math.huge
  if #value < sound_length + min_shape or #value > sound_length + max_shape then return false end
  local sound, shape = value:sub(1, sound_length), value:sub(sound_length + 1)
  if not M.is_sound_code(sound, sound_length) then return false end
  if shape == "" then return min_shape == 0 end
  return M.is_shape_code(shape, min_shape, max_shape)
end

-- 按 core.shape_keys 的顺序列出形码，所以提示顺序固定为 v/i/u/o/a。
function M.shape_list()
  local result = {}
  for i = 1, #M.shape_keys do result[#result + 1] = M.shape_keys:sub(i, i) end
  return result
end

-- 用 Lua 自带的 utf8 库拆字。外部文本在加载时先检查 UTF-8，避免用坏编码继续拆字。
function M.split_chars(text)
  local result = {}
  if not M.valid_text(text) then return result end
  for _, point in utf8.codes(text) do
    result[#result + 1] = utf8.char(point)
  end
  return result
end

-- 返回 Unicode 字符数，不是 UTF-8 字节数。
function M.utf8_length(text)
  if type(text) ~= "string" or text == "" then return 0 end
  return utf8.len(text) or 0 -- 坏 UTF-8 没有字符数，统一返回 0。
end

function M.first_character(text)
  return M.character_at(text, 1)
end

-- 按从 1 开始的字符序号取一个 Unicode 字符。
function M.character_at(text, index)
  if type(text) ~= "string" or text == "" or index < 1 then return nil end
  local start_pos = utf8.offset(text, index)
  if not start_pos then return nil end
  local next_pos = utf8.offset(text, index + 1)
  return next_pos and text:sub(start_pos, next_pos - 1) or text:sub(start_pos)
end

local function open_reverse(item)
  if item.value then return item.value end
  -- 反查加载暂时失败后间隔重试。失败后至少等五秒再试，成功后就不再读取时钟，避免普通查询反复检查重试时间。
  local now = os.time()
  if now < item.retry_at then return nil end
  item.retry_at = now + 5
  local ok, value = pcall(ReverseLookup, item.dictionary)
  if ok and value then item.value = value end
  return item.value
end

function reverse_methods:lookup(character)
  local value = open_reverse(self)
  if not value then return nil end
  local cached = self.codes[character]
  if cached ~= nil then return cached end
  local result = value:lookup(character)
  if type(result) ~= "string" then return nil end
  -- 最多缓存 256 个反查结果。正常查询没有编码时，空字符串也可以缓存；查询失败时不缓存。
  local slot = self.cursor % 256 + 1
  local expired = self.slots[slot]
  if expired then self.codes[expired] = nil end
  self.slots[slot], self.cursor = character, slot
  self.codes[character] = result
  return result
end

function M.reverse_ready(reverse)
  return reverse ~= nil and open_reverse(reverse) ~= nil
end

-- 同一个词典的反查句柄和重试时间由多个模块共用，避免各模块反复打开同一词典。
function M.acquire_reverse(dictionary)
  if type(dictionary) ~= "string" or dictionary == "" then return nil end
  local item = reverse_cache[dictionary]
  if not item then
    item = setmetatable({
      dictionary=dictionary, refs=0, retry_at=0,
      codes={}, slots={}, cursor=0,
    }, reverse_mt)
    reverse_cache[dictionary] = item
    open_reverse(item)
  end
  item.refs = item.refs + 1
  return item
end

-- 模块退出时减少一个使用者。等最后一个使用者也退出，再释放共享缓存。
function M.release_reverse(dictionary)
  local item = dictionary and reverse_cache[dictionary]
  if not item then return end
  item.refs = item.refs - 1
  if item.refs <= 0 then reverse_cache[dictionary] = nil end
end

-- 同时返回编码和查询是否成功。正常查不到编码时返回空串，仍可缓存。
-- 查询失败时也返回空串，但第二个值是 false，调用方不能把它当成正常空结果缓存。
local function reverse_lookup(reverse, character) return reverse:lookup(character) end
function M.reverse_codes(reverse, character)
  if not reverse or not character then return "", false end
  local ok, value = pcall(reverse_lookup, reverse, character)
  if not ok or type(value) ~= "string" then return "", false end
  return value, true
end

-- 从汉字编码中取两位音码，跳过一简和形码。
-- 不同读音可能首字母相同，不能只看首字母就合并，否则会丢失完整音码。
function M.sound_codes(reverse, character)
  local codes, seen = {}, {}
  for code in M.reverse_codes(reverse, character):gmatch("[a-z]+") do
    local sound, shape = code:sub(1, 2), code:sub(3)
    if M.is_sound_code(sound, 2) and (shape == "" or M.is_shape_code(shape, 1))
        and not seen[sound] then
      seen[sound] = true
      codes[#codes + 1] = sound
    end
  end
  return codes
end

function M.word_base_length(text)
  local count = M.utf8_length(text)
  if count == 2 then return 4 end
  if count == 3 then return 3 end
  if count >= 4 then return 4 end
  return nil
end

-- 只认当前词码后面追加的辅助形码。其他音码或 630 编码不算这条词码的短码。
function M.word_shape_suffix(text, code)
  local base = M.word_base_length(text)
  if not base or not M.is_sound_code(code:sub(1, base), base) then return nil end
  local suffix = code:sub(base + 1)
  if not M.is_shape_code(suffix, 1) then return nil end
  return base, suffix
end

-- 把错误写入当前会话的提示属性，并记录日志。
function M.report(context, message, detail)
  local text = "纯白键道：" .. message
  if context then context:set_property("whitkey_last_error", text) end
  if log and log.error then log.error(text .. (detail and ("：" .. tostring(detail)) or "")) end
  if rime_api and rime_api.notify then pcall(rime_api.notify, "whitkey_error", text) end
end
-- 客户端没有通知接口时，在下一次普通候选的旁注里显示一次错误。
function M.decorate(candidate, context)
  local message = context:get_property("whitkey_last_error") or ""
  if message == "" then return end
  candidate.comment = message .. (candidate.comment ~= "" and (" · " .. candidate.comment) or "")
  context:set_property("whitkey_last_error", "")
end

return M
