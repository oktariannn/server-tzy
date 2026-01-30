--==[ ADVANCED SERVER HOPPER – AGRESIF + ANTI 429 ]==--

if not game:IsLoaded() then
    game.Loaded:Wait()
end

-- 🔧 KONFIGURASI
local CONFIG = {
    DelayBeforeStart    = 12,   -- jeda sebelum mulai hop (detik)
    MinPlayers          = 7,    -- minimal pemain di server utama
    MaxPlayers          = 15,   -- maksimal pemain di server utama
    MinBackupPlayers    = 3,    -- minimal pemain untuk server cadangan (hindari 1 player)
    MaxPagesToScan      = 3,    -- semakin besar, semakin berat & rawan 429
    RandomStartPage     = false,-- demi anti 429, lebih stabil kalau false
    UseAntiFriend       = true, -- cek teman di server sekarang
    RememberVisited     = true, -- ingat server yang sudah dikunjungi
    ResetVisitedAfter   = 150,  -- kalau visited > ini, reset list

    FetchCooldown       = 0.4,  -- delay antar request server list (detik)
    SafeHopCooldownMin  = 8,    -- kalau kena 429: tunggu random X–Y detik
    SafeHopCooldownMax  = 14,
}

task.wait(CONFIG.DelayBeforeStart)

local Players         = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local HttpService     = game:GetService("HttpService")

local LocalPlayer  = Players.LocalPlayer
local placeId      = game.PlaceId
local currentJobId = game.JobId

math.randomseed(os.time())

----------------------------------------------------------------
-- 🔁 GLOBAL visited server list (supaya ingat lewat teleport)
----------------------------------------------------------------
local env = getgenv and getgenv() or _G
env.AdvServerHopVisited = env.AdvServerHopVisited or {}
local visited = env.AdvServerHopVisited

local function countVisited()
    local n = 0
    for _ in pairs(visited) do
        n += 1
    end
    return n
end

-- Jangan pernah balik ke server sekarang
if CONFIG.RememberVisited and currentJobId then
    visited[currentJobId] = true
end

if CONFIG.RememberVisited and countVisited() > CONFIG.ResetVisitedAfter then
    visited = {}
    env.AdvServerHopVisited = visited
    warn("[ServerHop] Reset daftar visited server (kebanyakan).")
end

----------------------------------------------------------------
-- 👥 Load daftar teman (kalau anti friend on)
----------------------------------------------------------------
local FriendIds = {}

local function loadFriends()
    local ok, pagesOrErr = pcall(function()
        return Players:GetFriendsAsync(LocalPlayer.UserId)
    end)

    if not ok then
        warn("[ServerHop] Gagal load daftar teman:", pagesOrErr)
        return
    end

    local pages = pagesOrErr
    repeat
        for _, info in ipairs(pages:GetCurrentPage()) do
            FriendIds[info.Id] = true
        end
    until pages.IsFinished or not pcall(function()
        pages:AdvanceToNextPageAsync()
    end)
end

if CONFIG.UseAntiFriend then
    loadFriends()
end

local function HasFriendInCurrentServer()
    if not CONFIG.UseAntiFriend then return false end
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and FriendIds[plr.UserId] then
            return true, plr.Name
        end
    end
    return false
end

local hasFriend, friendName = HasFriendInCurrentServer()
if hasFriend then
    warn("[ServerHop] Ada teman di server ini:", friendName, "→ cari server lain.")
else
    print("[ServerHop] Tidak ada teman di server ini.")
end

----------------------------------------------------------------
-- 🪂 Fallback: simple rejoin
----------------------------------------------------------------
local function SimpleRejoin()
    warn("[ServerHop] Mode simple: rejoin random server di place.")
    local okTp, err = pcall(function()
        TeleportService:Teleport(placeId, LocalPlayer)
    end)
    if not okTp then
        warn("[ServerHop] Teleport simple gagal:", err)
    end
end

----------------------------------------------------------------
-- 🛡 Mode SAFE-HOP (kalau kena 429 / rate limit)
----------------------------------------------------------------
local function SafeHopRateLimited()
    local waitTime = math.random(CONFIG.SafeHopCooldownMin, CONFIG.SafeHopCooldownMax)
    warn(("[ServerHop] Roblox API rate-limited (HTTP 429). Tunggu %d detik lalu rejoin."):format(waitTime))
    task.wait(waitTime)

    local okTp, err = pcall(function()
        TeleportService:Teleport(placeId, LocalPlayer)
    end)
    if not okTp then
        warn("[ServerHop] Teleport SAFE-HOP gagal:", err)
    end
end

----------------------------------------------------------------
-- 📄 Ambil server list (Advanced mode) + proteksi 429
----------------------------------------------------------------
local cursor = nil
local lastFetch = 0
local RATE_LIMITED = false

local function GetServers()
    -- Cooldown antar request biar nggak spam API
    local diff = os.clock() - lastFetch
    if diff < CONFIG.FetchCooldown then
        task.wait(CONFIG.FetchCooldown - diff)
    end
    lastFetch = os.clock()

    local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100")
        :format(placeId)

    if cursor then
        url = url .. "&cursor=" .. cursor
    end

    local ok, result = pcall(function()
        return game:HttpGet(url)
    end)

    if not ok then
        local msg = tostring(result)
        warn("[ServerHop] Gagal ambil server list:", msg)

        if msg:find("429") or msg:find("Too Many Requests") then
            RATE_LIMITED = true
        end

        return nil
    end

    local decoded
    local okDecode, errDecode = pcall(function()
        decoded = HttpService:JSONDecode(result)
    end)

    if not okDecode then
        warn("[ServerHop] Gagal decode JSON server list:", errDecode)
        return nil
    end

    cursor = decoded.nextPageCursor
    return decoded.data
end

----------------------------------------------------------------
-- 🎲 (Opsional) Skip ke page acak – dimatikan default demi anti 429
----------------------------------------------------------------
if CONFIG.RandomStartPage then
    local maxSkip = math.max(0, CONFIG.MaxPagesToScan - 1)
    local skipPages = math.random(0, maxSkip)

    for _ = 1, skipPages do
        local servers = GetServers()
        if not servers or not cursor or RATE_LIMITED then break end
    end

    print("[ServerHop] Mulai scan dari page acak, skip halaman:", skipPages)
end

print(("[ServerHop] Target server utama: %d–%d pemain"):format(CONFIG.MinPlayers, CONFIG.MaxPlayers))
print(("[ServerHop] Minimal pemain untuk backup server: %d+"):format(CONFIG.MinBackupPlayers))

----------------------------------------------------------------
-- 🔎 Kumpulkan kandidat server
----------------------------------------------------------------
local candidates = {} -- dalam range utama
local backups    = {} -- di luar range utama, tapi masih layak

for page = 1, CONFIG.MaxPagesToScan do
    if RATE_LIMITED then
        break
    end

    local servers = GetServers()
    if not servers then
        if RATE_LIMITED then
            break
        end
        -- kalau cuma error biasa, hentikan scanning
        warn("[ServerHop] Server list kosong / gagal di page", page)
        break
    end

    for _, server in ipairs(servers) do
        local sid       = server.id
        local playing   = server.playing
        local maxPlr    = server.maxPlayers

        local notFull     = playing < maxPlr
        local inRangeMain = playing >= CONFIG.MinPlayers and playing <= CONFIG.MaxPlayers
        local notVisited  = (not CONFIG.RememberVisited) or (not visited[sid])
        local okForBackup = playing >= CONFIG.MinBackupPlayers

        if notFull and notVisited then
            local info = {
                id      = sid,
                playing = playing,
                max     = maxPlr,
                score   = 0,
            }

            -- Skor: makin dekat ke tengah range, makin bagus
            local mid  = (CONFIG.MinPlayers + CONFIG.MaxPlayers) / 2
            local dist = math.abs(playing - mid)
            info.score = -dist + math.random() -- sedikit random biar variatif

            if inRangeMain then
                table.insert(candidates, info)
            elseif okForBackup then
                table.insert(backups, info)
            end
        end
    end

    if not cursor then
        break
    end
end

-- Kalau kena rate limit di tengah jalan → SAFE-HOP
if RATE_LIMITED then
    SafeHopRateLimited()
    return
end

-- Fungsi pilih server dengan score terbaik dari list
local function pickBest(list)
    if #list == 0 then return nil end
    local best = list[1]
    for i = 2, #list do
        if list[i].score > best.score then
            best = list[i]
        end
    end
    return best
end

local target = pickBest(candidates)

if not target then
    if #backups > 0 then
        warn(("[ServerHop] Tidak ada server di range utama, pakai backup (>= %d pemain).")
            :format(CONFIG.MinBackupPlayers))
        target = pickBest(backups)
    else
        warn("[ServerHop] Tidak ada server lain yang bisa dimasuki dari server list. Rejoin biasa.")
        SimpleRejoin()
        return
    end
end

----------------------------------------------------------------
-- 🚀 Teleport ke server target
----------------------------------------------------------------
print(("[ServerHop] Teleport ke server %s (%d/%d pemain)")
    :format(target.id, target.playing, target.max))

if CONFIG.RememberVisited then
    visited[target.id] = true
end

local okTp, tpErr = pcall(function()
    TeleportService:TeleportToPlaceInstance(placeId, target.id, LocalPlayer)
end)

if not okTp then
    local errStr = tostring(tpErr)
    warn("[ServerHop] Teleport gagal:", errStr)

    if errStr:find("773") or errStr:lower():find("restricted") then
        warn("[ServerHop] Error 773 (tempat/server dibatasi Roblox). " ..
             "Ini batas dari Roblox, bukan dari script. Coba lagi nanti atau ganti game.")
    end
end
