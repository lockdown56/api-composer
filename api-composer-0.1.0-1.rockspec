package = "api-composer" 
version = "0.1.0-1"

local pluginName = package:match("^(.+)$")  

supported_platforms = {"linux", "macosx"}
source = {
  url = "http://github.com/Kong/kong-plugin.git",
  tag = "0.1.0"
}

description = {
  summary = "",
  homepage = "",
  license = "Apache 2.0"
}

dependencies = {
}

build = {
  type = "builtin",
  modules = {
    ["kong.plugins."..pluginName..".handler"] = "kong/plugins/"..pluginName.."/handler.lua",
    ["kong.plugins."..pluginName..".schema"] = "kong/plugins/"..pluginName.."/schema.lua",

    ["inspur.jsonpath"] = "lib/lua-inspur-jsonpath/jsonpath.lua",

    ["resty.socket"] = "lib/lua-resty-socket/lib/resty/socket.lua",

    ["resty.requests"] = "lib/lua-resty-requests/lib/resty/requests.lua",
    ["resty.requests.adapter"] = "lib/lua-resty-requests/lib/resty/requests/adapter.lua",
    ["resty.requests.request"] = "lib/lua-resty-requests/lib/resty/requests/request.lua",
    ["resty.requests.response"] = "lib/lua-resty-requests/lib/resty/requests/response.lua",
    ["resty.requests.session"] = "lib/lua-resty-requests/lib/resty/requests/session.lua",
    ["resty.requests.util"] = "lib/lua-resty-requests/lib/resty/requests/util.lua",
  }
}
