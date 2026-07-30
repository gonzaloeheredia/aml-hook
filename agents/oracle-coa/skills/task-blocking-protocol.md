---
name: task-blocking-protocol
description: "Ejecutar el protocolo aplicable cuando se detecta un match de sanciones, un vínculo con financiamiento del terrorismo o una situación que supera el nivel de resolución autónoma del agente. Cubre el tratamiento de fondos bloqueados, la segregación con rastro auditable, la notificación al Oficial de Cumplimiento del operador y las restricciones de confidencialidad. Usar de inmediato ante cualquier override de la dimensión de sanciones, sin esperar el cierre del análisis."
---

# Task: Blocking Protocol — Bloqueo, Segregación y Notificación

## Rol en el agente

Esta skill decide qué se hace con la operación y con los fondos cuando el
análisis arroja un resultado que el agente no puede resolver por sí mismo.
No evalúa el fondo del caso: asegura que la acción correcta se ejecute y que
la información correcta llegue al destinatario correcto en el tiempo
correcto. Es el mecanismo de control que garantiza que el agente no opere
fuera de su mandato.

---

## Distinción fundamental: rechazar no es bloquear

Esta es la diferencia operativa que la mayoría de las implementaciones
omite, y es la que un supervisor va a examinar primero.

| Situación | Tratamiento correcto | Tratamiento incorrecto |
|---|---|---|
| Score 71–99 sin designación | **Rechazo.** El swap revierte y los fondos permanecen en poder del participante | — |
| Match en lista de sanciones | **Bloqueo.** Los fondos adeudados a la parte designada quedan bloqueados y segregados, con registro auditable | Revertir el swap y devolver los fondos, que es una disposición del activo bloqueado |

Bajo el régimen de OFAC, cuando existe una obligación de pago o entrega a
favor de una parte designada, el activo debe bloquearse y mantenerse
segregado. Devolverlo al remitente puede constituir un incumplimiento
autónomo. La implementación de esta lógica corresponde al contrato de
custodia previsto en la arquitectura del hook.

**Advertencia de alcance.** La aplicabilidad concreta del régimen de bloqueo
al operador de un pool depende de su calificación regulatoria y de su nexo
jurisdiccional, cuestión que resuelve `protocol-obligations` en forma
preliminar y que requiere confirmación legal del operador. Esta skill
implementa el estándar más exigente por defecto y deja constancia del
criterio aplicado.

---

## Inputs esperados

| Campo | Descripción |
|---|---|
| `evento_id` | Identificador del evento |
| `address` | Dirección afectada |
| `trigger` | Qué activó el protocolo |
| `output_ofac` | Resultado del screening de sanciones |
| `score_result` | `ScoreResult` completo |
| `swap` | Parámetros de la operación afectada |
| `configuracion_pool` | Política de custodia, dirección del contrato de segregación, contactos del operador |

---

## Paso 1: Clasificación del trigger

| Trigger | Urgencia | Acción sobre la operación |
|---|---|---|
| Match directo en OFAC SDN, ONU o UE | Crítica | `REVERT` y activación de custodia sobre los fondos afectados |
| Interacción con contrato designado | Crítica | Idéntica |
| Nexo con financiamiento del terrorismo o proliferación | Crítica | Idéntica, con notificación inmediata |
| Controlador designado en Smart Account | Crítica | `REVERT` preventivo; custodia sujeta a revisión humana |
| Match por atribución de cluster | Alta | `REVERT`; custodia sujeta a revisión humana previa |
| Exploit en curso detectado sobre el pool | Crítica | Circuit breaker según la configuración del operador |
| Indisponibilidad del Nivel 1 de evidencia | Alta | Aplicar política de default; notificar incidente operativo |

---

## Paso 2: Tratamiento de los fondos

| Escenario | Tratamiento |
|---|---|
| El bloqueo ocurre en `beforeSwap` y la transacción revierte íntegramente | No hay transferencia de valor. No hay activo que segregar. Registrar la denegación con su fundamento |
| El bloqueo se detecta en `afterSwap` sobre la parte receptora | Enrutar el saldo a favor de la parte designada al contrato de custodia. No revertir hacia el remitente sin instrucción del Oficial de Cumplimiento |
| Fondos ya acreditados antes de la designación | Situación fuera del alcance del hook. Notificar al operador para tratamiento por su propio proceso |

**Requisitos del registro de custodia.** Todo enrutamiento a custodia debe
generar un registro con: dirección afectada, monto, activo, bloque,
`tx_hash`, lista y entrada que fundamentan el bloqueo, y `audit_hash` del
`ScoreResult`. El activo permanece segregado y no disponible hasta
instrucción documentada.

---

## Paso 3: Notificación

El destinatario es siempre el Oficial de Cumplimiento del operador del pool.
El agente no se comunica con autoridades ni con terceros.

| Situación | Destinatario | Plazo |
|---|---|---|
| Match de sanciones confirmado | Oficial de Cumplimiento del operador | Inmediato |
| Nexo con financiamiento del terrorismo | Oficial de Cumplimiento y dirección del operador | Inmediato |
| Match por cluster o por controlador | Oficial de Cumplimiento | Mismo día |
| Sospecha razonable alcanzada sin designación | Oficial de Cumplimiento | Mismo día hábil |
| Incidente operativo de fuentes | Responsable técnico del operador | Inmediato |

**Plazos regulatorios que el operador debe conocer.** El agente los informa;
no los ejecuta.

| Obligación | Marco | Plazo de referencia |
|---|---|---|
| Reporte de bienes bloqueados a OFAC | 31 CFR Part 501 | 10 días hábiles desde el bloqueo |
| Informe anual de bienes bloqueados | 31 CFR Part 501 | Según el calendario del régimen |
| Presentación de SAR ante FinCEN, si el operador es sujeto obligado | 31 CFR § 1010.320 | 30 días corridos desde la detección inicial |
| Conservación de registros | BSA y GAFI Rec. 11 | 5 años |

---

## Paso 4: Estructura de la notificación

```
ASUNTO: [BLOQUEO / ESCALAMIENTO] Evento [ID] — [Tipo] — Pool [ID]

1. SITUACIÓN
   Qué se detectó y por qué se activó el protocolo.

2. CLASIFICACIÓN
   Trigger: [regla activada]
   Score: [XX/100] — Salida ejecutada: [REVERT / custodia]

3. DATOS DE LA OPERACIÓN
   Wallet afectada: [0x...]
   Pool: [0x...]
   Monto: [...] — Activo: [...]
   Bloque y transacción: [...]

4. FUNDAMENTO
   Lista y entrada que originan la designación.
   Hechos disparadores principales con su base regulatoria.
   Confidence de cada hecho.

5. TRATAMIENTO DE FONDOS
   Estado: [sin transferencia / enrutado a custodia]
   Dirección de custodia: [0x...]
   Monto segregado: [...]

6. ACCIÓN REQUERIDA DEL OFICIAL DE CUMPLIMIENTO
   Qué se necesita y en qué plazo, con referencia al plazo regulatorio
   aplicable según la calificación del operador.

7. EXPEDIENTE
   audit_hash: [...]
   Referencia al expediente de evidencia completo.
```

---

## Paso 5: Confidencialidad

| Regla | Contenido |
|---|---|
| No se informa al sujeto evaluado | Ni el score, ni el fundamento, ni la existencia de un análisis en curso |
| El evento on-chain no revela el motivo | El código de razón emitido no debe permitir inferir la tipología detectada ni el umbral aplicado |
| El expediente no se publica | Se conserva off-chain, accesible al Oficial de Cumplimiento del operador |
| Prohibición de tipping-off | Bajo la BSA, revelar la existencia de un reporte de actividad sospechosa al sujeto reportado está prohibido |

**Tensión con la transparencia on-chain.** Un evento de reversión es
público, y la wallet afectada puede inferir que fue bloqueada. Lo que no
debe poder inferir es por qué ni con qué umbral, porque esa información
permite calibrar el comportamiento para eludir el control. El diseño del
código de razón debe resolver esa tensión, y su granularidad es un parámetro
que el operador configura bajo su propio criterio de riesgo.

---

## Paso 6: Registro

Independientemente del resultado, registrar:

| Campo | Contenido |
|---|---|
| Momento de activación | Timestamp y bloque |
| Trigger | Regla activada |
| Acción ejecutada sobre la operación | Reversión / custodia |
| Destino de los fondos | Dirección de custodia o ausencia de transferencia |
| Destinatario de la notificación | |
| Confirmación de recepción | Sí / No / Pendiente |
| Instrucción recibida del Oficial de Cumplimiento | |
| Acciones resultantes | |

---

## Reglas de no omisión

Este protocolo no puede omitirse ni posponerse si:

- Existe match confirmado en OFAC SDN, ONU o UE
- Se detecta interacción con un contrato designado
- Se identifica nexo con financiamiento del terrorismo o proliferación
- Un controlador de una Smart Account presenta un match directo

En estos casos la activación es inmediata y no espera el cierre del análisis
de fondo.

---

## Límites de autonomía del agente

El agente nunca:

- Presenta un reporte ante ninguna autoridad
- Libera fondos de custodia sin instrucción documentada del Oficial de Cumplimiento
- Informa al sujeto evaluado sobre la existencia de un análisis o un reporte
- Responde requerimientos de autoridades
- Modifica parámetros gobernables fuera del Timelock de la DAO
- Desbloquea una wallet con override de sanciones activo

---

## Output estructurado

```json
{
  "evento_id": "...",
  "address": "0x...",
  "trigger": "...",
  "urgencia": "crítica | alta",
  "accion_operacion": "revert-sin-transferencia | revert-con-custodia | circuit-breaker | default-policy",
  "custodia": {
    "activada": false,
    "direccion_custodia": null,
    "monto": null,
    "activo": null,
    "tx_hash": null,
    "block_number": 0
  },
  "notificacion": {
    "destinatario": "Oficial de Cumplimiento del operador",
    "momento": "<ISO 8601>",
    "mensaje": "...",
    "confirmacion_recepcion": false
  },
  "plazos_informados": [
    {"obligacion": "...", "marco": "...", "plazo": "...", "condicionado_a": "calificación regulatoria del operador"}
  ],
  "confidencialidad": {
    "sujeto_no_informado": true,
    "codigo_razon_emitido": "...",
    "granularidad_evento": "..."
  },
  "revision_humana_requerida": true,
  "audit_hash": "...",
  "siguiente_skill": "task-regulatory-report"
}
```
