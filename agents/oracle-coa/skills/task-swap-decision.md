---
name: task-swap-decision
description: "Traducir el score producido por fact-scoring en la salida ternaria que AML Hook ejecuta: permitir con fee estándar, aplicar fee diferencial, o revertir. Verifica reglas de override, valida la suficiencia probatoria de la decisión, define el destino del fee diferencial y produce el fundamento que se registra on-chain. Usar después de fact-scoring, antes de task-regulatory-report."
---

# Task: Swap Decision — Determinación de la Salida del Hook

## Rol en el agente

Esta skill toma el `ScoreResult` y produce la decisión que el hook ejecuta.
Es el momento de síntesis: el punto donde el análisis se convierte en una
acción con efecto económico sobre una operación real.

La decisión es ternaria, y esa gradación es la traducción operativa del
Enfoque Basado en Riesgo. Un sistema binario trata igual al riesgo medio y
al riesgo bajo, o al riesgo medio y al alto. Ninguna de las dos cosas
satisface la Recomendación 1 del GAFI.

---

## Inputs esperados

| Campo | Descripción |
|---|---|
| `score_result` | Output completo de `fact-scoring` |
| `output_ofac` | Output de `ofac-screening` |
| `output_typology` | Tipologías identificadas y multiplicidad de categorías |
| `configuracion_pool` | Modo, umbrales gobernables, multiplicador de fee, política de default |
| `expediente` | Output de `task-onchain-evidence`, incluidos gaps y modo degradado |

---

## Paso 1: Verificación de overrides

Antes de aplicar el mapeo de rangos, verificar si alguna regla de override
está activa. Las reglas de override no admiten ponderación.

| Regla | Condición | Efecto |
|---|---|---|
| Match directo en lista de sanciones | `OFAC_MATCH_DIRECTO`, `ONU_MATCH_DIRECTO`, `UE_MATCH_DIRECTO` | Score 100. Salida `REVERT`. Activar `task-blocking-protocol` |
| Interacción con contrato designado | `CONTRATO_SANCIONADO_DIRECTO` | Idéntico al anterior |
| Nexo con financiamiento del terrorismo | `FINANCIAMIENTO_TERRORISMO` | Idéntico, con urgencia máxima |
| Controlador designado en Smart Account | Hit en cualquier controlador | `REVERT` preventivo y revisión humana obligatoria |
| Nivel 1 de evidencia no disponible | `nivel_1_disponible: false` | Suspensión de la evaluación; aplicar la política de default del pool |
| Atribución del originador no resuelta | `atribucion.resuelta: false` bajo política restrictiva | Salida `REVERT` con código `ATTRIBUTION_FAILED`. No se construye perfil. Encolado para resolución diferida si la política está activa |

---

## Paso 2: Mapeo del score a la salida

| Rango | Salida | Efecto en el hook |
|---|---|---|
| 0–30 | `ALLOW` | Swap ejecutado con fee estándar. Evento de verificación emitido |
| 31–70 | `FEE_DIFERENCIAL` | Swap ejecutado con el multiplicador configurado. Evento de monitoreo emitido con el fundamento |
| 71–99 | `REVERT` | Swap revertido. Razón registrada en evento on-chain |
| 100 | `REVERT` + bloqueo | Swap revertido y protocolo de bloqueo activado |

**Fundamento de la salida intermedia.** El tramo 31–70 corresponde a
wallets con comportamiento atípico sin designación confirmada. No existe
obligación legal de bloquearlas. El estándar regulatorio ante ese perfil es
monitoreo reforzado y escrutinio adicional, no rechazo. El fee diferencial
es la traducción on-chain de ese principio: aplica fricción económica
proporcional, deja registro del evento y no excluye al participante.

---

## Paso 3: Validación de suficiencia probatoria

Toda decisión de `REVERT` por score entre 71 y 99 debe superar tres
controles antes de ejecutarse. Un bloqueo mal fundado tiene costo
regulatorio propio y expone al operador a reclamos.

| Control | Criterio | Resultado si falla |
|---|---|---|
| **Al menos un hecho HIGH** | El score no puede sustentarse solo en hechos MEDIUM y LOW | Emitir `CONFIDENCE_INSUFICIENTE`; degradar a `FEE_DIFERENCIAL` |
| **Multiplicidad de categorías** | Al menos dos categorías GAFI concurrentes | Emitir advertencia; la decisión requiere revisión humana antes de consolidarse como política sobre esa wallet |
| **Ausencia de gap crítico** | Ningún gap del expediente impide evaluar la dimensión que sustenta el bloqueo | Degradar a `FEE_DIFERENCIAL` y registrar la limitación |
| **Hecho propio o señal verificada** | El bloqueo no se sustenta exclusivamente en señales externas no verificadas de forma independiente | Degradar a `FEE_DIFERENCIAL`; ver `cross-pool-intelligence` Paso 3 |

Estos controles no aplican a los overrides del Paso 1. Un match de sanciones
se ejecuta con independencia de la suficiencia del resto del expediente.

---

## Paso 4: Destino del fee diferencial

El fee diferencial no se acredita al pool de forma inmediata. Se deposita en
un contrato de escrow con timelock configurable, cuyo default es 48 horas.

| Escenario dentro del timelock | Destino del fee |
|---|---|
| Se confirma que la wallet integraba un esquema de fraude, por designación posterior, por flag de wallets vinculadas o por completarse el patrón | Fondo de compensación para los LPs afectados |
| No hay confirmación al vencimiento del plazo | Liberación normal al pool |

El mecanismo produce dos efectos: genera un costo económico real para el
actor incluso cuando supera el filtro inicial, y financia un mecanismo de
compensación. Convierte el control de compliance en protección del pool.

**Registro obligatorio.** Todo depósito en escrow se registra con el
`audit_hash` del `ScoreResult` que lo fundamentó, para que la liberación o
la reasignación posterior sea auditable.

---

## Paso 5: Formulación del fundamento

Toda decisión, incluidas las de `ALLOW`, produce un fundamento registrable.
La ausencia de acción también es una decisión, y su documentación es parte
del estándar de monitoreo razonable.

El fundamento incluye:

1. Score y tramo aplicado
2. Los tres hechos de mayor contribución, con su base regulatoria
3. Tipologías identificadas y cantidad de categorías GAFI concurrentes
4. Controles de suficiencia superados o fallados
5. Bloque de cálculo del score y bloque de ejecución de la decisión
6. `audit_hash` del `ScoreResult`

**Regla de longitud.** El fundamento que se emite on-chain es un identificador
y un código de razón, no texto extenso. El fundamento completo se conserva
off-chain, vinculado por `audit_hash`. El evento on-chain debe permitir
localizar el expediente, no contenerlo.

---

## Paso 6: Derivaciones

| Condición | Derivación |
|---|---|
| Override de sanciones activo | `task-blocking-protocol`, urgencia crítica |
| `SOSPECHA_RAZONABLE_ALCANZADA` | `task-regulatory-report` |
| `REVERT` por score 71–99 | `task-regulatory-report` |
| `CONFIDENCE_INSUFICIENTE` o gap crítico | Revisión humana del Oficial de Cumplimiento del operador |
| `FEE_DIFERENCIAL` sin sospecha razonable | Registro y monitoreo; sin expediente formal |
| `ALLOW` | Registro de la verificación; cierre |
| Hecho propio publicable | `cross-pool-intelligence`, operación de publicación |
| Impugnación recibida sobre esta decisión | `dispute-remediation` |
| Decisión incorporada al período de validación | `model-validation` |

---

## Output estructurado

```json
{
  "evento_id": "...",
  "address": "0x...",
  "score_final": 0,
  "salida": "ALLOW | FEE_DIFERENCIAL | REVERT",
  "override_aplicado": {
    "activo": false,
    "regla": null
  },
  "validacion_suficiencia": {
    "hecho_high_presente": true,
    "sustento_propio_o_verificado": true,
    "categorias_gafi_concurrentes": 0,
    "gap_critico": false,
    "resultado": "suficiente | degradada | insuficiente",
    "salida_degradada_desde": null
  },
  "fee": {
    "multiplicador_aplicado": 1,
    "escrow": false,
    "timelock_horas": null,
    "escrow_id": null
  },
  "fundamento": {
    "codigo_razon": "...",
    "hechos_principales": [
      {"type": "...", "contribucion": 0, "base_regulatoria": "..."}
    ],
    "tipologias": ["..."],
    "score_calculado_en_block": 0,
    "decision_ejecutada_en_block": 0,
    "audit_hash": "..."
  },
  "evento_onchain": {
    "nombre": "ComplianceDecision",
    "campos": ["wallet", "poolId", "salida", "codigo_razon", "audit_hash"]
  },
  "atribucion": {
    "resuelta": true,
    "metodo": "...",
    "confidence": "HIGH | MEDIUM | LOW"
  },
  "requiere_revision_humana": false,
  "via_impugnacion_disponible": true,
  "siguiente_skill": "task-blocking-protocol | task-regulatory-report | cross-pool-intelligence | cerrar"
}
```

> Esta skill produce una decisión de ejecución sobre una operación, no una
> conclusión sobre la licitud de la conducta de nadie. La calificación de una
> operación como sospechosa, y toda actuación derivada, corresponde al
> Oficial de Cumplimiento del operador del pool.
