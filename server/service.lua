MZStatusService = MZStatusService or {}

local Runtime = {}
local UnavailableBySource = {}
local LogAtBySource = {}
local operationSequence = 0
local schedulerRunning = false
local stopping = false

local ACTIVITY_EVENT = 'mz_status:server:reportActivityCandidate'
local PRESENTATION_EVENT = 'mz_status:client:consumablePresented'
local ACTIVITY_TYPES = {
  shot_fired = true,
  high_speed = true,
  vehicle_impact_belted = true,
  vehicle_impact_unbelted = true
}

local function statusConfig()
  return Config and Config.Status or {}
end

local function nowMs()
  if type(GetGameTimer) == 'function' then return GetGameTimer() end
  return math.floor(os.clock() * 1000)
end

local function clone(value)
  if type(value) ~= 'table' then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = clone(child) end
  return result
end

local function finite(value)
  local number = tonumber(value)
  return number and number == number and number ~= math.huge and number ~= -math.huge
end

local function coreCall(exportName, ...)
  local args = table.pack(...)
  local ok, first, second = pcall(function()
    local coreExports = exports['mz_core']
    return coreExports[exportName](coreExports, table.unpack(args, 1, args.n))
  end)
  if not ok then return false, { code = 'core_unavailable', detail = tostring(first) } end
  return first, second
end

local function telemetry(eventName, fields)
  pcall(function() exports['mz_core']:RecordPlayerStateEvent(eventName, fields or {}) end)
end

local function metric(name, amount)
  pcall(function() exports['mz_core']:IncrementPlayerStateMetric(name, amount or 1) end)
end

local function debugEnabled()
  return Config and Config.Debug == true
end

local function debugLog(message)
  if debugEnabled() then print(('[MZ_STATUS][SERVER] %s'):format(message)) end
end

local function positiveInteger(value)
  value = tonumber(value)
  if not value or value <= 0 or value % 1 ~= 0 then return nil end
  return value
end

local function resolveActiveIdentity(source)
  source = positiveInteger(source)
  if not source then return nil, 'invalid_source', { lifecycle = 'UNKNOWN' } end

  local sessionCallOk, session = pcall(function()
    return exports['mz_core']:GetPlayerSession(source)
  end)
  if not sessionCallOk or type(session) ~= 'table' then
    return nil, sessionCallOk and 'session_unavailable' or 'core_unavailable', { lifecycle = 'UNKNOWN' }
  end

  local lifecycle = tostring(session.lifecycle or 'UNKNOWN')
  local sessionId = positiveInteger(session.sessionId or session.id)
  local accountId = positiveInteger(session.accountId)
  local characterId = positiveInteger(session.activeCharacterId)
  if session.isActive ~= true or lifecycle ~= 'CHARACTER_ACTIVE' or not sessionId or not accountId or not characterId then
    return nil, 'character_unavailable', { lifecycle = lifecycle, sessionId = sessionId }
  end

  local identityCallOk, identity = pcall(function()
    return exports['mz_core']:ResolvePlayerIdentity(source)
  end)
  if not identityCallOk or type(identity) ~= 'table' then
    return nil, identityCallOk and 'identity_unavailable' or 'core_unavailable', {
      lifecycle = lifecycle,
      sessionId = sessionId
    }
  end
  if identity.ok ~= true or identity.active ~= true then
    return nil, tostring(identity.error or 'identity_inactive'), {
      lifecycle = lifecycle,
      sessionId = sessionId
    }
  end

  local identitySessionId = positiveInteger(identity.sessionId)
  local identityAccountId = positiveInteger(identity.accountId)
  local identityCharacterId = positiveInteger(identity.characterId)
  if identitySessionId ~= sessionId or identityAccountId ~= accountId or identityCharacterId ~= characterId then
    return nil, 'identity_mismatch', { lifecycle = lifecycle, sessionId = sessionId }
  end

  return {
    source = source,
    sessionId = tostring(sessionId),
    accountId = accountId,
    characterId = characterId,
    lifecycle = lifecycle
  }
end

local function getState(source)
  local ok, result = coreCall('GetPlayerState', source)
  if not ok or type(result) ~= 'table' or type(result.state) ~= 'table' then
    return nil, result and result.code or 'player_not_loaded'
  end
  return result.state
end

local function logLimited(source, code, message)
  source = tonumber(source)
  if not source then return end
  local current = nowMs()
  local cooldown = tonumber(statusConfig().activity and statusConfig().activity.logCooldownMs) or 5000
  LogAtBySource[source] = LogAtBySource[source] or {}
  if LogAtBySource[source][code] and current - LogAtBySource[source][code] < cooldown then return end
  LogAtBySource[source][code] = current
  print(('[mz_status][%s] source=%s %s'):format(tostring(code), tostring(source), tostring(message or '')))
end

local function cleanupRuntime(source, reason)
  source = tonumber(source)
  local runtime = source and Runtime[source] or nil
  if runtime then
    debugLog(('cleanup source=%s characterId=%s reason=%s'):format(
      tostring(source), tostring(runtime.characterId), tostring(reason or 'unknown')
    ))
  end
  if source then Runtime[source] = nil end
  return runtime ~= nil
end

local function logCharacterUnavailable(source, code, detail)
  if not debugEnabled() then return end
  source = tonumber(source)
  if not source then return end
  detail = type(detail) == 'table' and detail or {}
  local current = nowMs()
  local signature = ('%s:%s'):format(tostring(code), tostring(detail.lifecycle or 'UNKNOWN'))
  local previous = UnavailableBySource[source]
  if previous and previous.signature == signature and current - previous.loggedAt < 15000 then return end
  UnavailableBySource[source] = { signature = signature, loggedAt = current }
  debugLog(('characterUnavailable source=%s lifecycle=%s error=%s'):format(
    tostring(source), tostring(detail.lifecycle or 'UNKNOWN'), tostring(code or 'unknown')
  ))
end

local function newRuntime(source, identity, current)
  local runtime = {
    source = tonumber(source),
    sessionId = tostring(identity.sessionId),
    accountId = tonumber(identity.accountId),
    characterId = tonumber(identity.characterId),
    lifecycle = tostring(identity.lifecycle),
    lastTickAt = current or nowMs(),
    hungerAccumulator = 0,
    thirstAccumulator = 0,
    stressAccumulator = 0,
    criticalHungerAccumulator = 0,
    criticalThirstAccumulator = 0,
    lastActivityAt = current or nowMs(),
    activityCooldowns = {},
    activityWindow = { startedAt = current or nowMs(), count = 0 },
    consumptionCooldownUntil = 0,
    categoryCooldowns = {},
    activeOperation = nil,
    completedOperations = {},
    logAt = {}
  }
  Runtime[tonumber(source)] = runtime
  UnavailableBySource[tonumber(source)] = nil
  debugLog(('characterBound source=%s characterId=%s sessionId=%s'):format(
    tostring(source), tostring(runtime.characterId), tostring(runtime.sessionId)
  ))
  return runtime
end

local function runtimeFor(source, current, create, resolvedIdentity)
  source = tonumber(source)
  local identity, identityErr, identityDetail = resolvedIdentity, nil, nil
  if type(identity) ~= 'table' then
    identity, identityErr, identityDetail = resolveActiveIdentity(source)
  end
  if not identity then
    cleanupRuntime(source, identityErr or 'character_unavailable')
    logCharacterUnavailable(source, identityErr, identityDetail)
    return nil, identityErr or 'character_unavailable'
  end
  local runtime = Runtime[source]
  local matches = runtime
    and runtime.sessionId == tostring(identity.sessionId)
    and runtime.accountId == tonumber(identity.accountId)
    and runtime.characterId == tonumber(identity.characterId)
  if not matches then
    cleanupRuntime(source, runtime and 'identity_replaced' or 'character_bound')
    if not create then return nil, 'session_mismatch' end
    runtime = newRuntime(source, identity, current)
  end
  return runtime
end

local function dueTicks(runtime, accumulatorName, elapsed, intervalMs, maximum)
  intervalMs = math.max(1000, math.floor(tonumber(intervalMs) or 60000))
  maximum = math.max(1, math.floor(tonumber(maximum) or 1))
  local accumulated = math.max(0, tonumber(runtime[accumulatorName]) or 0) + math.max(0, elapsed)
  local raw = math.floor(accumulated / intervalMs)
  local due = math.min(raw, maximum)
  if raw > maximum then
    runtime[accumulatorName] = accumulated % intervalMs
  else
    runtime[accumulatorName] = accumulated - (due * intervalMs)
  end
  return due
end

local function applyPatch(source, patch, reason, extra)
  local context = type(extra) == 'table' and clone(extra) or {}
  context.reason = reason
  local ok, result = coreCall('ApplyStatusPatch', source, patch, context)
  if not ok then
    logLimited(source, 'mutation_failed', ('operation=%s code=%s'):format(reason, tostring(result and result.code)))
  end
  return ok, result
end

function MZStatusService.restoreSurvivalStatus(source, context)
  if type(GetInvokingResource) ~= 'function' or GetInvokingResource() ~= 'mz_admin' then
    return false, { code = 'not_authorized' }
  end
  source = positiveInteger(source)
  if not source then return false, { code = 'invalid_source' } end
  local state, stateErr = getState(source)
  if not state then return false, { code = stateErr or 'player_not_loaded' } end
  if tostring(state.deathState or 'alive') ~= 'alive' then
    return false, { code = 'invalid_state' }
  end
  context = type(context) == 'table' and context or {}
  return applyPatch(source, { hunger = 100, thirst = 100 }, 'admin_heal', {
    actorSource = tonumber(context.actorSource)
  })
end

exports('RestoreSurvivalStatus', function(source, context)
  return MZStatusService.restoreSurvivalStatus(source, context)
end)

local function applyCriticalDamage(source, cause, amount, shouldLog)
  local ok, result = coreCall('ApplyPlayerHealthDamage', source, amount, {
    reason = 'survival_damage',
    cause = cause
  })
  local applied = ok == true or (type(result) == 'table' and result.code == 'persistence_pending' and result.changed == true)
  if applied then
    if shouldLog == true then
      print(('[mz_status][critical_damage] source=%s cause=%s amount=%s deathState=%s persistence=%s'):format(
        tostring(source), tostring(cause), tostring(amount),
        tostring(result and result.state and result.state.deathState or 'unknown'),
        tostring(ok and 'normal' or 'pending')
      ))
      telemetry('status_critical_damage', {
        source = source, reason = cause, result = ok and 'applied' or 'persistence_pending',
        revision = result and result.revision,
        nextState = result and result.state and result.state.deathState,
        evidence = { amount = amount }
      })
    end
  else
    logLimited(source, 'critical_damage_failed', ('cause=%s code=%s'):format(cause, tostring(result and result.code)))
  end
  return applied, result
end

local function processCritical(source, runtime, state, elapsed, previousStatus)
  local cfg = statusConfig().critical or {}
  if cfg.damageEnabled == false then return end
  local maxTicks = tonumber(cfg.maxCatchUpTicks) or 1
  local hungerCfg = cfg.hunger or {}
  local thirstCfg = cfg.thirst or {}
  local hungerZero = tonumber(state.status.hunger) <= (tonumber(hungerCfg.threshold) or 0)
  local thirstZero = tonumber(state.status.thirst) <= (tonumber(thirstCfg.threshold) or 0)
  if not hungerZero then runtime.criticalHungerAccumulator = 0 end
  if not thirstZero then runtime.criticalThirstAccumulator = 0 end
  if previousStatus and tonumber(previousStatus.hunger) > 0 and hungerZero then runtime.criticalHungerAccumulator = 0 end
  if previousStatus and tonumber(previousStatus.thirst) > 0 and thirstZero then runtime.criticalThirstAccumulator = 0 end
  local hungerDue = hungerZero and dueTicks(runtime, 'criticalHungerAccumulator', elapsed,
    hungerCfg.damageIntervalMs, maxTicks) or 0
  local thirstDue = thirstZero and dueTicks(runtime, 'criticalThirstAccumulator', elapsed,
    thirstCfg.damageIntervalMs, maxTicks) or 0
  if hungerDue <= 0 and thirstDue <= 0 then return end
  local cause, amount
  if hungerDue > 0 and thirstDue > 0 then
    cause = 'hunger_thirst'
    amount = math.max(tonumber(hungerCfg.damageAmount) or 0, tonumber(thirstCfg.damageAmount) or 0)
  elseif hungerDue > 0 then
    cause, amount = 'hunger', tonumber(hungerCfg.damageAmount) or 0
  else
    cause, amount = 'thirst', tonumber(thirstCfg.damageAmount) or 0
  end
  if amount > 0 then applyCriticalDamage(source, cause, math.floor(amount), true) end
end

function MZStatusService.processPlayer(source, current, resolvedIdentity)
  source = tonumber(source)
  current = tonumber(current) or nowMs()
  local runtime, runtimeErr = runtimeFor(source, current, true, resolvedIdentity)
  if not runtime then return false, runtimeErr end
  local state, stateErr = getState(source)
  if not state then
    cleanupRuntime(source, stateErr or 'player_not_loaded')
    return false, stateErr or 'player_not_loaded'
  end
  if runtime.statusLoaded ~= true then
    runtime.statusLoaded = true
    debugLog(('statusLoaded characterId=%s'):format(tostring(runtime.characterId)))
  end
  local elapsed = current - (tonumber(runtime.lastTickAt) or current)
  runtime.lastTickAt = current
  if elapsed < 0 then elapsed = 0 end
  local scheduler = statusConfig().scheduler or {}
  elapsed = math.min(elapsed, math.max(1000, tonumber(scheduler.maxElapsedMs) or 15000))
  if tostring(state.deathState or 'alive') ~= 'alive' then
    runtime.hungerAccumulator, runtime.thirstAccumulator, runtime.stressAccumulator = 0, 0, 0
    runtime.criticalHungerAccumulator, runtime.criticalThirstAccumulator = 0, 0
    return true, 'paused'
  end

  local previousStatus = clone(state.status)
  local patch = {}
  local maxCatchUp = tonumber(scheduler.maxCatchUpTicks) or 2
  local hunger = statusConfig().hunger or {}
  local thirst = statusConfig().thirst or {}
  if hunger.enabled ~= false then
    local ticks = dueTicks(runtime, 'hungerAccumulator', elapsed, hunger.decayIntervalMs, maxCatchUp)
    if ticks > 0 then patch.hunger = -(math.max(0, tonumber(hunger.decayAmount) or 1) * ticks) end
  end
  if thirst.enabled ~= false then
    local ticks = dueTicks(runtime, 'thirstAccumulator', elapsed, thirst.decayIntervalMs, maxCatchUp)
    if ticks > 0 then patch.thirst = -(math.max(0, tonumber(thirst.decayAmount) or 1) * ticks) end
  end
  local passive = statusConfig().stress and statusConfig().stress.passiveReduction or {}
  if statusConfig().stress and statusConfig().stress.enabled ~= false and passive.enabled ~= false
    and current - (runtime.lastActivityAt or current) >= (tonumber(passive.delayAfterActivityMs) or 60000) then
    local ticks = dueTicks(runtime, 'stressAccumulator', elapsed, passive.intervalMs, maxCatchUp)
    if ticks > 0 then patch.stress = -(math.max(0, tonumber(passive.amount) or 1) * ticks) end
  else
    runtime.stressAccumulator = 0
  end

  if next(patch) then
    local ok, result = applyPatch(source, patch, 'survival_tick')
    if ok and type(result) == 'table' and type(result.state) == 'table' then state = result.state end
  end
  processCritical(source, runtime, state, elapsed, previousStatus)
  return true
end

function MZStatusService.runSchedulerPass(current, sources)
  local succeeded, failed, skipped = 0, 0, 0
  for _, source in ipairs(sources or {}) do
    local identity, identityErr, identityDetail = resolveActiveIdentity(tonumber(source))
    if not identity then
      cleanupRuntime(tonumber(source), identityErr or 'character_unavailable')
      logCharacterUnavailable(source, identityErr, identityDetail)
      skipped = skipped + 1
    else
      local ok, result, detail = xpcall(function()
        return MZStatusService.processPlayer(tonumber(source), current, identity)
      end, debug.traceback)
      if ok and result ~= false then
        succeeded = succeeded + 1
      else
        failed = failed + 1
        logLimited(source, 'scheduler_player_failed', tostring(ok and detail or result))
      end
    end
  end
  metric('status_ticks_total', succeeded)
  return succeeded, failed, skipped
end

local function consumeActivityAttempt(runtime, current)
  local cfg = statusConfig().activity or {}
  local windowMs = math.max(1000, tonumber(cfg.windowMs) or 10000)
  if current - runtime.activityWindow.startedAt >= windowMs then
    runtime.activityWindow = { startedAt = current, count = 0 }
  end
  runtime.activityWindow.count = runtime.activityWindow.count + 1
  return runtime.activityWindow.count <= math.max(1, tonumber(cfg.maxAttemptsPerWindow) or 20)
end

local function validateActivityPayload(payload)
  if type(payload) ~= 'table' then return nil, 'invalid_payload' end
  local count = 0
  for key in pairs(payload) do
    count = count + 1
    if key ~= 'type' or count > 1 then return nil, 'unknown_field' end
  end
  if count ~= 1 or type(payload.type) ~= 'string' or ACTIVITY_TYPES[payload.type] ~= true then
    return nil, 'invalid_type'
  end
  return payload.type
end

local function confirmHighSpeed(source)
  if type(GetPlayerPed) ~= 'function' or type(GetVehiclePedIsIn) ~= 'function' or type(GetEntitySpeed) ~= 'function' then
    return true
  end
  local ped = GetPlayerPed(source)
  if not ped or ped == 0 then return false end
  local vehicle = GetVehiclePedIsIn(ped, false)
  if not vehicle or vehicle == 0 then return false end
  if type(GetPedInVehicleSeat) == 'function' and GetPedInVehicleSeat(vehicle, -1) ~= ped then return false end
  local threshold = tonumber(statusConfig().stress and statusConfig().stress.highSpeed
    and statusConfig().stress.highSpeed.thresholdKmh) or 160
  return (tonumber(GetEntitySpeed(vehicle)) or 0) * 3.6 >= threshold
end

local function confirmShot(source)
  local ok, equipped = pcall(function() return exports['mz_inventory']:GetEquippedWeaponState(source) end)
  return ok and type(equipped) == 'table' and equipped.equipped == true
end

function MZStatusService.handleActivityCandidate(source, payload)
  source = tonumber(source)
  local current = nowMs()
  local runtime, runtimeErr = runtimeFor(source, current, true)
  if not runtime then return false, runtimeErr end
  if not consumeActivityAttempt(runtime, current) then
    logLimited(source, 'activity_rate_limit', 'attempt window exceeded')
    telemetry('status_activity_rejected', { source = source, reason = 'rate_limited', result = 'rejected' })
    pcall(function()
      exports['mz_core']:ReportPlayerStateSuspicion('status_activity_rate_limited', source, {
        reason = 'activity candidate flood', error = 'rate_limited'
      })
    end)
    return false, 'rate_limited'
  end
  local activityType, payloadErr = validateActivityPayload(payload)
  if not activityType then
    logLimited(source, 'activity_rejected', payloadErr)
    telemetry('status_activity_rejected', { source = source, reason = payloadErr, result = 'rejected' })
    return false, payloadErr
  end
  local state, stateErr = getState(source)
  if not state or tostring(state.deathState) ~= 'alive' then return false, stateErr or 'invalid_state' end
  local cooldownMs, stressAmount = 0, 0
  if activityType == 'shot_fired' then
    local cfg = statusConfig().stress and statusConfig().stress.shot or {}
    if cfg.enabled == false then return false, 'feature_disabled' end
    if not confirmShot(source) then return false, 'activity_unconfirmed' end
    cooldownMs, stressAmount = tonumber(cfg.cooldownMs) or 5000, tonumber(cfg.amount) or 3
  elseif activityType == 'high_speed' then
    local cfg = statusConfig().stress and statusConfig().stress.highSpeed or {}
    if cfg.enabled == false or not confirmHighSpeed(source) then return false, 'activity_unconfirmed' end
    cooldownMs, stressAmount = tonumber(cfg.cooldownMs) or 15000, tonumber(cfg.amount) or 2
  else
    local cfg = statusConfig().activity and statusConfig().activity.vehicleImpact or {}
    if cfg.enabled == false then return false, 'feature_disabled' end
    cooldownMs = tonumber(cfg.cooldownMs) or 3000
    local damage = activityType == 'vehicle_impact_belted'
      and (tonumber(cfg.beltedDamage) or 6) or (tonumber(cfg.unbeltedDamage) or 15)
    if runtime.activityCooldowns.vehicle_impact and current < runtime.activityCooldowns.vehicle_impact then
      return false, 'cooldown'
    end
    runtime.activityCooldowns.vehicle_impact = current + cooldownMs
    runtime.lastActivityAt = current
    return applyCriticalDamage(source, activityType, math.floor(damage), false)
  end
  if runtime.activityCooldowns[activityType] and current < runtime.activityCooldowns[activityType] then
    return false, 'cooldown'
  end
  runtime.activityCooldowns[activityType] = current + cooldownMs
  runtime.lastActivityAt = current
  return applyPatch(source, { stress = math.floor(stressAmount) }, 'stress_activity', { cause = activityType })
end

local function cleanupCompleted(runtime, current)
  local retention = tonumber(statusConfig().consumption and statusConfig().consumption.completedRetentionMs) or 60000
  for operationId, entry in pairs(runtime.completedOperations) do
    if current - (entry.completedAt or current) > retention then runtime.completedOperations[operationId] = nil end
  end
end

local function operationId(source, sessionId)
  operationSequence = operationSequence + 1
  return ('MZS-%s-%s-%s-%s'):format(tostring(source), tostring(sessionId), tostring(nowMs()), tostring(operationSequence))
end

local function canBenefit(state, definition)
  if definition.status then return tonumber(state.status[definition.status]) < 100 end
  if definition.healing then return tonumber(state.status.health) < 200 end
  return false
end

local function commitConsumable(source, id)
  local current = nowMs()
  local runtime, runtimeErr = runtimeFor(source, current, false)
  if not runtime then return false, runtimeErr or 'player_not_loaded' end
  cleanupCompleted(runtime, current)
  if runtime.completedOperations[id] then return true, clone(runtime.completedOperations[id].result) end
  local operation = runtime.activeOperation
  if not operation or operation.id ~= id then return false, 'operation_not_active' end
  if runtime.sessionId ~= operation.sessionId
    or runtime.accountId ~= operation.accountId
    or runtime.characterId ~= operation.characterId then
    runtime.activeOperation = nil
    return false, 'session_mismatch'
  end
  if current - operation.startedAt > (tonumber(statusConfig().consumption.operationTimeoutMs) or 10000) then
    runtime.activeOperation = nil
    return false, 'operation_timeout'
  end
  local definition = Config.Consumables[operation.item]
  local ok, result
  if definition.status then
    ok, result = coreCall('ApplyStatusPatch', source, { [definition.status] = definition.amount }, {
      reason = 'consumable', item = operation.item, operationId = id
    })
  else
    ok, result = coreCall('ApplyPlayerHealing', source, definition.healing, {
      reason = 'basic_bandage', item = operation.item, operationId = id
    })
  end
  local applied = ok == true or (type(result) == 'table' and result.code == 'persistence_pending' and result.changed == true)
  if not applied then
    runtime.activeOperation = nil
    logLimited(source, 'consumable_effect_failed', ('item=%s operation=%s code=%s'):format(
      operation.item, id, tostring(result and result.code)
    ))
    return false, result and result.code or 'effect_failed'
  end
  local completion = {
    operationId = id,
    item = operation.item,
    category = definition.category,
    revision = result and result.revision,
    persistencePending = ok ~= true
  }
  runtime.activeOperation = nil
  runtime.consumptionCooldownUntil = current + (tonumber(statusConfig().consumption.globalCooldownMs) or 1000)
  runtime.categoryCooldowns[definition.category] = current + (tonumber(definition.cooldownMs) or 3000)
  runtime.completedOperations[id] = { completedAt = current, result = clone(completion) }
  telemetry('status_consumable_completed', {
    operationId = id, source = source, revision = completion.revision,
    reason = operation.item, result = completion.persistencePending and 'persistence_pending' or 'completed'
  })
  TriggerClientEvent(PRESENTATION_EVENT, source, {
    operationId = id,
    item = operation.item,
    label = definition.label,
    category = definition.category,
    durationMs = definition.presentationMs,
    emote = definition.emote,
    animation = definition.animation
  })
  return true, completion
end

local function abortConsumable(source, id, reason)
  local runtime = Runtime[tonumber(source)]
  if runtime and runtime.activeOperation and runtime.activeOperation.id == id then
    local item = runtime.activeOperation.item
    runtime.activeOperation = nil
    logLimited(source, 'consumable_aborted', ('operation=%s reason=%s'):format(id, tostring(reason)))
    telemetry('status_consumable_rollback', {
      operationId = id, source = source, reason = tostring(reason), result = 'aborted',
      evidence = { item = item }
    })
    return true
  end
  return false
end

function MZStatusService.prepareConsumable(payload)
  if statusConfig().enabled == false then return { ok = false, error = 'feature_disabled' } end
  if type(payload) ~= 'table' or type(payload.item) ~= 'string' then
    return { ok = false, error = 'invalid_consumable_payload' }
  end
  local definition = Config.Consumables and Config.Consumables[payload.item]
  if type(definition) ~= 'table' then
    logLimited(payload.source, 'unknown_consumable', tostring(payload.item))
    return { ok = false, error = 'unknown_consumable' }
  end
  local source = tonumber(payload.source)
  local current = nowMs()
  local runtime, runtimeErr = runtimeFor(source, current, true)
  if not runtime then return { ok = false, error = runtimeErr } end
  local state, stateErr = getState(source)
  if not state then
    cleanupRuntime(source, stateErr or 'player_not_loaded')
    return { ok = false, error = stateErr or 'player_not_loaded' }
  end
  if tostring(state.deathState) ~= 'alive' then return { ok = false, error = 'invalid_state' } end
  local actionOk, action = coreCall('CanPlayerPerformAction', source, 'inventory.use')
  if not actionOk or type(action) ~= 'table' or action.allowed ~= true then
    return { ok = false, error = 'player_state_blocked' }
  end
  if not canBenefit(state, definition) then return { ok = false, error = 'no_benefit' } end
  cleanupCompleted(runtime, current)
  if runtime.activeOperation then
    if current - runtime.activeOperation.startedAt <= (tonumber(statusConfig().consumption.operationTimeoutMs) or 10000) then
      return { ok = false, error = 'operation_active' }
    end
    runtime.activeOperation = nil
  end
  if current < (runtime.consumptionCooldownUntil or 0)
    or current < (runtime.categoryCooldowns[definition.category] or 0) then
    return { ok = false, error = 'cooldown' }
  end
  local id = operationId(source, runtime.sessionId)
  runtime.activeOperation = {
    id = id,
    source = source,
    sessionId = runtime.sessionId,
    accountId = runtime.accountId,
    characterId = runtime.characterId,
    item = payload.item,
    slot = tonumber(payload.slot),
    startedAt = current
  }
  telemetry('status_consumable_started', {
    operationId = id, source = source, reason = payload.item, result = 'reserved'
  })
  return {
    ok = true,
    consume = true,
    amount = 1,
    operationId = id,
    data = { operationId = id, category = definition.category },
    afterCommit = function() return commitConsumable(source, id) end,
    onAbort = function(reason) return abortConsumable(source, id, reason) end
  }
end

function MZStatusService.registerConsumables()
  local registered, failed = 0, 0
  for itemName in pairs(Config.Consumables or {}) do
    local ok, result, resultErr = pcall(function()
      return exports['mz_inventory']:RegisterItemUseHandler(itemName, function(payload)
        return MZStatusService.prepareConsumable(payload)
      end)
    end)
    if ok and result == true then
      registered = registered + 1
    else
      failed = failed + 1
      print(('[mz_status][consumable_registration_failed] item=%s error=%s'):format(
        tostring(itemName), tostring(ok and resultErr or result):sub(1, 240)
      ))
    end
  end
  print(('[mz_status][consumables_registered] registered=%s failed=%s'):format(registered, failed))
  return failed == 0, registered, failed
end

if type(RegisterCommand) == 'function' then
  RegisterCommand('mz_status_diag', function(source, args)
    if tonumber(source) ~= 0 then return end
    local target = tonumber(type(args) == 'table' and args[1] or nil)
    if not target or target <= 0 or not GetPlayerName(target) then
      print('[mz_status][diag] uso: mz_status_diag <source>')
      return
    end
    local state, stateErr = getState(target)
    local identity, identityErr, identityDetail = resolveActiveIdentity(target)
    print(('[mz_status][diag] source=%s state_ok=%s state_error=%s revision=%s identity_ok=%s identity_error=%s characterId=%s sessionId=%s lifecycle=%s'):format(
      tostring(target), tostring(state ~= nil), tostring(stateErr or 'none'),
      tostring(state and state.revision or 'none'), tostring(identity ~= nil), tostring(identityErr or 'none'),
      tostring(identity and identity.characterId or 'none'), tostring(identity and identity.sessionId or 'none'),
      tostring(identity and identity.lifecycle or identityDetail and identityDetail.lifecycle or 'UNKNOWN')
    ))
  end, false)
end

AddEventHandler('mz_core:server:playerVitalChangedInternal', function(source, payload)
  if type(payload) ~= 'table' or payload.kind ~= 'damage' or payload.fatal == true then return end
  local runtime = runtimeFor(source, nowMs(), true)
  if not runtime then return end
  local state, stateErr = getState(source)
  if not state then
    cleanupRuntime(source, stateErr or 'player_not_loaded')
    return
  end
  if tostring(state.deathState) ~= 'alive' then return end
  local cfg = statusConfig().stress and statusConfig().stress.damage or {}
  local amount = tonumber(cfg.baseAmount) or 3
  amount = amount + math.floor((tonumber(payload.healthDelta) or 0) / math.max(1, tonumber(cfg.healthStep) or 25))
  amount = amount + math.floor((tonumber(payload.armorDelta) or 0) / math.max(1, tonumber(cfg.armorStep) or 25))
  amount = math.min(math.max(0, tonumber(cfg.maximumAmount) or 10), amount)
  runtime.lastActivityAt = nowMs()
  if amount > 0 then applyPatch(source, { stress = math.floor(amount) }, 'stress_from_damage', { cause = payload.cause }) end
end)

RegisterNetEvent(ACTIVITY_EVENT, function(payload)
  MZStatusService.handleActivityCandidate(source, payload)
end)

AddEventHandler('playerDropped', function()
  local sourceId = tonumber(source)
  cleanupRuntime(sourceId, 'player_dropped')
  UnavailableBySource[sourceId] = nil
  LogAtBySource[sourceId] = nil
end)

AddEventHandler('mz_core:server:identitySessionClosed', function(sourceId)
  sourceId = tonumber(sourceId)
  cleanupRuntime(sourceId, 'identity_session_closed')
  UnavailableBySource[sourceId] = nil
  LogAtBySource[sourceId] = nil
end)

AddEventHandler('onResourceStart', function(resourceName)
  if resourceName ~= GetCurrentResourceName() and resourceName ~= 'mz_core' then return end
  SetTimeout(resourceName == 'mz_core' and 1000 or 0, function()
    stopping = false
    MZStatusService.registerConsumables()
    local current = nowMs()
    local recovered = 0
    for _, source in ipairs(GetPlayers()) do
      if MZStatusService.processPlayer(tonumber(source), current) then recovered = recovered + 1 end
    end
    print(('[mz_status][runtime_rebuilt] players=%s offline_catchup=false'):format(recovered))
  end)
end)

AddEventHandler('onResourceStop', function(resourceName)
  if resourceName ~= GetCurrentResourceName() then return end
  stopping = true
  local sources = {}
  for source in pairs(Runtime) do sources[#sources + 1] = source end
  for _, source in ipairs(sources) do
    local runtime = Runtime[source]
    local identity = resolveActiveIdentity(source)
    if runtime and identity and identity.sessionId == runtime.sessionId
      and identity.accountId == runtime.accountId and identity.characterId == runtime.characterId then
      local saved = coreCall('FlushPlayerState', source, 'mz_status_resource_stop', true)
      if saved == true then
        debugLog(('statusSaved characterId=%s'):format(tostring(runtime.characterId)))
      end
    end
    cleanupRuntime(source, 'resource_stop')
  end
  UnavailableBySource = {}
  LogAtBySource = {}
  print('[mz_status][scheduler_stopped] runtime_cleared=true persistence=core_owned')
end)

if type(CreateThread) == 'function' and rawget(_G, 'MZ_STATUS_TESTING') ~= true then
  CreateThread(function()
    schedulerRunning = true
    print('[mz_status][scheduler_started] mode=global')
    while not stopping do
      Wait(math.max(1000, tonumber(statusConfig().scheduler and statusConfig().scheduler.intervalMs) or 5000))
      if statusConfig().enabled ~= false then
        MZStatusService.runSchedulerPass(nowMs(), GetPlayers())
      end
    end
    schedulerRunning = false
  end)
end

if rawget(_G, 'MZ_STATUS_TESTING') == true then
  MZStatusService._test = {
    runtime = Runtime,
    unavailable = UnavailableBySource,
    logAt = function() return LogAtBySource end,
    newRuntime = newRuntime,
    runtimeFor = runtimeFor,
    resolveActiveIdentity = resolveActiveIdentity,
    cleanupRuntime = cleanupRuntime,
    dueTicks = dueTicks,
    validateActivityPayload = validateActivityPayload,
    commitConsumable = commitConsumable,
    events = { activity = ACTIVITY_EVENT, presentation = PRESENTATION_EVENT },
    schedulerRunning = function() return schedulerRunning end
  }
end
