log.info("Initialize web server")
log.info("Parsing lua files...")

function file_ext(file)
  return file:match("^.+(%..+)$")
end

local objects = {}
local assignments = {}
assignments["_G"] = {}

--- split lines like "function obj1.fun_name(args)" into:
--- table_name: "obj1"
--- func_signature: "fun_name(args)"
local function match_func_obj(line, file_path, line_number, is_method)
	local result_not_function = string.gsub(line, "function ", "")
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

--- split lines like "obj2.fun_name = function(args)" into:
--- table_name: "obj2"
--- func_signature: "fun_name(args)"
local function match_obj_func(line, file_path, line_number)
	local table_name, func_name_and_args = string.match(line, "%s*([^%.:]+).(.+)")
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

--- match lua binding in Rust files
--- example: module.set("read_dir", lua.create_function( |lua, path: String| {
local function match_module_set(line, file_path, line_number)
	local func_name, func_args = string.match(line, "[^\"]+.([^\"]+).*|[^,]*,[ ]*([^|]+)")

	local new_func_info = {
		name = func_name.." ("..func_args..")",
		path = file_path,
		line = line_number
	}

	return new_func_info
end

--- match lua binding in Rust files where we can't parse arguments
--- example: module.set("read_dir", func_name)
local function match_module_set_empty(line, file_path, line_number)
	local func_name = string.match(line, "[^\"]+.([^\"]+)")
	local new_func_info = {
		name = func_name,
		path = file_path,
		line = line_number
	}

	return new_func_info
end

--- match module name in Rust lua bindings
--- example: set("yaml", module)?;
local function match_module_name(line, file_path, line_number)
	local module_name = string.match(line, '.*set%(\"([^\"]*)')
	return module_name
end

--- match lines like 'obj.var_name = require "module"'
local function match_require(line, file_path, line_number)
	local table_name, module_to_var = string.match(line, "%s*([^%.:]+).(.+)")
	local var_name = string.match(module_to_var, "([^ ]+)")
	local module_name = string.match(module_to_var, "[^\"']*[\"'](.+)[\"']")

	if not assignments[table_name] then
		assignments[table_name] = {}
	end

	local new_assignment_info = {
		name = table_name,
		var = var_name,
		mod = module_name,
		line = line_number,
		path = file_path
	}

	table.insert(assignments[table_name], new_assignment_info)
end

--- match lines like '_G.obj_name = require'
local function match_global_require(line, file_path, line_number)
	local module_name = string.match(line, "_G%.([^%s=]+)")
	local table_name = "_G"

	if not assignments[table_name] then
		assignments[table_name] = {}
	end

	local new_assignment_info = {
		name = table_name,
		mod = module_name,
		line = line_number,
		path = file_path
	}

	local already_exists = false
	for _, assignment_info in ipairs( assignments[table_name] ) do
		if module_name == assignment_info.mod then
			already_exists = true
			break
		end
	end

	if not already_exists then
		table.insert(assignments[table_name], new_assignment_info)
	end
end

--- match lines like 'require "obj_name"' and 'require "folder.obj_name"'
local function match_module_require(line, file_path, line_number, file_name)
	if not objects[file_name] then
		return
	end

	local module_name = string.match(line, "require%s+[\"'](.+)[\"']")
	if string.find(module_name, ".") then
		module_name = string.match(module_name, ".*%.(.*)")
	end
	local table_name = file_name

	if not assignments[table_name] then
		assignments[table_name] = {}
	end

	local new_assignment_info = {
		name = table_name,
		mod = module_name,
		line = line_number,
		path = file_path
	}

	local already_exists = false
	for _, assignment_info in ipairs( assignments[table_name] ) do
		if module_name == assignment_info.mod then
			already_exists = true
			break
		end
	end

	if not already_exists then
		if not objects[module_name] then
			new_assignment_info.use_path = true
		end

		table.insert(assignments[table_name], new_assignment_info)
	end
end

--- match lines like 'global_table["key"] = ...'
local function match_global_table_access(line, file_path, line_number)
	local table_name, module_name = string.match(line, '([^\\[]+)..([^"\'"]+).*')

	if not objects[table_name] then
		objects[table_name] = {
			funcs = {},
			methods = {}
		}
	end
	if not objects[table_name].members then
		objects[table_name].members = {}
	end

	local new_func_info = {
		name = module_name,
		path = file_path,
		line = line_number
	}

	table.insert(objects[table_name].members, new_func_info)

	local already_exists = false
	for _, assignment_info in ipairs( assignments["_G"] ) do
		if table_name == assignment_info.mod then
			already_exists = true
			break
		end
	end

	local new_assignment_info = {
		name = "_G",
		mod = table_name,
		line = line_number,
		path = file_path
	}

	if not already_exists then
		if not objects[table_name] then
			new_assignment_info.use_path = true
		end

		table.insert(assignments["_G"], new_assignment_info)
	end
end

local function parse_dir(path)
	for _, obj in ipairs( fs.read_dir(path) ) do
		if fs.is_dir(path.."/"..obj) then
			parse_dir(path.."/"..obj)
		elseif file_ext(obj) == ".lua" or file_ext(obj) == ".rs" then
			local file_path = path.."/"..obj

			log.info(file_path)

			local file_contents = fs.read_file(file_path)
			local line_index = 1

			-- module.set variables
			local module_name
			local module_line
			local rs_bindings = {}

			for s in file_contents:gmatch("[^\n]*") do
				if file_ext(obj) == ".lua" then
				    if regex.match("^function.*?\\.", s) then
						match_func_obj(s, file_path, line_index)
				    end
				    if regex.match("^function.*?:", s) then
						match_func_obj(s, file_path, line_index, true)
				    end
				    if regex.match("^[^-{2.}].*?\\.[\\w]+?.*?=[ ]*?function[ ]*?\\(", s) then
						match_obj_func(s, file_path, line_index)
				    end
				elseif file_ext(obj) == ".rs" then
				    if regex.match("module\\.set.*?\\|.*?,[ ]*(.*?)\\|", s) then
						table.insert(rs_bindings, match_module_set(s, file_path, line_index))
				    elseif regex.match('module\\.set\\(".*?",', s) then
						table.insert(rs_bindings, match_module_set_empty(s, file_path, line_index))
				    end
				    if regex.match("set\\(\".*?\",[ ]*module", s) then
						module_name = match_module_name(s, file_path, line_index)
						module_line = line_index
				    end
				end
			    line_index = line_index + 1
			end

			if module_name and #rs_bindings > 0 then
				if not objects[module_name] then
					objects[module_name] = {
						funcs = {},
						methods = {}
					}
				end
				for _, func_info in ipairs( rs_bindings ) do
					table.insert(objects[module_name].funcs, func_info)
				end

				local table_name = "_G"

				if not objects[table_name] then
					objects[table_name] = {
						funcs = {},
						methods = {}
					}
				end

				if not assignments[table_name] then
					assignments[table_name] = {}
				end

				local new_assignment_info = {
					name = table_name,
					mod = module_name,
					line = module_line,
					path = file_path
				}

				local already_exists = false
				for _, assignment_info in ipairs( assignments[table_name] ) do
					if module_name == assignment_info.mod then
						already_exists = true
						break
					end
				end

				if not already_exists then
					table.insert(assignments[table_name], new_assignment_info)
				end
			end
		end
	end
end

local function parse_assignments(path)
	for _, obj in ipairs( fs.read_dir(path) ) do
		if fs.is_dir(path.."/"..obj) then
			parse_assignments(path.."/"..obj)
		elseif file_ext(obj) == ".lua" then

			local file_path = path.."/"..obj

			local file_contents = fs.read_file(file_path)
			local line_index = 1
			for s in file_contents:gmatch("[^\n]*") do
				for obj_name, _ in pairs( objects ) do
				    if regex.match('=\\s*require\\s*"'..obj_name..'"', s) then
						match_require(s, file_path, line_index)
				    end
				    if regex.match('^_G\\.'..obj_name..'\\s*=\\s*require', s) then
						match_global_require(s, file_path, line_index)
				    end
				    if regex.match('^require [\"\'].*'..obj_name..'.*[\"\']', s) then
						match_module_require(s, file_path, line_index, obj:match("^(.+)%..+$"))
				    end
				end

				if regex.match('^\\w+\\["\\w+"\\][ ]+=', s) then
					match_global_table_access(s, file_path, line_index)
			    end

			    line_index = line_index + 1
			end
		end
	end
end

parse_dir("./doc")
parse_assignments("./doc")

local assignments_to_body = {}

local G_assignment = {
	name = "_G",
	children = assignments["_G"]
}
table.insert(assignments_to_body, G_assignment)
for k, v in pairs( assignments ) do
	if k ~= "_G" then
		local assignment = {
			name = "_G",
			mod = k,
			line = 1,
			path = "",
		}
		table.insert(G_assignment.children, assignment)
	end
end

for obj_name, _ in pairs( objects ) do
	if obj_name ~= "_G" then
		local already_exists = false
		for _, assignment in ipairs( G_assignment.children ) do
			if assignment.mod == obj_name then
				already_exists = true
				break
			end
		end
		if not already_exists then
			local assignment = {
				name = "_G",
				mod = obj_name,
				line = 1,
				path = "",
			}
			table.insert(G_assignment.children, assignment)
		end
	end
end

local objs = {}
for obj_name, func_methods in pairs( objects ) do
	local new_o = {}
	table.insert(objs, new_o)
	new_o.name = obj_name
	new_o.funcs = func_methods.funcs or {}
	new_o.methods = func_methods.methods or {}
	new_o.members = func_methods.members or {}
end

for _, assignment in ipairs( assignments_to_body ) do
	for _, obj in ipairs( objs ) do
		if obj.name == assignment.name then
			assignment.obj = obj
			break
		end
	end
	for _, child in ipairs( assignment.children ) do
		for _, obj in ipairs( objs ) do
			if obj.name == child.mod then
				child.obj = obj
				break
			end
		end
	end
end

for k, v in pairs( assignments ) do
	if k ~= "_G" then
		local assignment  = G_assignment
		for _, child in ipairs( assignment.children ) do
			if child.mod == k then
				for _, obj in ipairs( objs ) do
					for _, ass_child in pairs( v ) do
						if obj.name == ass_child.mod then
							if not child.obj.children then
								child.obj.children = {}
							end

							table.insert(child.obj.children, obj)
							break
						end
					end
				end
			end
		end
	end
end

log.info("Done parsing lua files!")

local function get_lua_file_lines(body)
	local code_lines = {}
	for line in body:gmatch("[^\n]*") do
	    table.insert(code_lines, line)
	end
	return code_lines
end

local _tera = tera.new("./templates/*")

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

	if file_ext(request.path) == ".lua" or file_ext(request.path) == ".rs" then
	  local body = fs.read_file("."..request.path)
	  local code_lines = get_lua_file_lines(body)

	  return {
	      headers = {
	        ["content-type"] = "text/html",
	      },
	      body = _tera:render("lua_script.html", {
			  lines = code_lines
		})
	  }
	end

	-- routing for templates
	local template_name = "index.html"
	if fs.exists("./templates"..request.path..".html") then
		template_name = string.match(request.path, '/(.*)')..".html"
	end

	return {
		headers = {
		  ["content-type"] = "text/html",
		},
		body = _tera:render(template_name, {
		  objects = objs,
		  assignments = assignments_to_body
	})
}

end
