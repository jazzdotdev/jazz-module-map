log.info("Initialize web server")

function file_ext(file)
  return file:match("^.+(%..+)$")
end

local objects = {}
local assignments = {}

--- split lines like "function obj1.fun_name(args)" into:
--- table_name: "obj1"
--- func_signature: "fun_name(args)"
local function match_func_obj(line, file_path, is_method)
	for result in string.gmatch(line, "([^\n]+)") do
		local line_number, line_without_line_info = string.match(result, "([^:]+):(.+)")
		local result_not_function = string.gsub(line_without_line_info, "function ", "")
		local table_name, func_signature = string.match(result_not_function, "([^%.:]+).(.+)")

		if not objects[table_name] then
			objects[table_name] = {
				funcs = {},
				methods = {}
			}
		end

		local t = is_method and objects[table_name].methods or objects[table_name].funcs

		local new_func_info = {
			name = func_signature,
			path = file_path,
			line = line_number
		}

		table.insert(t, new_func_info)
	end
end

--- split lines like "obj2.fun_name = function(args)" into:
--- table_name: "obj2"
--- func_signature: "fun_name(args)"
local function match_obj_func(line, file_path)
	for result in string.gmatch(line, "([^\n]+)") do
		local line_number, line_without_line_info = string.match(result, "([^:]+):(.+)")
		local table_name, func_name_and_args = string.match(line_without_line_info, "%s*([^%.:]+).(.+)")
		local func_name = string.match(func_name_and_args, "([^ ]+)")
		local func_args = string.match(func_name_and_args, "[^%(]+(.+%))")

		if not objects[table_name] then
			objects[table_name] = {
				funcs = {},
				methods = {}
			}
		end

		local new_func_info = {
			name = func_name.." "..func_args,
			path = file_path,
			line = line_number
		}

		table.insert(objects[table_name].funcs, new_func_info)
	end
end

--- match lines like 'obj.var_name = require "module"' into:
local function match_require(line, file_path)
	for result in string.gmatch(line, "([^\n]+)") do
		local line_number, line_without_line_info = string.match(result, "([^:]+):(.+)")
		local table_name, module_to_var = string.match(line_without_line_info, "%s*([^%.:]+).(.+)")
		local var_name = string.match(module_to_var, "([^ ]+)")
		local module_name = string.match(module_to_var, "[^\"']*[\"'](.+)[\"']")

		if not assignments[table_name] then
			assignments[table_name] = {}
		end

		local new_assignment_info = {
			name = table_name,
			var = var_name,
			mod = module_name,
			line = line_number
		}

		table.insert(assignments[table_name], new_assignment_info)
	end
end

local function parse_dir(path)
	for _, obj in ipairs( fs.read_dir(path) ) do
		if fs.is_dir(path.."/"..obj) then
			parse_dir(path.."/"..obj)
		elseif file_ext(obj) == ".lua" then
			local handle, result

			local file_path = path.."/"..obj

			handle = io.popen('cd '..path..'; grep -nE "^function.*?\\." '..obj)
			result = handle:read("*a")
			handle:close()
			match_func_obj(result, file_path)

			handle = io.popen('cd '..path..'; grep -nE "^function.*?:" '..obj)
			result = handle:read("*a")
			handle:close()
			match_func_obj(result, file_path, true)

			handle = io.popen('cd '..path..'; grep -nE "^[^-{2.}].*?\\.[\\w]+?.*?=[ ]*?function[ ]*?\\(" '..obj)
			result = handle:read("*a")
			handle:close()
			match_obj_func(result, file_path)
		end
	end
end

local function parse_assignments(path)
	for _, obj in ipairs( fs.read_dir(path) ) do
		if fs.is_dir(path.."/"..obj) then
			parse_assignments(path.."/"..obj)
		elseif file_ext(obj) == ".lua" then
			local handle, result

			local file_path = path.."/"..obj

			for obj_name, _ in pairs( objects ) do
				handle = io.popen('cd '..path..'; grep -nE "=\\s*require\\s*\\"'..obj_name..'\\"" '..obj)
				result = handle:read("*a")
				handle:close()
				match_require(result, file_path)
			end
		end
	end
end

parse_dir("./doc")
parse_assignments("./doc")

local assignments_to_body = {}
for k, v in pairs( assignments ) do
	local assignment = {
		name = k,
		children = v
	}
	table.insert(assignments_to_body, assignment)
end

local objs = {}
for obj_name, func_methods in pairs( objects ) do
	local new_o = {}

	-- local assigned_to_any = false
	-- for ass_obj_name, children_of_obj in pairs( assignments ) do
	-- 	if obj_name == ass_obj_name then
	-- 		assigned_to_any = true
	-- 		break
	-- 	end
	-- 	for _, child_obj_name in ipairs( children_of_obj ) do
	-- 		if obj_name == child_obj_name then
	-- 			assigned_to_any = true
	-- 			break
	-- 		end
	-- 	end
	-- end

	-- if not assigned_to_any then
	table.insert(objs, new_o)
	new_o.name = obj_name
	new_o.funcs = func_methods.funcs or {}
	new_o.methods = func_methods.methods or {}
	-- end
end

local function get_lua_file_markup(body)
	local new_body = "<pre>"
	local line_index = 1
	for s in body:gmatch("[^\n]+") do
	    new_body = new_body..'<code id="'..line_index..'">'..s..'</code>'
	    line_index = line_index + 1
	end
	new_body = new_body.."</pre>"
	return new_body
end

return function (request)

	if file_ext(request.path) == ".css" then
	  return {
	      headers = {
	        ["content-type"] = "text/css",
	      },
	      body = fs.read_file("."..request.path)
	  }
	end

	-- log.info(request.path)

	if file_ext(request.path) == ".lua" then
	  local body = fs.read_file("."..request.path)
	  body = get_lua_file_markup(body)

	  return {
	      headers = {
	        ["content-type"] = "text/html",
	      },
	      body = render("lua_script.html", {
			  body = body
		})
	  }
	end

	return {
		headers = {
		  ["content-type"] = "text/html",
		},
		body = render("index.html", {
		  objects = objs,
		  assignments = assignments_to_body
	})
}

end
