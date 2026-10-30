-- 输入 a＋编码后，在这里查询 A 快捷短语并生成候选。
local store = require "whitkey.data_store"
local M = {}
-- 候选按文件中的 rank 排列，不把这些短语写进主静态词库。
function M.translate(input, segment, env)
  if type(input) ~= "string" or not input:match("^[a-z]+$") then return end
  if not env.shortcuts then
    env.shortcuts, env.shortcuts_path = store.acquire_shortcuts(env.shortcuts_file)
  end
  local matches = store.shortcut_lookup(env.shortcuts, input)
  if not matches then return end
  for index, item in ipairs(matches) do
    local candidate = Candidate("custom_phrase", segment.start, segment._end,
        item.phrase, "")
    candidate.quality = env.shortcut_quality - item.rank * 1000 - index
    yield(candidate)
  end
end


function M.init(env, config)
  config = config or env.engine.schema.config
  env.shortcut_quality = config:get_int("custom_phrase/initial_quality") or 1000000
  env.shortcuts_file = config:get_string("custom_phrase/store_file")
      or "white_replace/A_custom_phrases.txt"
end
function M.fini(env)
  if env.shortcuts then store.release_shortcuts(env.shortcuts_path) end
  env.shortcuts, env.shortcuts_path, env.shortcuts_file = nil, nil, nil
end
return M
