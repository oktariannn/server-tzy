--==[ ADVANCED SERVER HOPPER – 3 MODE (UTAMA / BACKUP / LAST_RESORT) ]==--

if not game:IsLoaded() then
    game.Loaded:Wait()
end

-- 🔧 KONFIGURASI
local CONFIG = {
    DelayBeforeStart      = 15,    -- jeda sebelum mulai hop (detik)

    -- MODE UTAMA (medium traffic)
    MinPlayersMain        = 4,    -- minimal pemain server utama
    MaxPlayersMain        = 15,   -- maksimal pemain server utama

    -- MODE BACKUP (kalau nggak ada utama)
    MinPlayersBackup      = 3,    -- >2 player (3+)

    -- MODE LAST_RESORT (game super sepi)
    MinPlayersLastResort  = 2,    -- >1 player (2+)

    MaxPagesToScan        = 4,    -- makin besar makin berat & rawan 429
    RandomStartPage       = false,-- demi anti 429, false lebih stabil
    UseAntiFriend         = true, -- cek teman di server sekarang
    RememberVisited       = true, -- ingat server yang sudah dikunjungi
    ResetVisitedAfter     = 150,  -- kalau visited > ini, reset list

    FetchCooldown         = 0.4,  -- delay antar request server list (detik)
    SafeHopCooldownMin    = 8,    -- kalau kena 429: tunggu random X–Y detik
    SafeHopCooldownMax    = 14,
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
-- 🔁 visited server list (supaya ingat lewat teleport)
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

-- Jangan pernah balik ke server sekarang (kalau bisa)
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
-- 🪂 Fallback: simple rejoin (kalau semua mode gagal)
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
-- 🛡 SAFE-HOP (kalau kena 429 / rate limit)
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
-- 🎲 Random start page (optional, default off)
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

print(("[ServerHop] Mode: utama → %d–%d pemain"):format(CONFIG.MinPlayersMain, CONFIG.MaxPlayersMain))
print(("[ServerHop] Mode: backup → >= %d pemain"):format(CONFIG.MinPlayersBackup))
print(("[ServerHop] Mode: last_resort → >= %d pemain (lebih dari 1)")
    :format(CONFIG.MinPlayersLastResort))

----------------------------------------------------------------
-- 🔎 Kumpulkan kandidat server
--   - UTAMA       : 4–15 player
--   - BACKUP      : 3+ player (luar range utama)
--   - LAST_RESORT : 2+ player (bener-bener sepi tapi tetap >1)
----------------------------------------------------------------
local candidates  = {} -- utama
local backups     = {} -- backup
local lastResorts = {} -- last_resort

for page = 1, CONFIG.MaxPagesToScan do
    if RATE_LIMITED then
        break
    end

    local servers = GetServers()
    if not servers then
        if RATE_LIMITED then
            break
        end
        warn("[ServerHop] Server list kosong / gagal di page", page)
        break
    end

    for _, server in ipairs(servers) do
        local sid       = server.id
        local playing   = server.playing
        local maxPlr    = server.maxPlayers

        local notFull    = playing < maxPlr
        local notVisited = (not CONFIG.RememberVisited) or (not visited[sid])
        local notCurrent = sid ~= currentJobId

        if notFull and notVisited and notCurrent then
            local info = {
                id      = sid,
                playing = playing,
                max     = maxPlr,
                score   = 0,
            }

            -- Mode utama: 4–15
            if playing >= CONFIG.MinPlayersMain and playing <= CONFIG.MaxPlayersMain then
                -- skor: makin dekat ke tengah range, makin bagus
                local mid  = (CONFIG.MinPlayersMain + CONFIG.MaxPlayersMain) / 2
                local dist = math.abs(playing - mid)
                info.score = -dist + math.random()
                table.insert(candidates, info)

            -- Mode backup: >2 (3+), di luar range utama
            elseif playing >= CONFIG.MinPlayersBackup then
                info.score = playing + math.random() -- makin rame makin bagus
                table.insert(backups, info)

            -- Mode last_resort: >1 (2+), di luar backup
            elseif playing >= CONFIG.MinPlayersLastResort then
                info.score = playing + math.random()
                table.insert(lastResorts, info)
            end
        end
    end

    if not cursor then
        break
    end
end

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
local mode   = "utama"

if not target then
    if #backups > 0 then
        target = pickBest(backups)
        mode   = "backup"
        warn("[ServerHop] Mode backup aktif → pakai server >2 pemain (3+).")
    elseif #lastResorts > 0 then
        target = pickBest(lastResorts)
        mode   = "last_resort"
        warn("[ServerHop] Mode last_resort aktif → game sepi, pakai server terbaik yang >1 pemain.")
    end
end

if not target then
    warn("[ServerHop] Tidak ada server lain yang memenuhi semua mode. Rejoin biasa.")
    SimpleRejoin()
    return
end

----------------------------------------------------------------
-- 🚀 Teleport ke server target
----------------------------------------------------------------
print(("[ServerHop] Mode: %s | Teleport ke server %s (%d/%d pemain)")
    :format(mode, target.id, target.playing, target.max))

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
