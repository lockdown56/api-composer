local kong = kong
local ngx = ngx
local cjson = require "cjson.safe"
local jp = require "inspur.jsonpath"
local requests = require "resty.requests"
local lpeg = require "lpeg"

local new_tab = require "table.new"
local remove_tab = table.remove
local concat_tab = table.concat
local type = type
local tonumber = tonumber
local tostring = tostring
local string = string
local find = string.find

local ComposerHandler = {}

ComposerHandler.PRIORITY = 1000
ComposerHandler.VERSION = '0.1.0'


local function str_split(s, sep)
    sep = lpeg.P(sep)
    local elem = lpeg.C((1 - sep)^0)
    local p = lpeg.Ct(elem * (sep * elem)^0)
    return lpeg.match(p, s)
end


local function parsePathVar(uri_patt)
    local uri_patt_arr, err = str_split(uri_patt, "/")
    if err then
        kong.log.err("failed to split uri pattern, err: ", err, ", uri pattern: ", uri_patt)
        return err
    end

    local uri_arr
    uri_arr, err = str_split(kong.request.get_path(), "/")
    if err then
        kong.log.err("failed to split uri, err: ", err, ", uri: ", kong.request.get_path())
        return err
    end

    local path_vars = {}
    for i in ipairs(uri_patt_arr) do
        local m
        m, err = ngx.re.match(uri_patt_arr[i], "({)(.+)(})")
        if err then
            kong.log.err("failed to match uri pattern array, err: ", err)
            return nil, err
        end

        if m and m[2] then
            path_vars[m[2]] = uri_arr[i]
        end
    end

    return path_vars
end


local function parseRequest(uri_patt, ctx)
    local req = new_tab(0, 4)
    req.header = kong.request.get_headers()
    req.query = kong.request.get_query()
    req.body = kong.request.get_body()

    local path, err = parsePathVar(uri_patt)
    if err then
        return err
    end

    req.path = path

    ctx.req = req
end


local function get_value(schema, ctx)
    local from, _, err = ngx.re.find(schema.value, "\\$", "jo")
    if err then
        return nil, err
    end

    local value
    if from then
        local value_expr
        value_expr, err = jp.parse(schema.value)
        if err then
            return nil, err
        end

        -- 
        if 'header' == value_expr[3] then
            value_expr[4] = string.lower(value_expr[4])
        end

        local matched_values = jp.query(ctx, value_expr)
        local is_arr
        is_arr, _, err = ngx.re.find(schema.value, "[*]", "jo")
        if err then
            return nil, err
        end

        if not is_arr then
            value = matched_values[1]
        else
            value = matched_values
        end
    else
        value = schema.value
    end

    if not value then
        value = schema.default
    end

    -- default value
    local value_type = schema.type
    if value_type == "array" then
        if not value or (type(value) == "table" and #value == 0) then
            value = {}
            setmetatable(value, cjson.empty_array_mt)
        end
    elseif value_type == "object" then
        -- do nothing
    elseif value_type == "number" or value_type == "integer" then
        value = tonumber(value)
    elseif value_type == "string" then
        if (type(value) == "table") then
            value = cjson.encode(value)
        else
            value = value and tostring(value) or ""
        end
    elseif value_type == "boolean" then
        value = (value == true)
    end

    return value
end


local function get_body(body_schema, ctx)
    if not body_schema then
        return ""
    end

    if body_schema.value then
        local value, err = get_value(body_schema, ctx)
        if err then
            return nil, err
        end

        return value
    elseif body_schema.type == "object" then
        local body = {}
        for key, schema in pairs(body_schema.properties) do
            local res, err = get_body(schema, ctx)
            if err then
                return nil, err
            end
            body[key] = res
        end

        return body
    elseif body_schema.type == "array" then
        local res, err = get_body(body_schema.items, ctx)
        if err then
            return nil, err
        end

        return {res}
    end
end


local function get_step_inputs(inputs, ctx)
    local step_inputs = {
        query = {},
        path = {},
        header = {}
    }

    for pos, params in pairs(inputs) do
        if type(params) == 'table' and string.lower(pos) ~= "body" then
            for param_key, schema in pairs(params) do
                local expr = jp.parse(schema.value)
                local first = remove_tab(expr, 1)
                if first == '$' then
                    local from_step = remove_tab(expr, 1)
                    local data = ctx[from_step]
                    if nil == data then
                        return nil, "value expression err, can not get values"
                    end

                    local from_step_pos = expr[1]
                    if from_step_pos == 'header' then
                        expr[2] = string.lower(expr[2])
                    end

                    local value = jp.value(data, expr)
                    if nil == value then
                        value = schema.default
                    end

                    step_inputs[pos][param_key] = value
                else
                    step_inputs[pos][param_key] = schema.value
                end
            end
        end
    end

    -- body
    local input_body
    -- use object as default body type
    local raw_body_schema = inputs.body

    if raw_body_schema then
        local body_schema
        if not raw_body_schema.type then
            body_schema = {
                type = "object",
                properties = raw_body_schema
            }
        else
            body_schema = raw_body_schema
        end

        local err
        input_body, err = get_body(body_schema, ctx)
        if err then
            return nil, err
        end
    else
        input_body = ""
    end


    step_inputs.body = input_body

    return step_inputs
end


local function get_url(url, query, path_vars)
    -- replace path value if exist
    local new_url, _, err
    new_url, _, err = ngx.re.gsub(url, "{[^/]+}", function (m)
        local key
        key, _, err = ngx.re.gsub(m[0], '{|}', '')
        if err then
            return nil, err
        end
        return path_vars[key]
    end, "x")
    if err then
        return nil, err
    end

    if type(query) == 'table' then
        local url_tab = new_tab(10, 0)
        url_tab[1] = new_url

        local i = 2
        for k, v in pairs(query) do
            if 2 == i then
                url_tab[i] = '?'
            else
                url_tab[i] = '&'
            end

            url_tab[i+1] = k
            url_tab[i+2] = '='
            url_tab[i+3] = v

            i = i + 4
        end

        new_url = concat_tab(url_tab)
    end

    return new_url
end



local function get_response(step, ctx)
    -- status code
    local status_schema = {
        type = "number",
        value = step.status,
        default = 200
    }
    local status, err = get_value(status_schema, ctx)
    if err then
        return nil, err
    end

    -- header
    local header = {}
    if step.outputs.header then
        for header_key, schema in pairs(step.outputs.header) do
            local header_value
            header_value, err = get_value(schema, ctx)
            if err then
                return nil, err
            end

            header[header_key] = header_value
        end
    end

    -- body
    local body

    -- use object as default type if unspecified
    local raw_body_schema = step.outputs.body
    if raw_body_schema then
        local body_schema
        if not raw_body_schema.type then
            body_schema = {
                type = "object",
                properties = raw_body_schema
            }
        else
            body_schema = raw_body_schema
        end

        body, err = get_body(body_schema, ctx)
        if err then
            return nil, err
        end
    else
        body = ""
    end

    return {
        status = status,
        header = header,
        body = body
    }
end


local function send_request(step, step_inputs, ctx)
    local url, err = get_url(step.url, step_inputs.query, step_inputs.path)
    if err then
        return err
    end

    -- send request
    local req = {
        method = string.upper(step.method),
        url = url,
        headers = step_inputs.header,
        body = step_inputs.body,
        timeouts = {
            step.timeout or 3000,
            10000,
            30000
        }
    }

    local r
    r, err = requests.request(req)
    if r == nil then
        kong.log("failed to request from upstream, ", err)
        return err
    end

    local status_code = r.status_code
    local res_body = r:body()
    if status_code > 399 then
        kong.log("upstream error, status_code: ", status_code, ", msg: ", res_body)
        return "upstream error", status_code, res_body
    end

    local output_body

    -- parse body if body is json format -- start
    local headers = r.headers
    local content_type = string.lower(headers["content-type"] or "")
    local startIndex, _ = find(content_type, "application/json")
    if startIndex ~= nil and startIndex >= 1 then
        output_body, err = cjson.decode(res_body)
        if err then
            kong.log(step.name, " response format err: ", err)
            kong.response.exit(500, step.name .. " response format err, not json")
        end
    else
        output_body = res_body
    end
    ----------------------------------------- end

    local outputs = {
        status = status_code,
        header = r.headers,
        body = output_body
    }

    ctx[step.code] = outputs

    return nil
end


function ComposerHandler:access(conf)
    local ctx = new_tab(0, 10)

    local err = parseRequest(conf.uri, ctx)
    if err then
        kong.response.exit(400, "invalid request")
    end

    local composer_conf
    composer_conf, err = cjson.decode(conf.composer_conf)
    if err then
        kong.log("composer config err: ", err)
        kong.response.exit(500, "composer config err")
    end

    local steps = composer_conf.steps
    for i in ipairs(steps) do
        local step = steps[i]
        if step.type == 'http' then
            local step_inputs
            step_inputs, err = get_step_inputs(step.inputs, ctx)
            if err then
                kong.log("failed to parse params for step：", err)
                kong.response.exit(500, "server error")
            end

            local status_code, msg
            err, status_code, msg = send_request(step, step_inputs, ctx)
            if err then
                return kong.response.exit(status_code or 500, msg or "server error")
            end
        elseif step.type == 'response' then
            -- assembly response content
            local res
            res, err = get_response(step, ctx)
            if err then
                kong.response.exit(500, "server error")
            end

            kong.response.exit(res.status, res.body, res.header)
        else
            kong.log('no support type：', step.type)
        end
    end
end


return ComposerHandler
