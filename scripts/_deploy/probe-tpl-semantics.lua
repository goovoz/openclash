-- 模板引擎语义实测：确认 <%- %> 是赋值还是注释
package.path = "/usr/lib/lua/?.lua;" .. package.path
local tpl = require "luci.template"

local function try(name, t)
  local ok, res = pcall(tpl.render_string, t)
  print(string.format("%-40s ok=%s  out=%q", name, tostring(ok), tostring(res)))
end

-- 1) 纯赋值 <% section = "X" %>
try("<% assign %>", 'A<% section = "HELLO" %>B[<%= section %>]')

-- 2) <%- assign -%>（tsection.htm 用的写法）
try("<%- assign -%>", 'A<%- section = "HELLO" -%>B[<%= section %>]')

-- 3) <%- 注释 -%> 是否被吞掉
try("<%- comment -%>", 'A<%- section = "HELLO" -%>B')

-- 4) 标准注释 <%# %>
try("<%# comment %>", 'A<%# section = "HELLO" %>B')

-- 5) 赋值 + trim
try("<%- assign trim -%>", 'A<%- section = "HELLO" -%>B[<%= section %>]')