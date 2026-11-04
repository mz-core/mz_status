# Player Status e sobrevivência — Lote 4

## Arquitetura e responsabilidades

`mz_core` permanece como fonte única de `hunger`, `thirst`, `stress`, `health`, `armor`, `deathState`, `revision`, dirty tracking, persistência, state bags e sync. `mz_status` produz mudanças autorizadas e guarda apenas acumuladores, cooldowns e operações da sessão. O inventário do core valida posse/slot/quantidade, serializa por container e remove em transação. `mz_hud` somente projeta o snapshot revisionado e alerta.

Não há metadata paralela, SQL, flush ou defaults persistidos em `mz_status`. A ordem no starter é `mz_core` → `mz_inventory` → `mz_status` → demais consumers; o resource também registra novamente os handlers se `mz_core` reiniciar.

## Identidade multichar

Status persistente é `CHARACTER`-scoped. `mz_status` aceita trabalho somente quando `GetPlayerSession(source)` e `ResolvePlayerIdentity(source)` concordam sobre `sessionId`, `accountId` e o `active_character_id` numérico, com lifecycle `CHARACTER_ACTIVE`. `source` é apenas o endereço runtime; `citizenid` não é consultado nem armazenado pelo resource.

O runtime efêmero fica vinculado ao quarteto `source + sessionId + accountId + characterId`. Qualquer divergência limpa acumuladores, cooldowns e operações antes de falhar fechado. `playerDropped`, fechamento canônico da sessão e stop do resource também removem o binding. Durante `CONNECTED`, `ACCOUNT_RESOLVED`, `CHARACTER_SELECTION` e `CHARACTER_ACTIVATING`, não há leitura de status nem publicação adicional para o HUD.

Os valores continuam dentro do snapshot do personagem ativo mantido pelo core. Assim, o carregamento de `mz_players` por `character_id`, dirty tracking, sync revisionado e persistência permanecem em um único owner; criar uma tabela paralela de status produziria dual write. No stop de `mz_status`, bindings que ainda correspondem à identidade ativa solicitam um flush explícito ao core antes do cleanup.

## Scheduler e tempo

Existe uma thread global server-side. A cada 5 s ela percorre `GetPlayers()`, ignora conexões que ainda não possuem character ativo, pede snapshot e sessão ao core para as demais, captura falha por jogador e calcula elapsed por `GetGameTimer()`. O elapsed é limitado a 15 s e cada acumulador aceita no máximo dois períodos por passe. Não existe thread por source e `CHARACTER_SELECTION` nunca cria runtime de status.

O runtime contém apenas sessionId, accountId, characterId, lifecycle, relógio, acumuladores de hunger/thirst/stress/crítico, atividade, cooldowns e operações. Troca de sessão, account ou personagem substitui o runtime. `downed`, `dead` e `respawning` pausam decay, redução passiva, dano crítico e consumo. Player ausente/loading/unloading é ignorado. Restart reconstrói o runtime no horário atual, sem catch-up offline.

## Configuração padrão

| Regra | Default |
| --- | --- |
| scheduler | 5 s; elapsed máximo 15 s; catch-up 2 |
| hunger | -1 a cada 90 s |
| thirst | -1 a cada 60 s |
| stress passivo | -1 a cada 30 s, após 60 s sem atividade |
| fome zero | 5 de dano a cada 15 s |
| sede zero | 7 de dano a cada 10 s |
| catch-up crítico | 1 dano por passe |
| duas causas críticas | `largest_damage_wins` |
| tiro | +3 stress; cooldown 5 s |
| alta velocidade | +2 stress; ≥160 km/h; cooldown 15 s |
| impacto com/sem cinto | dano fixo 6/15; cooldown 3 s |
| consumo | cooldown global 1 s; timeout 10 s; idempotência 60 s |

Todos os números de gameplay ficam em `mz_status/config.lua`. Valores inválidos recebem mínimos/fallbacks defensivos; o clamp final pertence ao core.

## Fome, sede e persistência agrupada

O scheduler envia um único `ApplyStatusPatch(source, deltas, context)`. O schema aceita somente `hunger`, `thirst` e `stress`, no máximo três campos finitos. A operação ocorre sob o lock e produz uma revision, um dirty merge e um sync mesmo quando os três mudam juntos. Mudanças comuns não fazem flush; dirty/debounce do Lote 2 persiste os campos.

## Stress

- dano real não fatal aceito pelo core emite `mz_core:server:playerVitalChangedInternal`, que não é net event;
- o ganho é calculado server-side por faixas e limitado a 10;
- tiro só é aceito quando o inventário confirma arma equipada;
- alta velocidade usa source implícito, faixa fixa, cooldown e confirmação server-side de ped/veículo/velocidade/condutor quando possível;
- impacto do HUD usa candidato fechado e só pode danificar o próprio source;
- atividade recente pausa a redução passiva.

O único payload client → server é `{ type = '<allowlisted>' }`. Amount, target e campos extras são recusados e contam na janela de 20 tentativas/10 s.

## Dano crítico e cura

`ApplyPlayerHealthDamage` aceita somente amount positivo de `damageWriters`. Em `alive`, reduz health sob lock. Fatal atualiza health, flags, timestamp e `deathState` na mesma seção: `alive → downed` com last stand, senão `alive → dead`. Não existe janela `health=0/alive`. Fatal usa flush crítico; `persistence_pending` preserva `changed=true`.

Fome e sede têm timers separados. Se ambos vencem no mesmo passe, uma chamada usa o maior dano (7 por padrão); não somam. Acima do threshold, o acumulador da causa é zerado.

`ApplyPlayerHealing` é distinta: somente amount positivo de `healingWriters`, apenas `alive`, clamp no máximo, sem alterar death state ou reviver. Bandagem usa essa API.

## Catálogo real de itens

| ID | Definição local | Efeito server-side | Cooldown | Apresentação |
| --- | --- | --- | --- | --- |
| `water` | Água; 500 g; stack; sem metadata; `water.png` | thirst +25 | 3 s | 2,5 s/emote `beber7` |
| `bread` | Pão; 300 g; stack; sem metadata; `sandwich.png` | hunger +20 | 3 s | 2,5 s/emote `comer` |
| `bandage` | Bandagem; 250 g; stack; sem metadata; `bandage.png` | health +15 | 5 s | 3 s/notificação |

Os IDs vêm de `mz_inventory/shared/items.lua`. `bread.png` não existia e a definição foi corrigida para o asset local `sandwich.png`. Antes, `water` era removida sem efeito e `bread`/`bandage` não tinham handler. O client nunca envia efeito ou amount.

A bridge QB existente mantém apenas wrappers `AddItem`/`RemoveItem` para o inventário oficial. Não foram encontrados consumers ativos de `hud:server:RelieveStress`, `consumables:server:addHunger`, `consumables:server:addThirst` ou `hospital:server:UseBandage`; por isso nenhum alias inseguro foi criado.

## Integração e atomicidade do inventário

```text
callback de uso existente (slot)
→ guard CanPlayerPerformAction('inventory.use')
→ inventário resolve row real sob lock
→ mz_status valida alive, benefício, sessão, cooldown e operação ativa
→ transação remove uma unidade
→ hook pós-commit aplica efeito canônico
→ sucesso confirma operationId e apresenta
→ falha de efeito executa compensação ainda sob o lock
```

Stack parcial restaura amount; row removida restaura slot, item, amount, metadata e instance_uid. Falha da remoção chama `onAbort`, limpa a operação e não executa efeito. Falha de rollback retorna `inventory_rollback_failed`. O hook pós-commit não falha silenciosamente.

Há uma operação ativa por sessão e completed cache de 60 s. Retry do mesmo ID não reaplica. Source reutilizado e timeout recusam conclusão. `persistence_pending` com `changed=true` conta como efeito aplicado e não devolve item.

Não se promete transação distribuída entre banco e cache: a garantia é remoção transacional + efeito síncrono + compensação. Crash exatamente entre efeito e confirmação é risco residual.

## Apresentação e HUD

Após confirmação, `mz_status:client:consumablePresented` envia só operationId, item, label, category, durationMs, emote e animation. O client apresenta; conclusão client não concede efeito.

A apresentação reaproveita o catálogo do `mz_animations` quando o resource está iniciado (`emote = 'beber7'` para água e `emote = 'comer'` para pão, incluindo o prop preso à mão). Se `mz_animations` não estiver disponível, o client usa o fallback local `animation` da configuração. Nenhuma apresentação é iniciada dentro de veículo: cenários `in place` ejetavam o jogador do carro e podiam derrubá-lo do mapa. Se o jogador entrar em veículo, morrer ou entrar em ragdoll durante a janela, a animação/prop é encerrada imediatamente.

O HUD consome `mz_core:client:playerStateSync`, usa hunger/thirst/stress/health/armor e descarta revision menor ou igual. O adapter legado só vale antes do primeiro snapshot. Alertas disparam ao entrar em hunger ≤20, thirst ≤20 ou stress ≥80, têm cooldown de 60 s, rearmam ao sair e são suprimidos fora de `alive`. Não há tick, setter ou persistência no HUD.

O `SetEntityHealth` de colisão foi removido. O HUD mantém cálculo/ejeção visual, mas envia somente candidato local sem amount; `mz_status` aplica dano fixo do próprio source pela API canônica.

## Eventos

| Evento | Direção | Payload | Autoridade |
| --- | --- | --- | --- |
| `mz_status:server:reportActivityCandidate` | client → server | somente `{type}` | candidato; source implícito; rate/cooldown/validação |
| `mz_status:client:consumablePresented` | server → client | operationId, item, label, category, durationMs, emote, animation | apresentação sem efeito |
| `mz_status:client:reportVehicleImpact` | client local | boolean de cinto vindo do HUD | traduz para candidato fechado |
| `mz_core:server:playerVitalChangedInternal` | server interno | deltas aceitos/cause/fatal/deathState | `AddEventHandler`; nunca net |
| `mz_inventory:server:use` | client → server existente | container Character + slot | inventário valida row real |

Nenhum evento aceita target, effect, amount, status, health, deathState ou quantidade final.

## Exports e autorização

| Export do core | Schema | Writer | Retornos principais |
| --- | --- | --- | --- |
| `ApplyStatusPatch` | deltas hunger/thirst/stress | `statusWriters={'mz_status'}` | success/unchanged/not_authorized/lock/player |
| `ApplyPlayerHealthDamage` | redução positiva + contexto | `damageWriters={'mz_status'}` | success/invalid_state/pending |
| `ApplyPlayerHealing` | aumento positivo | `healingWriters={'mz_status'}` | success/no_benefit/invalid_state |

O export server-side `RestoreSurvivalStatus(source, context)` aceita apenas chamadas de `mz_admin`. Ele aplica um unico `ApplyStatusPatch` limitado pelo core para encher hunger/thirst depois de um heal administrativo autorizado; nao aceita status ou valores arbitrarios do chamador.

`mz_status` não expõe setters ou registro arbitrário. Usa o export preexistente `RegisterItemUseHandler` apenas para os três IDs estáticos.

## Logs

Com `Config.Debug=true`, transições de identidade registram `characterBound`, `statusLoaded`, `statusSaved`, `characterUnavailable` e `cleanup`, sem license ou identifier externo. Indisponibilidade repetida tem cooldown de 15 s. Há ainda logs operacionais agregados para start/stop/rebuild, falha individual do scheduler, mutation, dano crítico, candidato inválido/rate limit, handlers, abort/falha de efeito e falha/rollback do inventário. Tick, decay, sync e HUD normais não geram log.

## Restart, limites e testes

- restart `mz_status`: preserva core, descarta runtime e não faz catch-up;
- restart `mz_core`: `mz_status` tenta registrar handlers novamente; validar dependentes/reconnect em staging;
- restart `mz_inventory`: UI é consumer; a transação oficial vive no core;
- restart `mz_hud`: bootstrap lê estado local e segue por revision;
- não há progress cancelável/reserva distribuída;
- natives, ordem real, disconnect durante yield, NUI e crash no intervalo efeito/ack exigem runtime.

Harnesses: `player_state_survival_harness`, `inventory_consumable_contract_harness`, `status_service_harness` e `status_contract_harness`, além das regressões dos Lotes 2/3 e admin. Cobrem agrupamento, dirty/sync, dano/cura/fatal, scheduler/pausas/catch-up/sessão, stress/candidatos/rate/cooldown/passivo, itens/idempotência/pending, remove→efeito/rollback e HUD/revision/alertas.

## Classificação da varredura estática

Busca em Lua/JS ativos, excluindo docs, tests, backups, `ref`, `celular`, server-data e assets:

| Símbolo | Usos ativos | Classificação |
| --- | --- | --- |
| `hunger`/`thirst`/`stress` em `mz_core/config.lua`, normalizer/state service/sync e adapters client/HUD | schema, truth, sync | canônico |
| mesmos campos em `mz_status/config.lua` e `server/service.lua` | regras e chamadas às APIs fechadas | canônico (producer autorizado) |
| mesmos campos em `mz_hud/client`, `web/app`, defaults/icons/editor | reducer e apresentação | canônico read-only/apresentação |
| `SetEntityHealth` e `SetPedArmour` | somente `mz_core/client/player_state.lua` | canônico, aplicação física central |
| `AddItem`/`RemoveItem` em `mz_inventory/server/service.lua` | planos transacionais oficiais | canônico |
| `AddItem`/`RemoveItem` em `mz_core/server/bridges/qb.lua` | wrappers para o inventário oficial | compatibilidade temporária QB |
| `RegisterUsable` | nenhum uso ativo | inexistente |

Ocorrências em `tests/**` são teste; ocorrências sob backups/referências excluídas são inativas. Não restou uso ativo suspeito ou pendente de migração desses símbolos no escopo do Lote 4.

## Fora do Lote 4

Hospital, medicina avançada, revive de terceiros, timer/animação/tela/câmera de downed/morte, respawn hospitalar, lesões, sangramento, drogas, buffs e stamina persistida não foram implementados.

## Integração do Lote 5

O dano fatal produzido por `mz_status` continua passando por `ApplyPlayerHealthDamage`; o core publica a mudança interna de death state e `mz_medical` garante o deadline persistido. O scheduler de status pausa hunger/thirst/stress fora de `alive`; ele não controla timer médico, revive ou hospital.

Itens de sobrevivência continuam no fluxo transacional de consumíveis. O `firstaid` médico usa uma reserva separada no mesmo inventário oficial, vinculada à operação e sessão, para suportar progress cancelável e rollback. Não há sobreposição de handlers nem aplicação client-side de health. Contrato médico: `../../mz_medical/docs/PLAYER_MEDICAL_FLOW.md`.
