---
name: swap-behavior-analysis
description: "Analizar el comportamiento acumulativo de una wallet dentro del pool y a lo largo del tiempo, para detectar patrones que ninguna verificación puntual puede identificar. Cubre perfil conductual, anomalías estadísticas contra la distribución del pool, detección de esquemas de fraude y exit liquidity, análisis de wallets vinculadas y evaluación de la actividad DeFi previa al swap. Usar siempre que exista historial disponible de la wallet, y obligatoriamente antes de emitir un score en el tramo de bloqueo."
---

# Swap Behavior Analysis — Análisis Conductual Acumulativo

## Rol en el agente

Esta skill es el diferenciador funcional de AML Hook. Mientras
`wallet-screening` responde a la pregunta "qué es esta wallet",
`swap-behavior-analysis` responde a "cómo se comportó". Construye la película
en lugar de la fotografía.

Opera sobre la ventana histórica de la wallet y sobre la distribución
estadística del pool. No evalúa identidad: evalúa desviación respecto de un
comportamiento esperado.

---

## Inputs esperados

| Campo | Descripción |
|---|---|
| `address` | Dirección bajo análisis |
| `historial_swaps` | Serie de eventos `SwapObserved` emitidos por `afterSwap` |
| `historial_onchain` | Transacciones relevantes fuera del pool (transferencias entrantes y salientes, interacciones con protocolos) |
| `distribucion_pool` | Estadísticos del pool: mediana y percentiles de monto, frecuencia y antigüedad de wallet |
| `ventana_analisis` | Período bajo evaluación |
| `score_previo` | Último `ScoreResult` de la wallet |

---

## Paso 1: Construcción del perfil conductual

Calcular, para la ventana de análisis:

| Métrica | Definición |
|---|---|
| `antiguedad_dias` | Días desde la primera transacción registrada de la dirección |
| `swaps_totales` | Cantidad de swaps ejecutados en el pool |
| `monto_medio` / `monto_mediano` | Estadísticos de `amountSpecified` convertido a valor de referencia |
| `desvio_monto` | Dispersión de los montos. Baja dispersión con alta frecuencia es señal de automatización o fraccionamiento |
| `frecuencia_media` | Swaps por unidad de tiempo |
| `ratio_direccional` | Proporción de swaps con `zeroForOne = true` sobre el total |
| `contrapartes_distintas` | Direcciones distintas con las que interactuó fuera del pool |
| `protocolos_distintos` | Protocolos distintos con los que interactuó |
| `tiempo_retencion_medio` | Tiempo entre recepción de fondos y su movimiento posterior |

El perfil se compara contra dos referencias: el histórico de la propia
wallet y la distribución del pool. Una desviación respecto de la propia
historia es más significativa que una desviación respecto de la mediana del
pool, porque no penaliza perfiles legítimamente atípicos.

---

## Paso 2: Detección de tipologías acumulativas

Estas tipologías requieren serie temporal. Ninguna es visible en el swap
individual.

### 2.1 Structuring
N swaps en ventana T con suma acumulada por encima del umbral, sin que
ninguno individual lo supere. Es el caso de demostración primario del
producto: cien transacciones fraccionadas desde una wallet individual.

Señales complementarias que refuerzan la detección:
- Montos concentrados entre el 80% y el 99% del umbral
- Intervalos regulares o semirregulares entre operaciones
- Baja dispersión de montos
- `ratio_direccional` cercano a 1 o a 0

### 2.2 Smurfing coordinado
El mismo patrón de fraccionamiento distribuido entre múltiples wallets
vinculadas. La vinculación se establece por:
- Financiamiento común: las wallets recibieron fondos de un origen común
- Co-spending: las wallets aparecen como inputs de una misma transacción
- Sincronía temporal: actividad coordinada en ventanas estrechas
- Homogeneidad de montos entre wallets distintas

El resultado se emite como `STRUCTURING_CROSS_WALLET`, con el listado de
direcciones vinculadas y el criterio de vinculación aplicado.

### 2.3 Layering temporal
Swaps de alto valor en sucesión rápida seguidos de inactividad prolongada.
Indicador de movimiento de fondos con posterior enfriamiento.

### 2.4 Velocity spike
Volumen del período que supera en un múltiplo configurable la media
histórica de la wallet, sin correlato con un evento del pool (lanzamiento,
incentivo, cambio de liquidez) que lo explique.

---

## Paso 3: Detección de fraude y exit liquidity

El behavioral scoring no se limita al lavado clásico. Los esquemas propios
de DeFi dejan huellas medibles antes de que el daño sea total.

| Patrón | Definición operativa | FactEvent |
|---|---|---|
| **Account age vs. swap size** | Wallet de antigüedad en el percentil bajo intentando un swap de monto en el percentil alto de la distribución del pool. Una wallet legítima de ese volumen tiene historial de meses | `ACCOUNT_AGE_VS_SWAP_SIZE` |
| **Inbound-only micro-transfer cluster** | Múltiples transferencias entrantes pequeñas desde direcciones distintas, sin contrapartida saliente, en ventana corta. Preparación de wallets intermediarias para simular actividad | `INBOUND_ONLY_MICRO_CLUSTER` |
| **Velocity score** | Alta cantidad de transacciones en pocas horas donde el perfil normal implicaría días o semanas. El atacante necesita ejecutar rápido | `STRUCTURING_VELOCITY_SPIKE` |
| **Concentración de contraparte** | Interacción casi exclusiva con el protocolo objetivo y con wallets propias. Diversidad de protocolos muy por debajo de la mediana | `CONCENTRACION_CONTRAPARTE` |
| **Transferencia total inmediata** | Movimiento de más del 90% del balance inmediatamente después de recibirlo | `TRANSFERENCIA_RAPIDA_BALANCE_TOTAL` |

**Distinción respecto de los competidores estáticos.** La pregunta de un
sistema basado en listas es si la wallet figura en un registro conocido. Una
wallet nueva nunca figura, y el atacante usa una wallet fresca para cada
ataque. La pregunta de esta skill es distinta: si el comportamiento de la
wallet exhibe los patrones estadísticos de un ataque, incluso sin historial
previo de fraude.

---

## Paso 4: Análisis de la actividad DeFi previa

Clasificar la actividad on-chain previa al swap y su riesgo base.

| Tipo de actividad | Riesgo base | Observación |
|---|---|---|
| DEX (Decentralized Exchange) | Medio | Sin verificación de identidad pero trazable |
| Lending / borrowing | Medio | Riesgo alto si el colateral tiene origen opaco y el repago es inmediato |
| Liquid staking | Bajo-Medio | |
| Yield farming / provisión de liquidez | Medio | |
| Bridge entre cadenas | Medio-Alto | Dificulta la trazabilidad |
| Agregador cross-chain | Medio-Alto | |
| Mixer designado | Crítico | Override de la dimensión S |
| Otros mixers y privacy protocols | Alto | |
| NFT marketplace | Medio | Riesgo de wash trading |
| Gambling on-chain | Alto | |

### Uso normal frente a ofuscación probable

| Patrón | Uso normal | Ofuscación probable |
|---|---|---|
| DEX | Conversión de activos con volumen consistente con el perfil | Múltiples swaps en tiempo corto sin lógica económica |
| Bridge | Movimiento entre redes por yield o liquidez | Bridge inmediatamente previo al swap; múltiples bridges encadenados |
| Lending | Colateral y préstamo con actividad consistente | Préstamo contra colateral de origen opaco con repago inmediato |
| Fragmentación | No aplica | Múltiples wallets que convergen en una antes del swap |

---

## Paso 5: Evaluación de contratos no identificados

Si la wallet interactuó con contratos que el motor de analytics no atribuye:

1. Verificar el contrato en el explorador de la red
2. Determinar si el código fuente está verificado y si existen auditorías
   publicadas
3. Contrastar contra bases de incidentes (DeFiLlama Hacks DB y equivalentes)
4. Verificar si el protocolo fue explotado y si los fondos bajo análisis
   podrían provenir de la recirculación del exploit

| Hallazgo | Nivel de riesgo |
|---|---|
| Contrato verificado, protocolo auditado, sin incidentes | Bajo |
| Contrato verificado sin auditoría | Medio |
| Contrato no verificado | Alto |
| Protocolo explotado o exit scam documentado | Crítico |
| Fondos provenientes de direcciones vinculadas a un exploit | Crítico |

---

## Paso 6: Función del afterSwap

El `afterSwap` es la capa que convierte el sistema de estático a dinámico.
Sus funciones, en orden:

1. **Registro.** Emite `SwapObserved` con monto, dirección, contraparte,
   pool y bloque. Es la fuente de datos de esta skill.
2. **Actualización del perfil.** Dispara el recálculo descripto en
   `fact-scoring` sección 3.4.
3. **Verificación del destinatario.** Evalúa la wallet receptora. Si presenta
   un match de sanciones, deriva a `task-blocking-protocol`.
4. **Circuit breaker.** Si el swap fue anómalamente grande respecto de la
   liquidez del pool, emite la señal de interrupción prevista por la
   configuración del operador.
5. **Emisión de eventos.** Publica el resultado para indexación, dashboards
   y consumo por otros protocolos.

---

## Output estructurado

```json
{
  "address": "0x...",
  "ventana_analisis": {"desde": "...", "hasta": "...", "swaps_evaluados": 0},
  "perfil_conductual": {
    "antiguedad_dias": 0,
    "swaps_totales": 0,
    "monto_mediano_usd": 0.0,
    "desvio_monto": 0.0,
    "frecuencia_media_dia": 0.0,
    "ratio_direccional": 0.0,
    "contrapartes_distintas": 0,
    "protocolos_distintos": 0,
    "tiempo_retencion_medio_horas": 0.0
  },
  "desviacion": {
    "vs_historico_propio": "baja | media | alta",
    "vs_distribucion_pool": "baja | media | alta",
    "percentil_monto": 0,
    "percentil_antiguedad": 0
  },
  "tipologias_acumulativas": [
    {"tipo": "structuring | smurfing | layering | velocity-spike", "evidencia": "...", "confidence": "..."}
  ],
  "wallets_vinculadas": [
    {"address": "0x...", "criterio": "financiamiento-comun | co-spending | sincronia | homogeneidad"}
  ],
  "patrones_fraude": ["account-age-vs-size | inbound-only-cluster | velocity | concentracion-contraparte | transferencia-total"],
  "actividad_defi": [
    {"protocolo": "...", "tipo": "...", "riesgo_base": "bajo | medio | alto | crítico"}
  ],
  "contratos_no_identificados": [
    {"address": "0x...", "verificado": true, "hallazgo": "...", "nivel": "..."}
  ],
  "facts_emitidos": [
    {"fact_id": "...", "type": "...", "confidence": "...", "evidencia_onchain": {}}
  ],
  "historial_insuficiente": false,
  "siguiente_skill": "typology-detection | fact-scoring"
}
```

> Si `historial_insuficiente: true` (wallet sin actividad previa suficiente
> para construir perfil), la skill lo declara expresamente. La ausencia de
> historial no es un mitigante: es una limitación del análisis, y debe
> registrarse como tal en el expediente. Una wallet sin historial que
> intenta un swap de alto volumen genera `ACCOUNT_AGE_VS_SWAP_SIZE`, no un
> resultado limpio.
