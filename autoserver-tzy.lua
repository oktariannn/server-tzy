--==[ ADVANCED SERVER HOPPER – 3 MODE + COOLDOWN + PARTIAL RESET + SMART SIMPLE + JOBID LOG ]==--

if not game:IsLoaded() then
    game.Loaded:Wait()
end

-- 🔧 KONFIGURASI
local CONFIG = {
    DelayBeforeStart      = 8,    -- jeda sebelum mulai hop (detik)

    -- MODE UTAMA (medium traffic)
    MinPlayersMain        = 4,    -- minimal pemain server utama
    MaxPlayersMain        = 15,   -- maksimal pemain server utama

    -- MODE BACKUP (kalau nggak ada utama)
    MinPlayersBackup      = 3,    -- >2 player (3+)

    -- MODE LAST_RESORT (game super sepi tapi tetap >1 player)
    MinPlayersLastResort  = 2,    -- >1 player (2+)

    MaxPagesToScan        = 4,    -- makin besar makin berat & rawan 429
    RandomStartPage       = false,-- demi anti 429, false lebih stabil
    UseAntiFriend         = true, -- cek teman di server sekarang

    RememberVisited       = true, -- ingat server yang sudah dikunjungi
    ResetVisitedAfter     = 200,  -- jika total visited > ini → kompres
    KeepVisitedAfter      = 80,   -- setelah kompres, usahakan sisa sekitar ini

    FetchCooldown         = 0.4,  -- delay antar request server list (detik)
    SafeHopCooldownMin    = 8,    -- kalau kena 429: tunggu random X–Y detik
    SafeHopCooldownMax    = 14,

    -- Cooldown sebelum simple rejoin, mengurangi kemungkinan balik ke server sama
    SimpleRejoinCooldownMin = 10,
    SimpleRejoinCooldownMax = 18,
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
if CONFIG.RememberVisited and currentJobId and currentJobId ~= "" then
    visited[currentJobId] = true
end

-- Partial reset: kalau kebanyakan, buang sebagian saja
local function compactVisited()
    local total = countVisited()
    if not CONFIG.RememberVisited or total <= CONFIG.ResetVisitedAfter then
        return
    end

    warn(("[ServerHop] visited server %d > %d, kompres list...")
        :format(total, CONFIG.ResetVisitedAfter))

    local keepTarget = CONFIG.KeepVisitedAfter
    if keepTarget <= 0 then
        -- fallback: full reset
        for k in pairs(visited) do
            visited[k] = nil
        end
        if currentJobId and currentJobId ~= "" then
            visited[currentJobId] = true
        end
        env.AdvServerHopVisited = visited
        warn("[ServerHop] visited di-reset total (fallback).")
        return
    end

    -- hapus entri secara bertahap sampai mendekati keepTarget
    local toRemove = math.max(0, total - keepTarget)
    for jobId in pairs(visited) do
        if toRemove <= 0 then
            break
        end
        if jobId ~= currentJobId then
            visited[jobId] = nil
            toRemove -= 1
        end
    end

    env.AdvServerHopVisited = visited
    warn(("[ServerHop] visited dikompres. Sekarang ~%d server disimpan."):format(countVisited()))
end

compactVisited()

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
-- 🧠 SMART Simple rejoin dengan cooldown + anti visited + log JobId
----------------------------------------------------------------
local function SimpleRejoin()
    local waitTime = math.random(CONFIG.SimpleRejoinCooldownMin, CONFIG.SimpleRejoinCooldownMax)
    warn(("[ServerHop] Mode simple: cooldown %d detik sebelum cari server lain.")
        :format(waitTime))
    task.wait(waitTime)

    -- Coba ambil 1 page server list dan pilih server lain yang:
    -- - tidak penuh
    -- - JobId beda
    -- - bukan visited
    -- - minimal 1 player
    local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100")
        :format(placeId)

    local okHttp, result = pcall(function()
        return game:HttpGet(url)
    end)

    if okHttp then
        local okDecode, decoded = pcall(function()
            return HttpService:JSONDecode(result)
        end)

        if okDecode and decoded and decoded.data then
            local best

            for _, server in ipairs(decoded.data) do
                local sid     = server.id
                local playing = server.playing
                local maxPlr  = server.maxPlayers

                local notFull    = playing < maxPlr
                local notCurrent = sid ~= currentJobId
                local notVisited = (not CONFIG.RememberVisited) or (not visited[sid])

                if notFull and notCurrent and notVisited and playing >= 1 then
                    local score = playing + math.random()
                    if not best or score > best.score then
                        best = {
                            id      = sid,
                            playing = playing,
                            max     = maxPlr,
                            score   = score,
                        }
                    end
                end
            end

            if best then
                warn(("[ServerHop] Smart simple: teleport ke server lain (%d/%d pemain).")
                    :format(best.playing, best.max))
                warn(("[ServerHop] Smart simple JobId: %s"):format(best.id))

                if CONFIG.RememberVisited then
                    visited[best.id] = true
                end

                local okTp, errTp = pcall(function()
                    TeleportService:TeleportToPlaceInstance(placeId, best.id, LocalPlayer)
                end)
                if not okTp then
                    warn("[ServerHop] Teleport smart simple gagal:", errTp)
                end
                return
            else
                warn("[ServerHop] Smart simple: tidak ada server lain (semua visited/penuh/0 player).")
            end
        else
            warn("[ServerHop] Smart simple: gagal decode server list.")
        end
    else
        warn("[ServerHop] Smart simple gagal ambil server list:", tostring(result))
    end

    -- Fallback terakhir: benar-benar rejoin random
    warn("[ServerHop] Smart simple gagal, rejoin random server.")
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
    warn(("[ServerHop] Roblox API rate-limited (HTTP 429). Tunggu %d detik lalu rejoin.")
        :format(waitTime))
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
-- 🔎 Kumpulkan kandidat server: utama / backup / last_resort
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

            if playing >= CONFIG.MinPlayersMain and playing <= CONFIG.MaxPlayersMain then
                -- Mode utama: 4–15 player, makin dekat tengah makin bagus
                local mid  = (CONFIG.MinPlayersMain + CONFIG.MaxPlayersMain) / 2
                local dist = math.abs(playing - mid)
                info.score = -dist + math.random()
                table.insert(candidates, info)

            elseif playing >= CONFIG.MinPlayersBackup then
                -- Mode backup: 3+ player, makin rame makin bagus
                info.score = playing + math.random()
                table.insert(backups, info)

            elseif playing >= CONFIG.MinPlayersLastResort then
                -- Mode last_resort: 2+ player, game sepi tapi tetap >1
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
    warn("[ServerHop] Tidak ada server lain yang memenuhi semua mode. Simple rejoin dengan cooldown + anti visited.")
    SimpleRejoin()
    return
end

----------------------------------------------------------------
-- 🚀 Teleport ke server target (log JobId juga)
----------------------------------------------------------------
print(("[ServerHop] Mode: %s | Teleport ke server (%d/%d pemain)")
    :format(mode, target.playing, target.max))
print(("[ServerHop] JobId target: %s"):format(target.id))

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
