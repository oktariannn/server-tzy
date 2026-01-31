--==[ ADVANCED SERVER HOPPER – ANTI 429 + LAST RESORT ]==--

if not game:IsLoaded() then
    game.Loaded:Wait()
end

-- Konfigurasi umum
local CONFIG = {
    DelayBeforeStart      = 8,   -- jeda sebelum mulai hop (detik)

    -- RANGE UTAMA
    MinPlayers            = 3,   -- minimal pemain di server tujuan
    MaxPlayers            = 7,   -- maksimal pemain di server tujuan

    -- RANGE CADANGAN
    BackupMinPlayers      = 2,   -- server cadangan minimal 2 pemain (tidak 1 pemain)

    MaxPagesToScan        = 6,   -- maksimal halaman server yang discan
    RandomStartPage       = true,-- mulai dari page acak
    UseAntiFriend         = true,-- cek teman di server sekarang
    RememberVisited       = true,-- ingat server yang sudah dikunjungi
    ResetVisitedAfter     = 150, -- kalau visited > ini, reset list

    LastResortAvoidSolo   = true,-- last resort tetap menghindari server 1 pemain kalau bisa
}

task.wait(CONFIG.DelayBeforeStart)

local Players         = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local HttpService     = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local placeId     = game.PlaceId
local currentJob  = game.JobId

math.randomseed(os.time())

----------------------------------------------------------------
-- 🔁 GLOBAL visited server list
----------------------------------------------------------------
local env = getgenv and getgenv() or _G
env.AdvServerHopVisited = env.AdvServerHopVisited or {}
local visited = env.AdvServerHopVisited

local function countVisited()
    local n = 0
    for _ in pairs(visited) do n += 1 end
    return n
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
-- 🌐 Cek apakah HTTP ke games.roblox.com tersedia
----------------------------------------------------------------
local HTTP_OK = true

do
    local testUrl = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=10")
        :format(placeId)

    local ok, res = pcall(function()
        return game:HttpGet(testUrl)
    end)

    if not ok then
        HTTP_OK = false
        warn("[ServerHop] HTTP ke games.roblox.com diblokir oleh executor / device.")
        warn("[ServerHop] Mode simple saja (tanpa server list).")
    else
        local okDecode = pcall(function()
            HttpService:JSONDecode(res)
        end)
        if not okDecode then
            HTTP_OK = false
            warn("[ServerHop] Response server list tidak valid, mode advanced dimatikan.")
        end
    end
end

----------------------------------------------------------------
-- 🪂 Mode simple (kalau HTTP tidak bisa sama sekali)
----------------------------------------------------------------
local function SimpleRejoin()
    warn("[ServerHop] Mode simple aktif (tanpa server list). Rejoin place saja.")
    local okTp, err = pcall(function()
        TeleportService:Teleport(placeId, LocalPlayer)
    end)
    if not okTp then
        warn("[ServerHop] Teleport simple gagal:", err)
    end
end

if not HTTP_OK then
    SimpleRejoin()
    return
end

----------------------------------------------------------------
-- 📄 Ambil server list (Advanced mode)
----------------------------------------------------------------
local cursor = nil
local RATE_LIMITED = false  -- kalau kena 429 kita tandai

local function GetServers()
    if RATE_LIMITED then return nil end -- sudah 429, jangan spam lagi

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
        if msg:find("429") then
            RATE_LIMITED = true
            warn("[ServerHop] Gagal ambil server list: HTTP 429 (Too Many Requests. Retry later)")
        else
            warn("[ServerHop] Gagal ambil server list:", msg)
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
-- 🎲 Skip ke page acak dulu (RandomStartPage)
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

print(("[ServerHop] Target server: %d–%d pemain"):format(CONFIG.MinPlayers, CONFIG.MaxPlayers))

----------------------------------------------------------------
-- 🔎 Kumpulkan kandidat server
----------------------------------------------------------------
local candidates = {}   -- sesuai range utama
local backups    = {}   -- minimal BackupMinPlayers
local anyServers = {}   -- last resort: server apa saja selain JobId sekarang
local anyNonSolo = {}   -- last resort tapi minimal 2 pemain

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

for page = 1, CONFIG.MaxPagesToScan do
    local servers = GetServers()
    if not servers then break end

    for _, server in ipairs(servers) do
        local sid       = server.id
        local playing   = server.playing
        local maxPlr    = server.maxPlayers

        if sid ~= currentJob then
            -- kumpulkan semua server untuk last resort
            local anyInfo = {
                id      = sid,
                playing = playing,
                max     = maxPlr,
                score   = math.random(),
            }
            table.insert(anyServers, anyInfo)
            if playing >= 2 then
                table.insert(anyNonSolo, anyInfo)
            end
        end

        local notFull       = playing < maxPlr
        local inMainRange   = playing >= CONFIG.MinPlayers and playing <= CONFIG.MaxPlayers
        local inBackupRange = playing >= CONFIG.BackupMinPlayers
        local notVisited    = (not CONFIG.RememberVisited) or (not visited[sid])
        local notSameServer = sid ~= currentJob

        if notFull and notVisited and notSameServer then
            local info = {
                id      = sid,
                playing = playing,
                max     = maxPlr,
                score   = 0,
            }

            local mid  = (CONFIG.MinPlayers + CONFIG.MaxPlayers) / 2
            local dist = math.abs(playing - mid)
            info.score = -dist + math.random()

            if inMainRange then
                table.insert(candidates, info)
            elseif inBackupRange then
                table.insert(backups, info)
            end
        end
    end

    if not cursor or RATE_LIMITED then
        break
    end
end

----------------------------------------------------------------
-- 🎯 Pilih server target
----------------------------------------------------------------
local target = pickBest(candidates)

if not target then
    if #backups > 0 then
        warn(("[ServerHop] Tidak ada server pas %d–%d pemain, pakai server cadangan (≥%d pemain).")
            :format(CONFIG.MinPlayers, CONFIG.MaxPlayers, CONFIG.BackupMinPlayers))
        target = pickBest(backups)
    else
        -- LAST RESORT
        if CONFIG.LastResortAvoidSolo and #anyNonSolo > 0 then
            warn("[ServerHop] Tidak ada server sesuai kriteria, pilih server acak non-solo (last resort).")
            target = anyNonSolo[math.random(1, #anyNonSolo)]
        elseif #anyServers > 0 then
            warn("[ServerHop] Tidak ada server sesuai kriteria, pilih server acak (last resort, bisa solo).")
            target = anyServers[math.random(1, #anyServers)]
        else
            -- 🔴 kasus: server list kosong (biasanya 429 parah)
            if RATE_LIMITED then
                warn("[ServerHop] Kena HTTP 429, server list kosong. Rejoin random (Roblox yang pilih server).")
            else
                warn("[ServerHop] Server list kosong / hanya berisi server ini. Rejoin random (Roblox yang pilih server).")
            end

            SimpleRejoin()
            return
        end
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
    if errStr:find("IsTeleporting") then
        warn("[ServerHop] Teleport sedang diproses Roblox (IsTeleporting), abaikan error ini.")
        return
    end

    warn("[ServerHop] Teleport gagal:", errStr)

    if errStr:find("773") or errStr:lower():find("restricted") then
        warn("[ServerHop] Error 773 (tempat/server dibatasi Roblox). " ..
             "Ini batas server, bukan script. Coba lagi nanti atau ganti game.")
    end
end
