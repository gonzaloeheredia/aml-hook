---
name: task-swap-intake
description: "Recibir y clasificar un evento de swap o una solicitud de evaluación de wallet antes de asignar el flujo de análisis. Determina el modo de evaluación, extrae los parámetros del swap, verifica la vigencia del score en el oracle y define qué skills de dominio deben ejecutarse. Usar siempre como primer paso ante un evento nuevo: swap entrante, actualización disparada por afterSwap, denuncia de un LP, o revisión programada de una wallet."
---

# Task: Swap Intake — Recepción y Clasificación de Eventos

## Rol en el agente

Esta skill es el punto de entrada del agente. Estructura el evento recibido,
determina el modo de evaluación y define el flujo de trabajo. No analiza el
fondo: clasifica y enruta.

---

## Modos de evaluación

El agente opera en cuatro modos, con exigencias distintas de latencia y
profundidad.

| Modo | Disparador | Latencia admisible | Profundidad |
|---|---|---|---|
| **PRECOMPUTE** | Wallet nueva detectada, o revisión programada por vencimiento | Alta — asincrónico | Completa |
| **POST_SWAP** | Evento `SwapObserved` emitido por `afterSwap` | Media — segundos a minutos | Incremental sobre las dimensiones ST y NW |
| **ON_DEMAND** | Solicitud explícita del operador o del Oficial de Cumplimiento | Alta | Completa, con expediente |
| **ALERT** | Denuncia validada de LP, alerta de Forta, actualización de lista de sanciones | Inmediata | Dirigida al hecho que la disparó |
| **DISPUTE** | Impugnación admitida, retracción de señal externa, revocación de clave de reenviador | Alta | Recálculo dirigido a los hechos impugnados |
| **DEFERRED_ATTRIBUTION** | Evento previamente bloqueado por atribución fallida, encolado para resolución por trace | Alta | Resolución de atribución y, si prospera, evaluación completa |

**Regla de latencia.** Ningún modo se ejecuta dentro del `beforeSwap`. El
hook lee el score precalculado del oracle. Si no existe score vigente para
una wallet, el hook aplica la política de default configurada por el
operador, y el intake registra el evento en modo `PRECOMPUTE` con prioridad
alta.

---

## Paso 1: Extracción de campos

| Campo | Descripción |
|---|---|
| `evento_id` | Identificador del evento |
| `modo` | PRECOMPUTE / POST_SWAP / ON_DEMAND / ALERT |
| `origen` | Hook / motor off-chain / operador / denuncia LP / fuente externa |
| `address_evaluada` | Dirección bajo análisis |
| `rol` | SENDER o RECIPIENT |
| `pool_id` | Pool de Uniswap v4 involucrado |
| `amount_specified` | Monto del swap, con signo |
| `zero_for_one` | Dirección del swap |
| `currency_in` / `currency_out` | Tokens del par |
| `block_number` / `block_timestamp` | Momento del evento |
| `tx_hash` | Transacción, si existe |
| `score_vigente` | Score actual en el oracle y su bloque de cálculo |
| `informacion_faltante` | Qué se necesita y no está disponible |

**Interpretación de los parámetros del swap.**
`amountSpecified` es el insumo cuantitativo para la detección de
structuring: su valor absoluto, su signo (exact input o exact output) y su
relación con el umbral configurado. `zeroForOne` es el insumo del análisis
direccional: una serie de swaps con dirección constante y montos homogéneos
tiene un perfil distinto de una serie bidireccional compatible con
arbitraje.

---

## Paso 2: Verificación de vigencia del score

Antes de disparar cualquier análisis, verificar el estado del score en el
oracle.

| Estado | Criterio | Acción |
|---|---|---|
| **Vigente** | Dentro del período de revisión que corresponde a su tramo | En modo POST_SWAP, actualización incremental. En los demás, no recalcular |
| **Vencido** | Superó el período de revisión | Recálculo completo |
| **Inexistente** | La wallet no tiene score registrado | Recálculo completo con prioridad alta |
| **Invalidado** | Cambió una lista de sanciones o entró una alerta que lo afecta | Recálculo inmediato, override del período de vigencia |

---

## Paso 3: Clasificación de urgencia

| Nivel | Criterio | Respuesta |
|---|---|---|
| **Crítico** | Hit en lista de sanciones, interacción con contrato designado, nexo con financiamiento del terrorismo, alerta de exploit en curso | Inmediato — derivar a `task-blocking-protocol` antes de continuar |
| **Alto** | Score previo ≥ 71, tipología acumulativa activa, denuncia de LP validada, wallet sin score intentando swap por encima del umbral | Recálculo prioritario |
| **Medio** | Score previo 31–70, actualización de rutina post-swap, wallet nueva con monto por debajo del umbral | Cola estándar |
| **Bajo** | Revisión programada de wallet en tramo estándar | Cola diferida |

---

## Paso 4: Asignación del flujo

```
Siempre, y en primer lugar   → originator-attribution
Atribución resuelta          → ofac-screening
Toda evaluación              → wallet-screening
Existe historial disponible  → swap-behavior-analysis
Hay patrones detectados      → typology-detection
Señales de otros pools       → cross-pool-intelligence
Toda evaluación              → fact-scoring
Toda evaluación              → task-swap-decision
Urgencia crítica             → task-blocking-protocol (en paralelo)
Sospecha razonable alcanzada → task-regulatory-report
Impugnación recibida         → dispute-remediation
Configuración de pool nuevo  → protocol-obligations
Validación periódica         → model-validation
```

**Precedencia obligatoria, en dos niveles.** `originator-attribution` se
ejecuta antes que todo. Sin sujeto atribuido no hay análisis posible y, bajo
la política restrictiva por defecto, el swap revierte con código
`ATTRIBUTION_FAILED` sin que se ejecute ninguna otra skill.

Resuelta la atribución, `ofac-screening` se ejecuta antes que cualquier otra
skill de dominio. Un match directo detiene el flujo y deriva de inmediato a
`task-blocking-protocol`.

**Skip condicional.** En modo `POST_SWAP` con score vigente y sin hechos
nuevos de las dimensiones S, MX o GEO, el flujo se reduce a
`swap-behavior-analysis` y `fact-scoring` incremental. El objetivo es que la
actualización del perfil sea barata y frecuente.

---

## Output estructurado

```json
{
  "evento_id": "...",
  "modo": "PRECOMPUTE | POST_SWAP | ON_DEMAND | ALERT | DISPUTE | DEFERRED_ATTRIBUTION",
  "origen": "...",
  "address_evaluada": "0x...",
  "rol": "SENDER | RECIPIENT",
  "swap": {
    "pool_id": "0x...",
    "amount_specified": "0",
    "zero_for_one": true,
    "currency_in": "0x...",
    "currency_out": "0x...",
    "block_number": 0,
    "tx_hash": "0x..."
  },
  "score_oracle": {
    "existe": true,
    "valor": 0,
    "calculado_en_block": 0,
    "estado": "vigente | vencido | inexistente | invalidado"
  },
  "urgencia": "crítico | alto | medio | bajo",
  "atribucion": {
    "resuelta": true,
    "address_a_evaluar": "0x...",
    "metodo": "...",
    "politica_aplicada": "restrictiva"
  },
  "flujo_asignado": ["originator-attribution", "ofac-screening", "wallet-screening", "..."],
  "informacion_faltante": ["..."],
  "notas_intake": "..."
}
```

> Esta skill no requiere análisis previo. Opera con la información
> disponible al momento de recibir el evento. Si la información es
> insuficiente para clasificar, registra la carencia y asigna el flujo
> completo por defecto: la falta de datos no puede resolverse asumiendo un
> riesgo bajo.
