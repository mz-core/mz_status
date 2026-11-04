local PRESENTATION_EVENT = 'mz_status:client:consumablePresented'
local ACTIVITY_EVENT = 'mz_status:server:reportActivityCandidate'
local ANIMATIONS_RESOURCE = 'mz_animations'
local PRESENTATION_STATE_NAME = 'mz_status:consumable'
local PRESENTATION_MIN_MS = 250
local PRESENTATION_MAX_MS = 5000
local PRESENTATION_TICK_MS = 100
local DICT_LOAD_TIMEOUT_MS = 2000
local MODEL_LOAD_TIMEOUT_MS = 2000

local lastShotReportAt = 0
local lastSpeedReportAt = 0
local activePresentation = nil
local catalogCache = {}

local function canAct()
  local ok, allowed = pcall(function()
    return exports['mz_core']:CanLocalPlayerPerformAction('inventory.use')
  end)
  return ok and allowed == true
end

local function report(activityType)
  TriggerServerEvent(ACTIVITY_EVENT, { type = activityType })
end

local function clampPresentationMs(value)
  local duration = math.floor(tonumber(value) or PRESENTATION_MIN_MS)
  if duration < PRESENTATION_MIN_MS then return PRESENTATION_MIN_MS end
  if duration > PRESENTATION_MAX_MS then return PRESENTATION_MAX_MS end
  return duration
end

local function normalizeAnimation(raw)
  if type(raw) ~= 'table' then return nil end
  if type(raw.dict) ~= 'string' or raw.dict == '' then return nil end
  if type(raw.anim) ~= 'string' or raw.anim == '' then return nil end
  return {
    dict = raw.dict,
    anim = raw.anim,
    prop = type(raw.prop) == 'string' and raw.prop ~= '' and raw.prop or nil,
    hand = tonumber(raw.hand) or 28422,
    flag = tonumber(raw.flag) or 49
  }
end

local function resolveCatalogEmote(name)
  if type(name) ~= 'string' or name == '' then return nil end
  if catalogCache[name] ~= nil then
    return catalogCache[name] or nil
  end
  if GetResourceState(ANIMATIONS_RESOURCE) ~= 'started' then return nil end

  local ok, catalog = pcall(function()
    return exports[ANIMATIONS_RESOURCE]:GetCatalog()
  end)
  if not ok or type(catalog) ~= 'table' then
    catalogCache[name] = false
    return nil
  end

  local lowered = string.lower(name)
  for index = 1, #catalog do
    local entry = catalog[index]
    if type(entry) == 'table' and type(entry.name) == 'string'
      and string.lower(entry.name) == lowered then
      catalogCache[name] = entry
      return entry
    end
  end

  catalogCache[name] = false
  return nil
end

-- Reaproveita o catálogo do mz_animations (ex.: beber7/comer) e troca apenas o
-- nome para que o cleanup saiba que a apresentação pertence ao mz_status.
local function buildPresentationDefinition(payload, animation)
  local entry = resolveCatalogEmote(payload.emote)
  local definition
  if entry then
    definition = {}
    for key, value in pairs(entry) do definition[key] = value end
  elseif animation then
    definition = {
      dict = animation.dict,
      anim = animation.anim,
      prop = animation.prop,
      hand = animation.hand,
      flag = animation.flag
    }
  end
  if not definition then return nil end
  definition.name = PRESENTATION_STATE_NAME
  return definition
end

local function requestAnimDict(dict)
  if HasAnimDictLoaded(dict) then return true end
  RequestAnimDict(dict)
  local deadline = GetGameTimer() + DICT_LOAD_TIMEOUT_MS
  while not HasAnimDictLoaded(dict) and GetGameTimer() < deadline do
    Wait(0)
  end
  return HasAnimDictLoaded(dict)
end

local function attachLocalProp(ped, animation)
  if not animation.prop then return nil end
  local hash = joaat(animation.prop)
  if not IsModelInCdimage(hash) or not IsModelValid(hash) then return nil end

  if not HasModelLoaded(hash) then
    RequestModel(hash)
    local deadline = GetGameTimer() + MODEL_LOAD_TIMEOUT_MS
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do
      Wait(0)
    end
  end
  if not HasModelLoaded(hash) then return nil end

  local coords = GetEntityCoords(ped)
  local object = CreateObjectNoOffset(hash, coords.x, coords.y, coords.z + 0.2, true, true, false)
  SetModelAsNoLongerNeeded(hash)
  if object == 0 then return nil end

  AttachEntityToEntity(
    object,
    ped,
    GetPedBoneIndex(ped, animation.hand),
    0.0, 0.0, 0.0,
    0.0, 0.0, 0.0,
    true, true, false, true, 1, true
  )
  return object
end

local function deleteLocalProp(prop)
  if not prop or prop == 0 or not DoesEntityExist(prop) then return end
  DetachEntity(prop, true, true)
  SetEntityAsMissionEntity(prop, true, true)
  DeleteEntity(prop)
end

local function stopLocalPresentation(state)
  local ped = state.ped
  deleteLocalProp(state.prop)
  if ped and ped ~= 0 and DoesEntityExist(ped) then
    StopAnimTask(ped, state.dict, state.anim, 2.0)
    if IsEntityPlayingAnim(ped, state.dict, state.anim, 3) then
      ClearPedTasksImmediately(ped)
    end
  end
  if state.dict and HasAnimDictLoaded(state.dict) then
    RemoveAnimDict(state.dict)
  end
end

local function stopAnimationsPresentation()
  if GetResourceState(ANIMATIONS_RESOURCE) ~= 'started' then return end
  pcall(function()
    local current = exports[ANIMATIONS_RESOURCE]:GetCurrent()
    if type(current) == 'table' and current.name == PRESENTATION_STATE_NAME then
      exports[ANIMATIONS_RESOURCE]:Stop('mz_status_consumable', false)
    end
  end)
end

local function stopPresentation()
  local state = activePresentation
  if not state then return end
  activePresentation = nil
  if state.owner == 'local' then
    stopLocalPresentation(state)
  else
    stopAnimationsPresentation()
  end
end

local function startAnimationsPresentation(definition, duration, ped)
  if not definition then return false end
  if GetResourceState(ANIMATIONS_RESOURCE) ~= 'started' then return false end

  local ok, played = pcall(function()
    return exports[ANIMATIONS_RESOURCE]:Play(definition, {
      duration = duration,
      silent = true,
      stateName = PRESENTATION_STATE_NAME
    })
  end)
  if not ok or played ~= true then return false end

  activePresentation = { owner = 'mz_animations', ped = ped }
  return true
end

local function startLocalPresentation(animation, ped)
  if not animation or not requestAnimDict(animation.dict) then return false end

  local prop = attachLocalProp(ped, animation)
  TaskPlayAnim(
    ped,
    animation.dict,
    animation.anim,
    4.0,
    -4.0,
    -1,
    animation.flag,
    0.0,
    false,
    false,
    false
  )
  activePresentation = {
    owner = 'local',
    ped = ped,
    dict = animation.dict,
    anim = animation.anim,
    prop = prop
  }
  return true
end

local function runPresentationWindow(payload, animation, ped, duration)
  local definition = buildPresentationDefinition(payload, animation)
  local started
  if GetResourceState(ANIMATIONS_RESOURCE) == 'started' then
    started = startAnimationsPresentation(definition, duration, ped)
  else
    started = startLocalPresentation(animation, ped)
  end
  if not started then return end

  local elapsed = 0
  while elapsed < duration do
    Wait(PRESENTATION_TICK_MS)
    elapsed = elapsed + PRESENTATION_TICK_MS
    local state = activePresentation
    if not state then return end

    local currentPed = PlayerPedId()
    if currentPed ~= ped or not DoesEntityExist(currentPed)
      or IsEntityDead(currentPed) or IsPedRagdoll(currentPed)
      or IsPedInAnyVehicle(currentPed, false) then
      stopPresentation()
      return
    end
  end

  stopPresentation()
end

RegisterNetEvent(PRESENTATION_EVENT, function(payload)
  if type(payload) ~= 'table' or type(payload.operationId) ~= 'string'
    or type(payload.category) ~= 'string' or type(payload.durationMs) ~= 'number' then return end

  local ped = PlayerPedId()
  local duration = clampPresentationMs(payload.durationMs)
  local animation = normalizeAnimation(payload.animation)

  -- Nunca iniciar cenário/animação "in place" dentro de veículo: isso ejetava o
  -- jogador do carro e podia derrubá-lo do mapa (limbo).
  if canAct() and DoesEntityExist(ped) and not IsEntityDead(ped)
    and not IsPedRagdoll(ped) and not IsPedInAnyVehicle(ped, false) then
    stopPresentation()
    CreateThread(function()
      runPresentationWindow(payload, animation, ped, duration)
    end)
  end

  if lib and lib.notify then
    lib.notify({
      type = 'success',
      title = tostring(payload.label or 'Consumível'),
      description = payload.category == 'medical_basic' and 'Tratamento básico aplicado.' or 'Consumido com sucesso.'
    })
  end
end)

AddEventHandler('onResourceStop', function(resourceName)
  if resourceName ~= GetCurrentResourceName() then return end
  stopPresentation()
end)

AddEventHandler('mz_status:client:reportVehicleImpact', function(hadSeatbelt)
  if not canAct() then return end
  report(hadSeatbelt == true and 'vehicle_impact_belted' or 'vehicle_impact_unbelted')
end)

CreateThread(function()
  while true do
    Wait(250)
    if canAct() then
      local current = GetGameTimer()
      local ped = PlayerPedId()
      if IsPedShooting(ped) and current - lastShotReportAt >= 1000 then
        lastShotReportAt = current
        report('shot_fired')
      end
      if current - lastSpeedReportAt >= 2000 then
        lastSpeedReportAt = current
        local vehicle = GetVehiclePedIsIn(ped, false)
        if vehicle and vehicle ~= 0 and GetPedInVehicleSeat(vehicle, -1) == ped
          and (GetEntitySpeed(vehicle) * 3.6) >= (tonumber(Config.Status.stress.highSpeed.thresholdKmh) or 160) then
          report('high_speed')
        end
      end
    end
  end
end)
