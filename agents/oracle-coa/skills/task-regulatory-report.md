---
name: task-regulatory-report
description: "Redactar el expediente de evidencia que el operador del pool entrega a su propio Oficial de Cumplimiento: dictamen técnico con scoring justificado, anexo de sustento para un eventual SAR ante FinCEN, registro de decisión y reporte agregado del pool. Usar después de task-swap-decision cuando se alcanzó sospecha razonable, cuando se ejecutó un bloqueo, o cuando el operador solicita el expediente de un período. El agente nunca presenta un reporte ante ninguna autoridad."
---

# Task: Regulatory Report — Expediente de Evidencia

## Rol en el agente

Esta skill transforma el análisis en documentación formal. No genera
análisis nuevo: estructura y formaliza lo que las skills anteriores
produjeron.

**Destinatario.** El destinatario de todo output de esta skill es el Oficial
de Cumplimiento del operador del pool. El agente produce evidencia y
borradores para su revisión. No presenta reportes ante FinCEN, OFAC, ninguna
autoridad europea ni ningún supervisor. Esa presentación requiere revisión y
firma humana, y corresponde exclusivamente al operador según su propia
calificación regulatoria.

**Finalidad.** El expediente debe permitir que el operador acredite, ante un
supervisor o ante su propia auditoría, que el pool contaba con un sistema
razonable de monitoreo, que cada decisión tuvo fundamento normativo, y que la
cadena desde la conclusión hasta la evidencia on-chain es reconstruible.

---

## Inputs esperados

| Campo | Descripción |
|---|---|
| `tipo_documento` | `dictamen` · `anexo-sar` · `registro-decision` · `reporte-pool` · `respuesta-requerimiento` |
| `evento_id` | Identificador del evento |
| `output_swap_decision` | Output de `task-swap-decision` |
| `score_result` | Output de `fact-scoring` |
| `output_typology` | Tipologías identificadas |
| `expediente` | Output de `task-onchain-evidence` |
| `output_blocking` | Output de `task-blocking-protocol`, si se activó |
| `output_protocol_obligations` | Marco aplicable al operador |
| `periodo` | Rango temporal, para el reporte agregado |

---

## A. Dictamen técnico

Documento base. Se emite ante toda decisión de `REVERT`, ante todo bloqueo, y
ante toda señal de `SOSPECHA_RAZONABLE_ALCANZADA`. También se emite en forma
abreviada para `ALLOW` (verificación de que no se abrió anexo SAR).

**Modelo narrativo.** La estructura del cuerpo sigue la guía FinCEN
*Guidance on Preparing A Complete & Sufficient Suspicious Activity Report
Narrative* (nov. 2003) — **solo como modelo interno** (Who / What / When /
Where / Why / How). No es un SAR presentado ni un formulario FinCEN.

**Prohibición de skills en el dictamen.** El texto del dictamen y del anexo
cita hechos, direcciones, montos, fechas, eventos on-chain y bases
normativas. **Nunca** lista nombres de skills del agente (`ofac-screening`,
`fact-scoring`, `task-*`, rutas `skills/…`, etc.). Las skills son
instrumentos internos de análisis; no son fuentes del expediente.

```
DICTAMEN TÉCNICO DE COMPLIANCE — AML HOOK
════════════════════════════════════════════════════════════

Evento:          [ID]
Pool:            [0x...]
Wallet:          [0x...]
Fecha de emisión:[ISO 8601]
Bloque:          [N]
Destinatario:    Oficial de Cumplimiento del operador del pool
Carácter:        Evidencia interna. No constituye reporte a autoridad.
Modelo:          FinCEN SAR Narrative Guidance (estructura Who–How) — no filing

1. WHO — SUJETO(S)
════════════════════════════════════════════════════════════
Dirección(es) bajo revisión, rol (originador / intermediario / beneficiario),
relaciones conocidas en el grafo (origen de hop, cluster si consta).
Sin identidad verificada en pool permissionless.

2. WHAT — INSTRUMENTOS Y PATRONES
════════════════════════════════════════════════════════════
Instrumento (swap USDC→ETH, P2P ERC-20, etc.), tipologías / indicadores
GAFI observados, evidencia on-chain (tx_hash / bloque) y resultado del
screening de sanciones (hallazgo o verificación sin hallazgos).

3. WHEN — TEMPORALIDAD
════════════════════════════════════════════════════════════
Fecha/hora de evaluación, trigger, período de actividad sospechosa,
próxima revisión. Sin tablas densas; fechas individuales quedan en el ledger.

4. WHERE — VENUE Y DIRECCIONES
════════════════════════════════════════════════════════════
Venue (pool Uniswap v4 / red), address bajo revisión, path de hops P2P,
corredores o jurisdicciones solo si constan en evidencia.

5. WHY — POR QUÉ ES INUSUAL / ELEVADO
════════════════════════════════════════════════════════════
Score y banda (ALLOW / FEE_OVERRIDE / REVERT), hechos disparadores con
contribución, contraste con perfil esperado del pool. Sin concluir delito.

6. HOW — MÉTODO DE OPERACIÓN Y CONTROL
════════════════════════════════════════════════════════════
Modus (cash-out, hop, swap ordinario) y respuesta del hook
(ALLOW / FEE_OVERRIDE / REVERT), evento emitido, tratamiento de fondos.

7. FUNDAMENTO NORMATIVO
════════════════════════════════════════════════════════════
Norma o estándar que sustenta cada conclusión (GAFI, OFAC, BSA/FinCEN
como marco de modelo narrativo, marco UE si aplica).

8. RECOMENDACIONES AL OFICIAL DE CUMPLIMIENTO
════════════════════════════════════════════════════════════
Acciones sugeridas, plazos, tip-off prohibition, decisión humana.

9. TRAZABILIDAD
════════════════════════════════════════════════════════════
audit_hash: [SHA-256]
Eventos on-chain emitidos: [listado con bloque]
Evidencia de respaldo (ledger / emits / screen) — sin nombres de skills
Retención: 5 años (GAFI Rec. 11; BSA)
```

---

## B. Anexo de sustento para SAR

Se produce únicamente cuando concurren dos condiciones: se alcanzó sospecha
razonable, y `protocol-obligations` evaluó que el operador es probable
sujeto obligado bajo la BSA.

**Naturaleza del documento.** Es un anexo de sustento, no un formulario
presentado. El SAR se presenta electrónicamente ante FinCEN por el sujeto
obligado a través de su propio acceso. El agente aporta el material
analítico que el Oficial de Cumplimiento utiliza para completarlo y decidir
si corresponde presentarlo.

**Regla de campos.** Si un dato no consta en el expediente, el campo queda
vacío. No se completan marcadores de relleno.

### B.1 Datos de la actividad

| Campo | Contenido | Fuente |
|---|---|---|
| Fecha de detección inicial | Momento en que el sistema alcanzó sospecha razonable. Determina el cómputo del plazo de 30 días | `ScoreResult` |
| Período de la actividad | Solo el período de la actividad sospechosa, no el historial completo de la wallet | `swap-behavior-analysis` |
| Monto involucrado | Suma de las operaciones que integran el patrón, sin decimales | Serie de swaps |
| Activo y red | Token, par y blockchain | Intake |
| Estado de la operación | Ejecutada, ejecutada con fee diferencial, o revertida | `task-swap-decision` |

### B.2 Sujetos

En un pool permissionless no existe identidad verificada. El anexo consigna
identificadores on-chain y declara expresamente la ausencia de atribución de
identidad.

```
tipo_identificador: DIRECCION_ONCHAIN
address:
tipo_cuenta: EOA | SMART_ACCOUNT
controladores: []          # si es Smart Account y fueron identificados
cluster_atribuido:         # entidad, si el motor de analytics la atribuyó
confidence_atribucion: HIGH | MEDIUM | LOW
jurisdiccion_inferida:     # con base de inferencia declarada
identidad_verificada: false
nota: "No existe verificación de identidad. La atribución de cluster
       proviene de un proveedor comercial de analytics y no fue
       verificada de forma independiente."
rol: ORIGINADOR | BENEFICIARIO | WALLET_VINCULADA
```

### B.3 Campos narrativos

Redacción objetiva siguiendo el modelo FinCEN Who / What / When / Where /
Why / How (solo estructura). Sin conclusiones sobre la licitud de la
conducta. Sin listar skills del agente.

| Campo | Contenido |
|---|---|
| **DESCRIPCIÓN (WHO / WHAT)** | Sujeto(s), instrumento y operaciones observadas en secuencia, con montos, fechas y transacciones |
| **ANÁLISIS (WHEN / WHERE)** | Temporalidad y venue / path (pool, red, hops). Tipologías e indicadores concurrentes |
| **EVIDENCIA (WHY)** | Por qué es inusual: score, hechos, contraste con perfil; txs y emits de respaldo (sin nombres de skills) |
| **CONCLUSIÓN (HOW)** | Método de operación + control aplicado + anclaje de sospecha razonable. No concluye delito; no es un SAR presentado |

### B.4 Advertencias de carga

| Advertencia | Contenido |
|---|---|
| Plazo | 30 días corridos desde la detección inicial, si el operador es sujeto obligado |
| Confidencialidad | Prohibición de informar al sujeto reportado |
| Determinación de la obligación | La presentación depende de la calificación del operador bajo la BSA, que requiere confirmación legal |
| Estado del documento | Borrador de sustento. No presentado |

### B.5 Output estructurado del anexo

```json
{
  "anexo_sar": {
    "marco": "31 CFR § 1010.320 — Suspicious Activity Report",
    "condicionado_a": "Calificación del operador como sujeto obligado bajo la BSA",
    "fecha_deteccion_inicial": null,
    "plazo_presentacion": null,
    "periodo_actividad": {"desde": null, "hasta": null},
    "monto_involucrado": null,
    "activo": null,
    "red": null,
    "estado_operacion": "EJECUTADA | EJECUTADA_FEE_DIFERENCIAL | REVERTIDA",
    "sujetos": [],
    "campos_narrativos": {
      "descripcion_actividad": "",
      "analisis": "",
      "evidencia_respaldo": "",
      "conclusion": ""
    },
    "campos_faltantes": [],
    "advertencias": [],
    "estado": "borrador-de-sustento",
    "nota_presentacion": "Material de sustento para revisión del Oficial de Cumplimiento del operador. El agente no presenta reportes ante ninguna autoridad."
  }
}
```

---

## C. Registro de decisión

Documento breve para toda decisión que no alcanza el umbral de dictamen.
Su función es acreditar que la decisión existió y tuvo fundamento.

```
REGISTRO DE DECISIÓN
Evento / Wallet / Pool / Bloque
Score: [XX] — Salida: [ALLOW / FEE_DIFERENCIAL]
Hechos principales: [tres de mayor contribución con base regulatoria]
Fundamento: [código de razón]
Próxima revisión: [fecha]
audit_hash: [...]
```

---

## D. Reporte agregado del pool

Producto periódico para el operador. Acredita el funcionamiento del sistema
de monitoreo en su conjunto, que es lo que un supervisor examina antes de
examinar casos individuales.

```
REPORTE DE MONITOREO — POOL [0x...]
Período: [desde] – [hasta]

1. VOLUMEN Y COBERTURA
   Swaps evaluados / total de swaps del pool
   Wallets distintas evaluadas
   Wallets con score vigente al cierre del período

2. DISTRIBUCIÓN DE SALIDAS
   ALLOW:            [N] ([%])
   FEE_DIFERENCIAL:  [N] ([%])
   REVERT:           [N] ([%])
   Bloqueos por sanciones: [N]

3. TIPOLOGÍAS DETECTADAS
   Por tipología: cantidad de casos y categorías GAFI involucradas

4. SEÑALES DE SOSPECHA RAZONABLE
   Casos que alcanzaron el umbral
   Casos elevados al Oficial de Cumplimiento
   Casos con anexo de sustento producido

5. DESEMPEÑO OPERATIVO DEL SISTEMA
   Disponibilidad de fuentes de Nivel 1 y Nivel 2
   Eventos en modo degradado
   Casos con CONFIDENCE_INSUFICIENTE
   Casos con gap crítico
   Latencia media entre swap y actualización del score

6. FEE DIFERENCIAL Y ESCROW
   Monto acumulado en escrow
   Liberado al pool / reasignado a compensación de LPs

7. GOBERNANZA
   Modificaciones de parámetros ejecutadas vía Timelock
   Fundamento de cada modificación

8. TRAZABILIDAD
   Retención: 5 años
   Índice de audit_hash del período
```

---

## E. Respuesta a requerimiento

Si el operador recibe un requerimiento de una autoridad, el agente compila
el material solicitado. No redacta la respuesta ni la remite.

| Regla | Contenido |
|---|---|
| Alcance | Únicamente el material que el operador solicita compilar |
| Destinatario | El área legal o el Oficial de Cumplimiento del operador |
| Prohibición | El agente no responde directamente a ninguna autoridad |
| Formato | Índice de expedientes con `audit_hash`, eventos on-chain y fuentes, sin interpretación jurídica |

---

## Paso de revisión previo a la entrega

Antes de finalizar cualquier documento:

- Verificar que el scoring del dictamen coincide con el `ScoreResult` y con
  la salida efectivamente ejecutada
- Verificar que toda conclusión tiene `base_regulatoria` y evidencia
  on-chain identificada
- Verificar que los hechos con `confidence: LOW` están señalados como tales
- Verificar que las limitaciones del análisis están declaradas: profundidad
  de hops, fuentes no disponibles, gaps, modo degradado
- Verificar que ningún documento contiene una conclusión sobre la licitud de
  la conducta de una persona
- Verificar que el estado del anexo de sustento permanece en
  `borrador-de-sustento`
- Verificar que el sujeto evaluado no fue informado

---

## Output

```json
{
  "evento_id": "...",
  "tipo_documento": "dictamen | dictamen+anexo-sar | registro-decision | reporte-pool | compilacion-requerimiento",
  "destinatario": "Oficial de Cumplimiento del operador del pool",
  "estado": "borrador | revisado",
  "dictamen": "[texto completo]",
  "anexo_sar": { },
  "registro_decision": "[texto]",
  "reporte_pool": "[texto]",
  "limitaciones_declaradas": ["..."],
  "campos_faltantes": ["..."],
  "audit_hash": "...",
  "retencion_anios": 5,
  "nota": "Documentación interna del operador. El agente no presenta reportes ante ninguna autoridad."
}
```

> Cuando la decisión fue `REVERT` o se activó un bloqueo, el output debe
> incluir el dictamen. Cuando además se alcanzó sospecha razonable y el
> operador es probable sujeto obligado bajo la BSA, debe incluir también el
> anexo de sustento.
