-- For the window test (run-frontend.sh): run the core inside Chimera for a
-- fixed number of frames with nothing pressed, then dump one memory domain
-- (when the job names one). The script compares that dump byte for byte with
-- the one Chimera's headless runner writes for the same game.
--
-- Job description comes from the file named by the MINIHAWK_JOB env var:
--   frames=<how many frames to advance>
--   out=<path to write the RAM dump (binary)>
--   meta=<path to write result metadata (text)>
--   shot=<optional path to write a screenshot>
--   domain=<optional: the memory domain to dump>

local function writeAll(path, data)
	local f = assert(io.open(path, "wb"))
	f:write(data)
	f:close()
end

local meta = {}
local function finish(status, detail)
	local lines = {
		"status=" .. status,
		"detail=" .. (detail or ""),
		"frames=" .. (meta.frames or 0),
		"lag=" .. (meta.lag or 0),
		"ramsize=" .. (meta.ramsize or 0),
		"ramhash=" .. (meta.ramhash or ""),
		-- the size of the picture the machine draws
		"width=" .. (meta.width or 0),
		"height=" .. (meta.height or 0),
	}
	if meta.metaPath then
		writeAll(meta.metaPath, table.concat(lines, "\n") .. "\n")
	end
	client.exit()
end

local jobPath = os.getenv("MINIHAWK_JOB")
if jobPath == nil then
	error("MINIHAWK_JOB env var not set")
end
local job = {}
for line in io.lines(jobPath) do
	local k, v = line:match("^([^=]+)=(.*)$")
	if k then job[k] = v end
end
meta.metaPath = job.meta

-- this core's system
local sysid = emu.getsystemid()
if sysid ~= "C64" then
	finish("ERROR", "wrong system id: " .. tostring(sysid))
end
if emu.getcorename() ~= "VICE" then
	finish("ERROR", "wrong core: " .. tostring(emu.getcorename()))
end

pcall(function() client.speedmode(6400) end)
pcall(function() client.invisibleemulation(true) end)

local frames = tonumber(job.frames) or 120
for _ = 1, frames do
	emu.frameadvance()
end

meta.frames = emu.framecount()
meta.lag = emu.lagcount()
meta.height = client.bufferheight()
meta.width = client.bufferwidth()

if job.shot ~= nil and job.shot ~= "" then
	client.screenshot(job.shot)
end

local DOMAIN = job.domain
if DOMAIN ~= nil and DOMAIN ~= "" then
	local ok, why = pcall(function()
		memory.usememorydomain(DOMAIN)
		meta.ramsize = memory.getcurrentmemorydomainsize()
		meta.ramhash = memory.hash_region(0, meta.ramsize, DOMAIN)
		local ram = memory.read_bytes_as_array(0, meta.ramsize, DOMAIN)
		local chunks = {}
		for i = 1, #ram do
			chunks[i] = string.char(ram[i])
		end
		writeAll(job.out, table.concat(chunks))
	end)
	if not ok then
		finish("ERROR", "memory domain " .. DOMAIN .. ": " .. tostring(why))
	end
end

finish("OK", "")
