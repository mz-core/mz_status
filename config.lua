Config = Config or {}

Config.Debug = false

Config.Status = {
  enabled = true,
  scheduler = {
    intervalMs = 5000,
    maxCatchUpTicks = 2,
    maxElapsedMs = 15000
  },
  hunger = {
    enabled = true,
    decayIntervalMs = 90000,
    decayAmount = 1,
    pauseWhenNotAlive = true
  },
  thirst = {
    enabled = true,
    decayIntervalMs = 60000,
    decayAmount = 1,
    pauseWhenNotAlive = true
  },
  stress = {
    enabled = true,
    damage = { baseAmount = 3, healthStep = 25, armorStep = 25, maximumAmount = 10 },
    shot = { enabled = true, amount = 3, cooldownMs = 5000 },
    highSpeed = { enabled = true, thresholdKmh = 160, amount = 2, cooldownMs = 15000 },
    passiveReduction = {
      enabled = true,
      delayAfterActivityMs = 60000,
      intervalMs = 30000,
      amount = 1
    }
  },
  critical = {
    damageEnabled = true,
    maxCatchUpTicks = 1,
    combinedRule = 'largest_damage_wins',
    hunger = { threshold = 0, damageIntervalMs = 15000, damageAmount = 5 },
    thirst = { threshold = 0, damageIntervalMs = 10000, damageAmount = 7 }
  },
  activity = {
    maxAttemptsPerWindow = 20,
    windowMs = 10000,
    logCooldownMs = 5000,
    vehicleImpact = {
      enabled = true,
      cooldownMs = 3000,
      beltedDamage = 6,
      unbeltedDamage = 15
    }
  },
  consumption = {
    globalCooldownMs = 1000,
    operationTimeoutMs = 10000,
    completedRetentionMs = 60000
  }
}

Config.Consumables = {
  water = {
    label = 'Água',
    category = 'drink',
    status = 'thirst',
    amount = 25,
    cooldownMs = 3000,
    presentationMs = 2500,
    -- Emote do catálogo mz_animations usado quando o resource está iniciado.
    emote = 'beber7',
    -- Fallback local (sem mz_animations). Mesmo dict/prop de /e beber7.
    animation = {
      dict = 'amb@world_human_drinking@beer@male@idle_a',
      anim = 'idle_a',
      prop = 'prop_ld_flow_bottle',
      hand = 28422,
      flag = 49
    }
  },
  bread = {
    label = 'Pão',
    category = 'food',
    status = 'hunger',
    amount = 20,
    cooldownMs = 3000,
    presentationMs = 2500,
    -- Emote do catálogo mz_animations usado quando o resource está iniciado.
    emote = 'comer',
    -- Fallback local (sem mz_animations). Mesmo dict/prop de /e comer.
    animation = {
      dict = 'amb@code_human_wander_eating_donut@male@idle_a',
      anim = 'idle_c',
      prop = 'prop_cs_burger_01',
      hand = 28422,
      flag = 49
    }
  },
  bandage = {
    label = 'Bandagem',
    category = 'medical_basic',
    healing = 15,
    cooldownMs = 5000,
    presentationMs = 3000
  }
}
