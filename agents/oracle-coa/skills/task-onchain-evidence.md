---
name: task-onchain-evidence
description: "Recopilar, organizar y validar la evidencia on-chain necesaria para evaluar una wallet. Cubre consulta de exploradores de bloques, motores de blockchain analytics, registros públicos de direcciones designadas, redes de alertas descentralizadas, attestations de terceros y el registro interno de denuncias de LPs. Usar después del intake, antes de las skills de dominio: produce el expediente sobre el que se construye todo el análisis."
---

# Task: On-Chain Evidence — Recopilación de Evidencia

## Rol en el agente

Esta skill estructura la recopilación de información sobre una dirección.
Define qué fuentes consultar, en qué orden, y cómo organizar el resultado
para que las skills de dominio trabajen sobre datos verificables. No evalúa
el fondo: produce un expediente ordenado con trazabilidad de cada dato.

Principio rector: todo hecho que después contribuya al score debe poder
rastrearse hasta la fuente que lo produjo, con su momento de consulta. Un
score sin cadena de evidencia no es defendible.

---

## Inputs esperados

| Campo | Descripción |
|---|---|
| `evento_id` | Identificador generado en el intake |
| `address` | Dirección bajo análisis |
| `modo` | Modo de evaluación asignado por el intake |
| `ventana_analisis` | Período a cubrir |
| `preguntas_clave` | Qué se necesita determinar |
| `evidencia_previa` | Expediente anterior de la wallet, si existe |

---

## Paso 1: Jerarquía de fuentes

Las fuentes se ordenan por su valor probatorio. La jerarquía determina el
`confidence` de los `FactEvent` que se emitan.

### Nivel 1 — Fuentes oficiales y estado on-chain verificable

| Fuente | Información | Confidence |
|---|---|---|
| Listas OFAC SDN, ONU y UE | Designaciones vigentes | HIGH |
| Mapping on-chain de direcciones designadas | Capa 1 del hook, consultable sin dependencia externa | HIGH |
| Explorador de bloques | Transacciones, código de contrato, `EXTCODESIZE`, owners de multisig | HIGH |
| Eventos emitidos por el propio hook | `SwapObserved`, decisiones previas, bloqueos | HIGH |

### Nivel 2 — Motores comerciales de analytics

| Fuente | Información | Confidence |
|---|---|---|
| Chainalysis | Mapping de direcciones designadas, atribución de cluster, exposición | MEDIUM |
| TRM Labs | Cobertura equivalente | MEDIUM |
| Elliptic | Cobertura equivalente, fuerte en Europa | MEDIUM |
| Solidus Labs | Orientado a DeFi; detección de manipulación de mercado | MEDIUM |

La atribución de cluster es un juicio del proveedor y no es verificable de
forma independiente por el operador. Corresponde `MEDIUM` salvo
confirmación por una segunda fuente independiente, en cuyo caso se aplica el
multiplicador de contexto correspondiente.

### Nivel 3 — Fuentes descentralizadas y comunitarias

| Fuente | Información | Confidence |
|---|---|---|
| Forta Network | Alertas de exploits, comportamiento anómalo, rug pulls | MEDIUM |
| EAS (Ethereum Attestation Service) | Attestations de riesgo publicadas por terceros | MEDIUM |
| Hypernative | Alertas on-chain en tiempo real | MEDIUM |
| DeFiLlama Hacks DB | Registro público de incidentes con direcciones involucradas | MEDIUM |
| Registros abiertos de direcciones sancionadas | Alternativa sin dependencia de proveedor comercial | MEDIUM |

### Nivel 4 — Señales internas del protocolo

| Fuente | Información | Confidence |
|---|---|---|
| Registro de denuncias de LPs | Reportes de proveedores de liquidez con stake | LOW individual; MEDIUM al superar el threshold y el período de challenge |
| Historial del oracle | `ScoreResult` previos de la wallet | HIGH sobre el dato del score; el fundamento hereda el confidence original |
| Registro compartido entre pools | Señales agregadas de otros pools que integran el hook | MEDIUM |

### Nivel 5 — Inferencia analítica

Estadísticos calculados por el propio agente: percentiles, desviaciones,
correlaciones temporales, vinculación de wallets. Confidence `LOW` salvo que
el criterio sea determinístico (co-spending verificable en una transacción
concreta, que es `HIGH`).

---

## Paso 2: Plan de recopilación por dimensión

| Dimensión de `fact-scoring` | Fuentes a consultar |
|---|---|
| **S — Sanciones** | Nivel 1 completo; Nivel 2 para atribución de cluster |
| **ST — Structuring** | Eventos del hook; explorador; inferencia analítica sobre la serie |
| **MX — Mixers** | Nivel 1 para contratos designados; Nivel 2 para trazabilidad; explorador para verificación directa |
| **NW — Red y contrapartes** | Explorador; Nivel 2 para atribución; oracle para score de contrapartes; DeFiLlama para exploits; denuncias de LPs |
| **GEO — Geografía** | Nivel 2 exclusivamente; declarar siempre la base de la inferencia |
| **MT — Mitigantes** | Oracle para historial; explorador para diversidad de protocolos; registros de attestations de terceros |

---

## Paso 3: Registro de la consulta

Para cada fuente consultada, documentar:

| Campo | Contenido |
|---|---|
| Fuente | Identificación |
| Momento de consulta | Timestamp y bloque de referencia |
| Versión de los datos | Fecha de última actualización de la lista o del índice |
| Resultado | Hallazgo o ausencia de hallazgo |
| Confidence asignado | Según la jerarquía |
| Disponibilidad | Respondió / no respondió / respondió parcialmente |

El registro de las consultas sin hallazgos es tan relevante como el de las
consultas positivas. Acreditar que se verificó y no se encontró nada es
parte del estándar de monitoreo razonable.

---

## Paso 4: Modo degradado

Si una fuente de Nivel 2 no responde, la skill continúa con las fuentes
disponibles y declara la limitación. La arquitectura del hook prevé
explícitamente que la indisponibilidad de un oracle no debe producir el
bloqueo de todas las operaciones.

| Situación | Comportamiento |
|---|---|
| Nivel 1 disponible, Nivel 2 caído | Continuar. Emitir `modo_degradado: true`. El score resultante no puede superar el tramo de fee diferencial salvo por hechos de Nivel 1 |
| Nivel 1 caído | Suspender la evaluación. El screening de sanciones no admite degradación. Emitir alerta al operador |
| Lista de sanciones desactualizada más allá del período configurado | Emitir `LISTA_DESACTUALIZADA`. Decisión del operador entre operar en modo degradado o suspender el pool |

---

## Paso 5: Identificación de gaps

Listar la información necesaria que no fue posible obtener y su efecto sobre
el análisis.

| Gap | Fuente posible | Efecto sobre el análisis |
|---|---|---|
| Atribución del originador tras un router | Trace de la transacción | El análisis no es concluyente sobre ningún actor real |
| Controladores de una Smart Account | Explorador; interfaz del contrato | No puede completarse la verificación por threshold |
| Origen de fondos más allá de la profundidad configurada | Ampliación de hops | Porcentaje de origen opaco no determinado |
| Atribución jurisdiccional | Motor de analytics | La dimensión GEO no puede evaluarse |

**Regla.** Un gap no equivale a un resultado negativo. Si un gap impide
evaluar una dimensión, el expediente debe declararlo, y `fact-scoring` no
puede computar esa dimensión como cero por defecto sin registrar la
limitación.

---

## Paso 6: Organización del expediente

```
expediente/
├── identificacion/     → tipo de cuenta, controladores, código de contrato
├── sanciones/          → listas consultadas, versiones, resultados
├── transaccional/      → serie de swaps, transferencias, eventos del hook
├── trazabilidad/       → hops, origen de fondos, protocolos intermedios
├── analytics/          → output del motor comercial, cluster, exposición
├── señales_externas/   → Forta, EAS, DeFiLlama, denuncias de LPs
├── historico/          → ScoreResult previos con audit_hash
└── gaps/               → información faltante y su efecto
```

---

## Output estructurado

```json
{
  "evento_id": "...",
  "address": "0x...",
  "fuentes_consultadas": [
    {
      "fuente": "...",
      "nivel": 1,
      "momento_consulta": "<ISO 8601>",
      "block_referencia": 0,
      "version_datos": "...",
      "resultado": "...",
      "confidence": "HIGH | MEDIUM | LOW",
      "disponibilidad": "ok | parcial | sin-respuesta"
    }
  ],
  "hallazgos_relevantes": ["..."],
  "gaps_identificados": [
    {"informacion": "...", "fuente_posible": "...", "efecto_sobre_analisis": "..."}
  ],
  "modo_degradado": false,
  "nivel_1_disponible": true,
  "lista_desactualizada": false,
  "expediente_suficiente": true,
  "listo_para_evaluacion": true,
  "notas": "..."
}
```

> Si `nivel_1_disponible: false`, la skill no avanza. El screening de
> sanciones es la única capa que no admite ejecución degradada, y su
> indisponibilidad se eleva al operador como incidente operativo.
