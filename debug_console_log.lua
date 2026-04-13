local M = {}

local DEFAULT_FILE_NAME = "DebugConsole.log"

local initialized = false
local originalPrint = _G.print
local inWrite = false
local useLoveFilesystem = false
local resolvedPath = DEFAULT_FILE_NAME
local virtualPath = DEFAULT_FILE_NAME

local function nowStamp()
    if os and os.date then
        return os.date("%Y-%m-%d %H:%M:%S")
    end
    return "0000-00-00 00:00:00"
end

local function stringifyArgs(...)
    local count = select("#", ...)
    if count == 0 then
        return ""
    end

    local parts = {}
    for i = 1, count do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    return table.concat(parts, "\t")
end

local function writeRawLine(line)
    if inWrite then
        return
    end

    inWrite = true

    if useLoveFilesystem and love and love.filesystem and type(love.filesystem.append) == "function" then
        pcall(love.filesystem.append, virtualPath, line .. "\n")
    else
        local file = io.open(resolvedPath, "a")
        if file then
            file:write(line)
            file:write("\n")
            file:close()
        end
    end

    inWrite = false
end

function M.getPath()
    return resolvedPath
end

function M.reset(reason)
    local header = string.format("[%s] Debug console log reset (%s)", nowStamp(), tostring(reason or "manual"))

    if useLoveFilesystem and love and love.filesystem and type(love.filesystem.write) == "function" then
        pcall(love.filesystem.write, virtualPath, header .. "\n")
    else
        local file = io.open(resolvedPath, "w")
        if file then
            file:write(header)
            file:write("\n")
            file:close()
        end
    end
end

function M.append(...)
    local message = stringifyArgs(...)
    writeRawLine(string.format("[%s] %s", nowStamp(), message))
end

function M.init(opts)
    if initialized then
        return true
    end

    opts = opts or {}
    virtualPath = tostring(opts.fileName or DEFAULT_FILE_NAME)
    resolvedPath = virtualPath

    if love and love.filesystem and type(love.filesystem.getSaveDirectory) == "function" then
        local ok, saveDir = pcall(love.filesystem.getSaveDirectory)
        if ok and type(saveDir) == "string" and saveDir ~= "" then
            local normalized = saveDir:gsub("[/\\]+$", "")
            resolvedPath = normalized .. "/" .. virtualPath
        end
    end

    useLoveFilesystem = love and love.filesystem and type(love.filesystem.write) == "function" and type(love.filesystem.append) == "function"

    M.reset("app_start")

    _G.print = function(...)
        originalPrint(...)
        M.append(...)
    end

    initialized = true
    return true
end

return M
