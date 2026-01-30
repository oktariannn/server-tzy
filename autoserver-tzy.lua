--==[ ADVANCED SERVER HOPPER – MINIMAL 4 PLAYER + SMART REJOIN ]==--

if not game:IsLoaded() then
    game.Loaded:Wait()
end

-- 🔧 KONFIGURASI
local CONFIG = {
    DelayBeforeStart    = 15,    -- jeda sebelum mulai hop (detik)

    -- RANGE UTAMA
    MinPlayers          = 4,    -- minimal pemain server utama
    MaxPlayers          = 14,   -- maksimal pemain server utama

    -- BACKUP (kalau nggak ada di range utama)
    MinBackupPlayers    = 4,    -- minimal pemain untuk backup (tetap >=4)

    MaxPagesToScan      = 4,    -- makin besar makin berat & rawan 429
    RandomStartPage     = false,-- demi anti 429, false lebih stabil
    UseAntiFriend       = true, -- cek teman di server sekarang
    RememberVisited     = true, -- ingat server yang sudah dikunjungi
    ResetVisitedAfter   = 150,  -- kalau visited > ini, reset list

    FetchCooldown       = 0.4,  -- delay antar request server list (detik)
    SafeHopCooldownMin  = 15,    -- kalau kena 429: tunggu random X–Y detik
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
-- 🧠 SMART REJOIN: coba cari server lain dulu sebelum rejoin random
----------------------------------------------------------------
local function SimpleRejoin()
    warn("[ServerHop] Mode smart-simple: coba cari server lain sebelum rejoin random.")

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

                -- Di smart rejoin kita boleh lebih fleksibel:
                -- minimal 1 player, tapi tetap prefer yang rame
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
                warn(("[ServerHop] Smart rejoin → teleport ke server lain (%d/%d pemain).")
                    :format(best.playing, best.max))

                if CONFIG.RememberVisited then
                    visited[best.id] = true
                end

                local okTp, errTp = pcall(function()
                    TeleportService:TeleportToPlaceInstance(placeId, best.id, LocalPlayer)
                end)
                if not okTp then
                    warn("[ServerHop] Teleport smart rejoin gagal:", errTp)
                end
                return
            else
                warn("[ServerHop] Smart rejoin: tidak ditemukan server lain yang valid dari 1 page.")
            end
        else
            warn("[ServerHop] Smart rejoin: gagal decode server list.")
        end
    else
        local msg = tostring(result)
        warn("[ServerHop] Smart rejoin gagal ambil server list:", msg)
    end

    -- Fallback terakhir: benar-benar rejoin random
    warn("[ServerHop] Smart rejoin gagal, rejoin random biasa.")
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

print(("[ServerHop] Target server utama: %d–%d pemain"):format(CONFIG.MinPlayers, CONFIG.MaxPlayers))
print(("[ServerHop] Minimal pemain untuk backup server: %d+"):format(CONFIG.MinBackupPlayers))

----------------------------------------------------------------
-- 🔎 Kumpulkan kandidat server (≥ 4 player SELALU untuk advanced)
----------------------------------------------------------------
local candidates = {} -- dalam range utama (4–14)
local backups    = {} -- di luar range utama, tapi masih >=4 player

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

        local notFull     = playing < maxPlr
        local inRangeMain = playing >= CONFIG.MinPlayers and playing <= CONFIG.MaxPlayers
        local notVisited  = (not CONFIG.RememberVisited) or (not visited[sid])

        -- Hard limit advanced: cuma terima >= MinBackupPlayers (>=4)
        local okAtAll     = playing >= CONFIG.MinBackupPlayers

        if notFull and notVisited and okAtAll then
            local info = {
                id      = sid,
                playing = playing,
                max     = maxPlr,
                score   = 0,
            }

            -- Skor: makin dekat ke tengah range, makin bagus
            local mid  = (CONFIG.MinPlayers + CONFIG.MaxPlayers) / 2
            local dist = math.abs(playing - mid)
            info.score = -dist + math.random()

            if inRangeMain then
                table.insert(candidates, info)
            else
                table.insert(backups, info)
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
        warn(("[ServerHop] Tidak ada server di range utama, pakai backup (>= %d pemain).")
            :format(CONFIG.MinBackupPlayers))
    end
end

if not target then
    warn("[ServerHop] Tidak ada server lain yang >= 4 pemain dari server list. Smart rejoin.")
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
