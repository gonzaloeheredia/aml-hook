---
name: wallet-screening
description: "Evaluar el riesgo AML/CFT de una dirección que participa en un swap de Uniswap v4. Cubre análisis de blockchain analytics, exposición directa e indirecta a entidades de riesgo, atribución de cluster, detección de patrones de ofuscación (mixing, bridging, chain-hopping, peeling) y clasificación del tipo de cuenta. Usar como skill de dominio primaria en todo caso: es la unidad de análisis base sobre la que se construye el perfil de la wallet."
---

# Wallet Screening — Evaluación de Riesgo de Direcciones

## Rol en el agente

Esta skill es la unidad de análisis AML/CFT (Anti-Money Laundering /
Combating the Financing of Terrorism) sobre una dirección individual. No
decide la salida del swap: evalúa, documenta y produce los `FactEvent` que
`fact-scoring` cuantifica.

Herramienta de blockchain analytics asumida disponible: Chainalysis,
Elliptic o TRM Labs. Los campos de output son equivalentes entre plataformas.
La skill debe funcionar en modo degradado cuando el proveedor comercial no
responde, apoyándose exclusivamente en el explorador y en las fuentes
públicas indexadas.

---

## Inputs esperados

| Campo | Descripción |
|---|---|
| `address` | Dirección bajo análisis |
| `rol_en_swap` | `SENDER` (evaluado en beforeSwap) o `RECIPIENT` (evaluado en afterSwap) |
| `chain_id` | Red sobre la que opera el pool |
| `pool_id` | Identificador del pool de Uniswap v4 |
| `currency_in` / `currency_out` | Direcciones de los tokens del par |
| `amount_specified` | Monto del swap tal como llega al hook |
| `resultado_analytics` | Output del motor de blockchain analytics, si está disponible |
| `score_previo` | Último `ScoreResult` de la wallet en el oracle, si existe |

---

## Paso 1: Clasificación del tipo de cuenta

Antes de cualquier análisis de riesgo, determinar qué es la dirección. La
clasificación condiciona todo lo que sigue.

| Tipo | Criterio de detección | Implicancia |
|---|---|---|
| **EOA** (Externally Owned Account) | `EXTCODESIZE == 0` | Análisis directo sobre la dirección |
| **Smart Account / Multisig** | `EXTCODESIZE > 0` y patrón de contrato compatible (Safe, ERC-4337) | Requiere verificación de controladores; ver Paso 2 |
| **Contrato de protocolo** | Dirección atribuida a un protocolo conocido | El riesgo se evalúa sobre el originador real, no sobre el router |
| **Router o agregador** | Universal Router, 1inch, CoW, etc. | La dirección no es el sujeto; recuperar el originador de `hookData` o del trace |
| **No determinado** | Sin atribución posible | Analizar como EOA y registrar la indeterminación |

**Regla crítica.** Si el `msg.sender` que llega al hook es un router o un
contrato de protocolo, la evaluación sobre esa dirección carece de valor
AML: el sistema estaría evaluando a la infraestructura y no al actor.

La resolución de este problema no corresponde a esta skill. `originator-attribution` se ejecuta antes y entrega el campo `address_a_evaluar`. Esta skill opera exclusivamente sobre esa dirección. Si la atribución no se resolvió, esta skill no se ejecuta: bajo la política restrictiva por defecto el swap ya revirtió, y no hay sujeto sobre el cual construir un perfil.

---

## Paso 2: Verificación de Smart Accounts

Los operadores institucionales no usan wallets simples. Usan Smart Accounts
multisig, donde el `msg.sender` es un contrato sin identidad propia ni
presencia en listas de sanciones. Tres modelos de verificación:

### 2.1 Verificación de controladores
Consultar los owners de la Smart Account y evaluar cada uno individualmente
contra las dimensiones S y NW. Si algún controlador presenta un match de
sanciones, la Smart Account hereda el override.

### 2.2 Verificación por threshold
Un controlador comprometido no siempre implica capacidad de ejecución.
Evaluar si el subconjunto de controladores limpios alcanza el threshold de
aprobación del multisig. Si el threshold es 3 de 5 y un único controlador
está designado, ese controlador por sí solo no puede aprobar la operación.

**Excepción obligatoria.** Esta lógica no aplica ante `OFAC_MATCH_DIRECTO`
en un controlador. La designación alcanza a las entidades en las que la
persona designada tiene participación relevante, y el análisis de control
efectivo excede lo que este módulo puede resolver de forma automatizada. El
caso se eleva a revisión humana con salida `REVERT` preventiva.

### 2.3 Pre-registro con caché
Iterar controladores en cada swap tiene costo de gas prohibitivo. Las Smart
Accounts institucionales completan una verificación previa cuyo resultado se
cachea en el oracle con vigencia limitada. Al vencer, se requiere
re-verificación. Genera el mitigante `SMART_ACCOUNT_PREREGISTRADA`.

---

## Paso 3: Análisis de exposición

Extraer del motor de analytics:

| Campo | Descripción |
|---|---|
| `risk_score` | Score de riesgo de la wallet según la plataforma (0–100) |
| `exposure_direct` | Porcentaje de fondos con exposición directa a entidades de riesgo |
| `exposure_indirect` | Exposición indirecta (contraparte de contraparte) |
| `cluster_name` | Entidad a la que se atribuye la wallet |
| `cluster_category` | Categoría de la entidad |
| `sanctions_exposure` | Exposición a direcciones en listas OFAC, ONU o UE |
| `hop_count` | Saltos entre el origen identificado y la wallet analizada |

### Categorías de entidad y riesgo base

| Categoría | Nivel de riesgo base |
|---|---|
| Exchange regulado con controles verificables | Bajo |
| Exchange sin controles / P2P no regulado | Medio-Alto |
| Mixer / Tumbler / CoinJoin | Crítico |
| Darknet market | Crítico |
| Ransomware | Crítico |
| Gambling on-chain | Medio |
| Protocolo DeFi estándar | Medio |
| Bridge cross-chain | Medio-Alto |
| Entidad designada (OFAC SDN / ONU / UE) | Crítico — override |
| Sin clasificación | Medio — requiere análisis adicional |

**Profundidad de análisis indirecto.** El default es 3 saltos. La
profundidad es un parámetro gobernable y debe justificarse bajo el EBR
(Enfoque Basado en Riesgo). Toda evaluación debe declarar la profundidad
efectivamente aplicada: un supervisor necesita saber hasta dónde se miró.

---

## Paso 4: Patrones de ofuscación

Revisar si el historial de la wallet presenta técnicas de ocultamiento del
origen de fondos.

### Mixing y CoinJoin
Participación en transacciones de mezcla. Indicador: múltiples inputs de
distintas wallets con outputs de monto homogéneo. Si el contrato involucrado
está designado, corresponde override inmediato de la dimensión S.

### Chain-hopping
Conversión rápida entre blockchains sin justificación económica. Indicador:
fondos que transitan por tres o más redes en menos de 24 horas antes del
swap.

### Peeling chains
Fondos que se dividen progresivamente en montos menores a través de wallets
intermediarias. Indicador: cadena de transacciones con reducción sucesiva de
monto hacia la wallet que ejecuta el swap.

### Layering veloz
Fondos que pasan por múltiples wallets intermediarias con menos de una hora
entre saltos. Indicador: hop count elevado con timestamps comprimidos.

### Privacy coins
Conversión hacia o desde monedas de privacidad mejorada antes del swap.
Requiere análisis del tramo previo si el activo final fue reconvertido.

### Structuring on-chain
Swaps múltiples de monto similar por debajo del umbral configurado, con
intervalos regulares o semirregulares. El análisis detallado corresponde a
`typology-detection`.

---

## Paso 5: Verificación contra fuentes públicas

Independientemente del motor comercial, verificar contra:

| Fuente | Uso |
|---|---|
| OFAC SDN List | Screening directo — ver `ofac-screening` |
| Listas ONU y UE consolidadas | Screening directo |
| Registros on-chain de direcciones sancionadas | Capa 1 del hook, sin dependencia externa en runtime |
| DeFiLlama Hacks DB | Fondos provenientes de exploits documentados |
| Forta Network | Alertas de comportamiento anómalo en tiempo real |
| EAS (Ethereum Attestation Service) | Attestations de riesgo publicadas por terceros |
| Registro de denuncias de LPs | Señal interna del protocolo |

---

## Paso 6: Emisión de FactEvents

La skill no calcula el score. Emite los `FactEvent` correspondientes al
catálogo de `fact-scoring`, cada uno con su `confidence` y su evidencia
on-chain. Reglas:

- Un hallazgo verificado en lista oficial o transacción confirmada:
  `confidence: HIGH`
- Un hallazgo derivado del motor de analytics: `confidence: MEDIUM`
- Un hallazgo inferido estadísticamente sin confirmación: `confidence: LOW`
- Todo `FactEvent` debe llevar `tx_hash` y `block_number` cuando exista un
  hecho on-chain que lo respalde

---

## Output estructurado

```json
{
  "address": "0x...",
  "rol_en_swap": "SENDER | RECIPIENT",
  "tipo_cuenta": "EOA | SMART_ACCOUNT | CONTRATO_PROTOCOLO | ROUTER | NO_DETERMINADO",
  "atribucion_originador": true,
  "smart_account": {
    "es_multisig": false,
    "controllers": [],
    "threshold": null,
    "controladores_con_hit": [],
    "preregistrada": false,
    "vigencia_cache": null
  },
  "analytics": {
    "disponible": true,
    "proveedor": "...",
    "risk_score": 0,
    "cluster_name": "...",
    "cluster_category": "...",
    "exposure_direct_pct": 0,
    "exposure_indirect_pct": 0,
    "hop_count": 0,
    "profundidad_analizada": 3,
    "sanctions_exposure": false
  },
  "patrones_ofuscacion": ["mixing | chain-hopping | peeling | layering | privacy-coin | structuring"],
  "fuentes_publicas": [
    {"fuente": "...", "resultado": "...", "confidence": "HIGH | MEDIUM | LOW"}
  ],
  "facts_emitidos": [
    {"fact_id": "...", "type": "...", "confidence": "...", "evidencia_onchain": {}}
  ],
  "modo_degradado": false,
  "siguiente_skill": "typology-detection | swap-behavior-analysis | ofac-screening | fact-scoring"
}
```

> Si `sanctions_exposure: true` o si algún controlador de una Smart Account
> presenta un match directo: emitir el `FactEvent` de override y derivar de
> inmediato a `task-blocking-protocol`. No es necesario completar el resto
> del análisis.

> Si `atribucion_originador: false`, la evaluación no es concluyente sobre
> ningún actor real. Registrar la limitación en el expediente y no computar
> el resultado como una verificación satisfactoria.
