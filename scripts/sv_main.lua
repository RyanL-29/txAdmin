--Helpers
function log(x)
    print("^5[txAdminClient]^0 " .. x)
end
function logError(x)
    print("^5[txAdminClient]^1 " .. x .. "^0")
end
function unDeQuote(x)
    local new, count = string.gsub(x, utf8.char(65282), '"')
    return new
end

--Check Environment
local apiHost = GetConvar("txAdmin-apiHost", "invalid")
local apiToken = GetConvar("txAdmin-apiToken", "invalid")
local txAdminClientVersion = GetResourceMetadata(GetCurrentResourceName(), 'version')
if GetConvar('txAdminServerMode', 'false') ~= 'true' then
    return
end
if apiHost == "invalid" or apiToken == "invalid" then
    logError('API Host or Token ConVars not found. Do not start this resource if not using txAdmin.')
    return
end
if GetCurrentResourceName() ~= "monitor" then
    logError('This resource should not be installed separately, it already comes with fxserver.')
    return
end
--Erasing the token convar
-- SetConvar("txAdmin-apiToken", "removed") //FIXME:


-- Setup threads and commands
local hbReturnData = 'no-data'
log("Version "..txAdminClientVersion.." starting...")
CreateThread(function()
    RegisterCommand("txaPing", txaPing, true)
    RegisterCommand("txaWarnID", txaWarnID, true)
    RegisterCommand("txaKickAll", txaKickAll, true)
    RegisterCommand("txaKickID", txaKickID, true)
    RegisterCommand("txaDropIdentifiers", txaDropIdentifiers, true)
    RegisterCommand("txaBroadcast", txaBroadcast, true)
    RegisterCommand("txaEvent", txaEvent, true)
    RegisterCommand("txaSendDM", txaSendDM, true)
    RegisterCommand("txaReportResources", txaReportResources, true)
    CreateThread(function()
        while true do
            HTTPHeartBeat()
            Wait(3000)
        end
    end)
    CreateThread(function()
        while true do
            FD3HeartBeat()
            Wait(3000)
        end
    end)
    AddEventHandler('playerConnecting', handleConnections)
    SetHttpHandler(handleHttp)
    log("Threads and commands set up. All Ready.")
end)


-- HeartBeat functions
function HTTPHeartBeat()
    local curPlyData = {}
    local players = GetPlayers()
    for i = 1, #players do
        local player = players[i]
        local ids = GetPlayerIdentifiers(player)
        -- using manual insertion instead of table.insert is faster
        curPlyData[i] = {
            id = player,
            identifiers = ids,
            name = GetPlayerName(player),
            ping = GetPlayerPing(player)
        }
    end

    local url = "http://"..apiHost.."/intercom/monitor"
    local exData = {
        txAdminToken = apiToken,
        players = curPlyData
    }
    PerformHttpRequest(url, function(httpCode, data, resultHeaders)
        local resp = tostring(data)
        if httpCode ~= 200 then
            hbReturnData = "HeartBeat failed with code "..httpCode.." and message: "..resp
            logError(hbReturnData)
        else
            hbReturnData = resp
        end
    end, 'POST', json.encode(exData), {['Content-Type']='application/json'})
end

function FD3HeartBeat()
    local payload = json.encode({type = 'txAdminHeartBeat'})
    Citizen.InvokeNative(`PRINT_STRUCTURED_TRACE` & 0xFFFFFFFF, payload)
end

-- HTTP request handler
function handleHttp(req, res)
    res.writeHead(200, {["Content-Type"]="application/json"})

    if req.path == '/stats.json' then
        return res.send(hbReturnData)
    elseif req.path == '/players.json' then
        if txHttpPlayerlistHandler ~= nil then
            return txHttpPlayerlistHandler(req, res)
        else
            return res.send(json.encode({error = 'handler not found'}))
        end
    else
        return res.send(json.encode({error = 'route not found'}))
    end
end

-- Ping!
function txaPing(source, args)
    log("Pong!")
    CancelEvent()
end

-- Warn specific player via server ID
function txaWarnID(source, args)
    if #args == 6 then
        for k,v in pairs(args) do
            args[k] = unDeQuote(v)
        end
        local id, author, reason, tTitle, tWarnedBy, tInstruction = table.unpack(args)
        local pName = GetPlayerName(id)
        if pName ~= nil then
            TriggerClientEvent('txAdminClient:warn', id, author, reason, tTitle, tWarnedBy, tInstruction)
            log("Warning "..pName.." with reason: "..reason)
        else
            logError('txaWarnID: player not found')
        end
    else
        logError('Invalid arguments for txaWarnID')
    end
    CancelEvent()
end

-- Kick all players
function txaKickAll(source, args)
    if args[1] == nil then
        args[1] = 'no reason provided'
    else
        args[1] = unDeQuote(args[1])
    end
    log("Kicking all players with reason: "..args[1])
    for _, pid in pairs(GetPlayers()) do
        DropPlayer(pid, "\n".."Kicked for: " .. args[1])
    end
    CancelEvent()
end

-- Kick specific player via server ID
function txaKickID(source, args)
    if #args ~= 2 then
        return logError("Invalid arguments for txaKickID")
    end
    local playerID, quotedMessage = table.unpack(args)

    local dropMessage = 'Kicked with no reason provided.'
    if quotedMessage ~= nil then dropMessage = unDeQuote(quotedMessage) end

    log("Kicking #"..playerID.." with reason: "..dropMessage)
    DropPlayer(playerID, "\n"..dropMessage)
    CancelEvent()
end

-- Kick any player with matching identifiers
function txaDropIdentifiers(_, args)
    if #args ~= 2 then
        return logError("Invalid arguments for txaDropIdentifiers")
    end
    local rawIdentifiers, quotedReason = table.unpack(args)

    local dropMessage = 'no reason provided'
    if quotedReason ~= nil then dropMessage = unDeQuote(quotedReason) end

    local searchIdentifiers = {}
    for id in string.gmatch(rawIdentifiers, '([^,;%s]+)') do
        table.insert(searchIdentifiers, id)
    end

    -- find players to kick
    local kickCount = 0
    for _, playerID in pairs(GetPlayers()) do
        local identifiers = GetPlayerIdentifiers(playerID)
        if identifiers ~= nil then
            local found = false
            for _, searchIdentifier in pairs(searchIdentifiers) do
                if found then break end

                for _, playerIdentifier in pairs(identifiers) do
                    if searchIdentifier == playerIdentifier then
                        log("Kicking #"..playerID.." with message: "..dropMessage)
                        kickCount = kickCount + 1
                        DropPlayer(playerID, dropMessage)
                        found = true
                        break
                    end
                end
            end

        end
    end

    if kickCount == 0 then
        log("No players found to kick")
    end
    CancelEvent()
end

-- Fire server event
-- FIXME: check source to make sure its from the console
function txaEvent(source, args)
    if args[1] ~= nil and args[2] ~= nil then
        local eventName = unDeQuote(args[1])
        local eventData = unDeQuote(args[2])
        TriggerEvent("txAdmin:events:" .. eventName, json.decode(eventData))
    else
        logError('Invalid arguments for txaEvent')
    end
    CancelEvent()
end

-- Broadcast admin message to all players
-- TODO: deprecate txaBroadcast, carefull to also show it on the Server Log
function txaBroadcast(source, args)
    if args[1] ~= nil and args[2] ~= nil then
        args[1] = unDeQuote(args[1])
        args[2] = unDeQuote(args[2])
        log("Admin Broadcast - "..args[1]..": "..args[2])
        TriggerClientEvent("chat:addMessage", -1, {
            args = {
                "(Broadcast) "..args[1],
                args[2],
            },
            color = {255, 0, 0}
        })
        TriggerEvent('txaLogger:internalChatMessage', 'tx', "(Broadcast) "..args[1], args[2])
    else
        logError('Invalid arguments for txaBroadcast')
    end
    CancelEvent()
end

-- Send admin direct message to specific player
function txaSendDM(source, args)
    if args[1] ~= nil and args[2] ~= nil and args[3] ~= nil then
        args[2] = unDeQuote(args[2])
        args[3] = unDeQuote(args[3])
        local pName = GetPlayerName(args[1])
        if pName ~= nil then
            log("Admin DM to "..pName.." from "..args[2]..": "..args[3])
            TriggerClientEvent("chat:addMessage", args[1], {
                args = {
                    "(DM) "..args[2],
                    args[3],
                },
                color = {255, 0, 0}
            })
            TriggerEvent('txaLogger:internalChatMessage', -1, "(DM) "..args[2], args[3])
        else
            logError('txaSendDM: player not found')
        end
    else
        logError('Invalid arguments for txaSendDM')
    end
    CancelEvent()
end

-- Get all resources/statuses and report back to txAdmin
function txaReportResources(source, args)
    --Prepare resources list
    local resources = {}
    local max = GetNumResources() - 1
    for i = 0, max do
        local resName = GetResourceByFindIndex(i)

        -- hacky patch
        local resDesc = GetResourceMetadata(resName, 'description')
        if resDesc ~= nil and string.find(resDesc, "Louis.dll") then
            resDesc = nil
        end

        local currentRes = {
            name = resName,
            status = GetResourceState(resName),
            author = GetResourceMetadata(resName, 'author'),
            version = GetResourceMetadata(resName, 'version'),
            description = resDesc,
            path = GetResourcePath(resName)
        }
        table.insert(resources, currentRes)
    end

    --Send to txAdmin
    local url = "http://"..apiHost.."/intercom/resources"
    local exData = {
        txAdminToken = apiToken,
        resources = resources
    }
    log('Sending resources list to txAdmin.')
    PerformHttpRequest(url, function(httpCode, data, resultHeaders)
        local resp = tostring(data)
        if httpCode ~= 200 then
            logError("ReportResources failed with code "..httpCode.." and message: "..resp)
        end
    end, 'POST', json.encode(exData), {['Content-Type']='application/json'})
end

-- Player connecting handler
function handleConnections(name, skr, d)
    local player = source
    if GetConvar("txAdmin-checkPlayerJoin", "invalid") == "true" then
        d.defer()
        Wait(0)

        --Preparing vars and making sure we do have indentifiers
        local url = "http://"..apiHost.."/intercom/checkPlayerJoin"
        local exData = {
            txAdminToken = apiToken,
            identifiers = GetPlayerIdentifiers(player),
            name = name
        }
        if #exData.identifiers <= 1 then
            d.done("[txAdmin] You do not have at least 1 valid identifier. If you own this server, make sure sv_lan is disabled in your server.cfg")
            return
        end

        --Attempt to validate the user
        CreateThread(function()
            local attempts = 0
            local isDone = false;
            --Do 10 attempts
            while isDone == false and attempts < 10 do
                attempts = attempts + 1
                d.update("[txAdmin] Checking banlist/whitelist... ("..attempts.."/10)")
                PerformHttpRequest(url, function(httpCode, data, resultHeaders)
                    local resp = tostring(data)
                    if httpCode ~= 200 then
                        logError("[txAdmin] Checking banlist/whitelist failed with code "..httpCode.." and message: "..resp)
                    elseif data == 'allow' then
                        if not isDone then
                            d.done()
                            isDone = true
                        end
                    else
                        if not isDone then
                            d.done("\n"..data)
                            isDone = true
                        end
                    end
                end, 'POST', json.encode(exData), {['Content-Type']='application/json'})
                Wait(2000)
            end

            --Block client if failed
            if not isDone then
                d.done('[txAdmin] Failed to validate your banlist/whitelist status. Try again later.')
                isDone = true
            end
        end)

    end
end
