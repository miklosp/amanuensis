-- xcode-build daemon for Hammerspoon
--
-- Install:
--   cp build-daemon.lua ~/.config/hammerspoon/
--   add to ~/.config/hammerspoon/init.lua:
--       dofile(os.getenv("HOME") .. "/.config/hammerspoon/build-daemon.lua")
--   Reload Hammerspoon (menubar → Reload Config).
--
-- Protocol: agent writes JSON to $XDG_STATE_HOME/xcode-build/inbox/<jobid>.json
-- (via .tmp → rename for atomicity). Daemon validates, runs /usr/bin/xcodebuild
-- with a fixed env, streams log to outbox/<jobid>.log, writes result sentinel
-- outbox/<jobid>.json last so the agent can poll for it.
--
-- Job JSON shape:
--   { "args": ["-workspace","Foo.xcworkspace","-scheme","Foo","test"],
--     "cwd":  "/Users/miklos/dev/foo" }      -- optional; agent's project dir

-- ===== Config — adjust to your layout =====

-- xcodebuild may only operate on workspaces/projects under these roots.
-- Symlinks are resolved before checking.
local PROJECT_ROOTS = {
  os.getenv("HOME") .. "/Code/",
}

local MAX_DURATION_S = 600                  -- kill builds longer than this
local MAX_LOG_BYTES  = 50 * 1024 * 1024     -- terminate if log exceeds this

-- Env handed to xcodebuild. No PATH from the agent, no DYLD_*, no XCODE_*.
local SAFE_ENV = {
  PATH = "/usr/bin:/bin:/usr/sbin:/sbin",
  HOME = os.getenv("HOME"),
  DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer",
}

-- Per-binary allowlists. Each job's `bin` field selects one of these;
-- default is "xcodebuild" for backward compatibility.
local BIN_CONFIGS = {
  xcodebuild = {
    path = "/usr/bin/xcodebuild",
    flagsWithValue = {
      ["-workspace"]=true, ["-project"]=true, ["-scheme"]=true,
      ["-destination"]=true, ["-configuration"]=true, ["-sdk"]=true,
      ["-derivedDataPath"]=true, ["-resultBundlePath"]=true,
      ["-only-testing"]=true, ["-skip-testing"]=true,
      ["-testPlan"]=true, ["-arch"]=true,
    },
    flagsBool = {
      ["-quiet"]=true, ["-json"]=true, ["-list"]=true,
      ["-parallel-testing-enabled"]=true, ["-disable-concurrent-destination-testing"]=true,
    },
    actions = {
      build=true, test=true, clean=true, archive=true, analyze=true,
      ["build-for-testing"]=true, ["test-without-building"]=true,
    },
    flagsPathProject = { ["-workspace"]=true, ["-project"]=true },
    flagsPathOutput  = { ["-derivedDataPath"]=true, ["-resultBundlePath"]=true },
  },
  log = {
    path = "/usr/bin/log",
    flagsWithValue = {
      ["--predicate"]=true, ["--last"]=true, ["--start"]=true, ["--end"]=true,
      ["--style"]=true, ["--type"]=true, ["--process"]=true,
    },
    flagsBool = {
      ["--info"]=true, ["--debug"]=true, ["--signpost"]=true, ["--source"]=true,
      ["--color"]=true,
    },
    actions = { show=true, stream=true },
    flagsPathProject = {},
    flagsPathOutput  = {},
  },
}

-- ===== Paths =====

local function xdg(env, default)
  return os.getenv(env) or (os.getenv("HOME") .. default)
end
local STATE  = xdg("XDG_STATE_HOME", "/.local/state") .. "/xcode-build"
local CACHE  = xdg("XDG_CACHE_HOME", "/.cache")       .. "/xcode-build"
local INBOX  = STATE .. "/inbox"
local OUTBOX = STATE .. "/outbox"
local AUDIT  = STATE .. "/audit.log"
local WORK   = CACHE

local function mkdirP(p)
  local cur = ""
  for part in p:gmatch("[^/]+") do
    cur = cur .. "/" .. part
    hs.fs.mkdir(cur)
  end
end
mkdirP(INBOX); mkdirP(OUTBOX); mkdirP(WORK)

-- ===== Helpers =====

local function ts() return os.date("!%Y-%m-%dT%H:%M:%SZ") end

local function logf(jobid, msg)
  print(("[xcode-build %s] %s"):format(jobid or "-", msg))
end

local function audit(rec)
  rec.ts = ts()
  local f = io.open(AUDIT, "a")
  if f then f:write(hs.json.encode(rec) .. "\n"); f:close() end
end

local function writeAtomic(path, body)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w"); if not f then return false end
  f:write(body); f:close()
  return os.rename(tmp, path)
end

-- Resolve a possibly-relative path against the job's cwd. Returns nil if
-- the path is relative and no cwd was supplied (caller must reject).
local function resolveRelative(path, cwd)
  if path:sub(1, 1) == "/" then return path end
  if cwd and cwd ~= "" then return cwd .. "/" .. path end
  return nil
end

-- Resolves path (including non-existent files, by resolving parent), then
-- checks containment under one of the roots. Defeats ../ and symlink games.
local function isUnderRoot(path, roots)
  local real = hs.fs.pathToAbsolute(path)
  if not real then
    local parent, leaf = path:match("^(.*)/([^/]+)$")
    if parent and parent ~= "" then
      local rp = hs.fs.pathToAbsolute(parent)
      if rp then real = rp .. "/" .. leaf end
    end
  end
  if not real then return false end
  for _, root in ipairs(roots) do
    local rr = hs.fs.pathToAbsolute(root)
    if rr and (real == rr or real:sub(1, #rr + 1) == rr .. "/") then
      return true
    end
  end
  return false
end

-- ===== Validation =====

local function validate(job)
  local binName = job.bin or "xcodebuild"
  local cfg = BIN_CONFIGS[binName]
  if not cfg then return nil, "unknown bin: " .. tostring(binName) end
  if type(job.args) ~= "table" or #job.args == 0 then
    return nil, "args must be a non-empty array"
  end
  if job.cwd ~= nil and not isUnderRoot(job.cwd, PROJECT_ROOTS) then
    return nil, "cwd not under PROJECT_ROOTS: " .. tostring(job.cwd)
  end
  local i = 1
  while i <= #job.args do
    local a = job.args[i]
    if type(a) ~= "string" then return nil, "non-string arg at " .. i end
    -- KEY=VALUE overrides xcodebuild build settings; e.g.
    -- OTHER_SWIFT_FLAGS=-Xfrontend -load-plugin-executable -Xfrontend /tmp/x.dylib
    -- is arbitrary code execution. Reject all. (`log` predicate values may
    -- contain `==`, but those are consumed as flag values, not arg names.)
    if a:find("=", 1, true) then
      return nil, "= override not allowed: " .. a
    end
    if a:sub(1, 1) == "-" then
      if cfg.flagsBool[a] then
        i = i + 1
      elseif cfg.flagsWithValue[a] then
        local v = job.args[i + 1]
        if not v then return nil, "flag " .. a .. " missing value" end
        if v:sub(1, 1) == "-" then return nil, "flag " .. a .. " value looks like a flag: " .. v end
        if cfg.flagsPathProject[a] then
          local resolved = resolveRelative(v, job.cwd)
          if not resolved or not isUnderRoot(resolved, PROJECT_ROOTS) then
            return nil, a .. " path not under PROJECT_ROOTS: " .. v
          end
        end
        if cfg.flagsPathOutput[a] then
          local resolved = resolveRelative(v, job.cwd)
          if not resolved or not isUnderRoot(resolved, { WORK }) then
            return nil, a .. " path not under cache root: " .. v
          end
        end
        i = i + 2
      else
        return nil, "flag not allowed: " .. a
      end
    elseif cfg.actions[a] then
      i = i + 1
    else
      return nil, "positional not allowed: " .. a
    end
  end
  return cfg
end

-- ===== Job runner (single-flight queue) =====

local active, pending = nil, {}
local runNext  -- forward decl

local function runJob(jobPath)
  local jobid = jobPath:match("([^/]+)%.json$")

  local fh = io.open(jobPath, "r")
  if not fh then
    audit({jobid=jobid, status="open-failed"})
    return runNext()
  end
  local raw = fh:read("*a"); fh:close()
  local job = hs.json.decode(raw)
  if not job then
    audit({jobid=jobid, status="bad-json"})
    os.rename(jobPath, OUTBOX .. "/" .. jobid .. ".bad.json")
    return runNext()
  end

  local cfg, err = validate(job)
  if not cfg then
    audit({jobid=jobid, status="rejected", reason=err, bin=job.bin, args=job.args, cwd=job.cwd})
    writeAtomic(OUTBOX .. "/" .. jobid .. ".json",
                hs.json.encode({jobid=jobid, exit=-1, error=err}, true))
    os.remove(jobPath)
    logf(jobid, "REJECTED: " .. err)
    return runNext()
  end

  active = jobid
  local logPath = OUTBOX .. "/" .. jobid .. ".log"
  local lf = io.open(logPath, "w")
  local written, killed = 0, nil
  local t0 = hs.timer.absoluteTime()

  audit({jobid=jobid, status="start", bin=job.bin, args=job.args, cwd=job.cwd})
  logf(jobid, ("starting: %s %s"):format(cfg.path, table.concat(job.args, " ")))

  local task
  local function finish(exit)
    if lf then lf:close(); lf = nil end
    local durMs = math.floor((hs.timer.absoluteTime() - t0) / 1e6)
    writeAtomic(OUTBOX .. "/" .. jobid .. ".json", hs.json.encode({
      jobid = jobid, exit = exit, durationMs = durMs,
      killed = killed, log = logPath,
    }, true))
    audit({jobid=jobid, status="done", exit=exit, durationMs=durMs, killed=killed})
    logf(jobid, ("done exit=%s dur=%dms%s"):format(tostring(exit), durMs, killed and (" killed="..killed) or ""))
    os.remove(jobPath)
    active = nil
    runNext()
  end

  task = hs.task.new(
    cfg.path,
    function(exit, sOut, sErr)
      if lf then
        if sOut and #sOut > 0 then lf:write(sOut) end
        if sErr and #sErr > 0 then lf:write(sErr) end
      end
      finish(exit)
    end,
    function(_, sOut, sErr)
      if not lf then return false end
      local chunk = (sOut or "") .. (sErr or "")
      if #chunk == 0 then return true end
      written = written + #chunk
      if written > MAX_LOG_BYTES then
        killed = "log-overflow"
        lf:write("\n[xcode-build] log exceeded " .. MAX_LOG_BYTES .. " bytes; terminating\n")
        task:terminate()
        return false
      end
      lf:write(chunk); lf:flush()
      return true
    end,
    job.args
  )
  if job.cwd then task:setWorkingDirectory(job.cwd) end
  task:setEnvironment(SAFE_ENV)
  task:start()

  hs.timer.doAfter(MAX_DURATION_S, function()
    if active == jobid and task:isRunning() then
      killed = "timeout"
      if lf then lf:write("\n[xcode-build] " .. MAX_DURATION_S .. "s timeout; terminating\n") end
      task:terminate()
    end
  end)
end

runNext = function()
  if active then return end
  local nextPath = table.remove(pending, 1)
  if nextPath then runJob(nextPath) end
end

local function scan()
  for file in hs.fs.dir(INBOX) do
    if file:match("%.json$") and not file:match("%.tmp$") then
      local full = INBOX .. "/" .. file
      local jid  = file:match("(.+)%.json$")
      if active ~= jid and not hs.fnutils.contains(pending, full) then
        table.insert(pending, full)
      end
    end
  end
  runNext()
end

xcodeBuildWatcher = hs.pathwatcher.new(INBOX, scan):start()
-- Backup poll: hs.pathwatcher sometimes silently stops delivering FSEvent
-- notifications. A 2s rescan keeps the queue alive without relying on it.
xcodeBuildPoll = hs.timer.doEvery(2, scan)
scan()  -- drain anything left from a prior session
logf(nil, "daemon up; inbox=" .. INBOX)
