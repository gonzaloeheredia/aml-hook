---
name: dispute-remediation
description: "Gestionar la impugnación de un score y la corrección de errores del sistema. Cubre el período de challenge de las denuncias de LPs, la disputa de una wallet bloqueada, la revisión por nueva evidencia, la rehabilitación de perfiles, el tratamiento del fee diferencial cobrado sobre un score revertido y la sanción de denuncias maliciosas. Usar ante toda impugnación, ante la aparición de evidencia que contradice un score vigente, y de forma periódica para revisar bloqueos sostenidos en el tiempo."
---

# Dispute & Remediation — Impugnación y Corrección

## Rol en el agente

Un sistema que bloquea y no puede desbloquear no cumple con el enfoque basado en riesgo: la proporcionalidad exige que la medida se levante cuando el riesgo que la fundó desaparece o se demuestra inexistente.

Esta skill cierra el circuito. Sin ella el paquete produce decisiones irreversibles sobre participantes que no tienen vía de corrección, lo cual es una fuente directa de reclamos, un obstáculo de adopción y una debilidad regulatoria: un supervisor que revisa un programa AML pregunta cómo se corrigen los errores, y la ausencia de respuesta es un hallazgo.

---

## Inputs esperados

| Campo | Descripción |
|---|---|
| `tipo_impugnacion` | Denuncia en challenge, disputa de score, revisión por nueva evidencia, revisión periódica |
| `address` | Dirección afectada |
| `score_impugnado` | `ScoreResult` bajo revisión, con su `audit_hash` |
| `hechos_impugnados` | Hechos disparadores cuya validez se cuestiona |
| `evidencia_aportada` | Material que sustenta la impugnación |
| `impugnante` | Titular de la wallet, LP denunciado, operador, o el propio sistema |
| `escrow_asociado` | Identificador del escrow, si hubo fee diferencial |

---

## Paso 1: Legitimación y admisibilidad

| Impugnante | Puede impugnar | No puede impugnar |
|---|---|---|
| **Titular de la wallet** | Score propio, hechos que lo componen, atribución fallida | Match directo en lista de sanciones |
| **LP denunciado** | Denuncia recibida durante el período de challenge | Score construido sobre otras dimensiones |
| **Operador del pool** | Cualquier score de su pool | Overrides de sanciones |
| **Sistema** | Cualquier score, ante nueva evidencia o corrección de un error de fuente | Nada |

**Materia no impugnable.** Un override por designación en una lista oficial no se disputa ante el operador del pool ni ante el agente. La designación se cuestiona ante la autoridad que la emitió, mediante los procedimientos de delisting que esa autoridad prevea. La skill informa esto y cierra la impugnación sin analizarla.

**Prueba de titularidad.** Para impugnar un score, el impugnante debe acreditar control de la dirección mediante firma de un mensaje con la clave correspondiente. Sin esa prueba la impugnación no se admite.

---

## Paso 2: Período de challenge de denuncias de LPs

Las denuncias de LPs son la fuente más manipulable del sistema. El período de challenge es su control.

| Etapa | Contenido | Plazo por defecto |
|---|---|---|
| Recepción | La denuncia se registra pero no afecta el score | Inmediato |
| Notificación | La wallet denunciada recibe el hecho de la denuncia, sin identificar al denunciante | Inmediato |
| Challenge | La wallet puede aportar evidencia que la contradiga | 72 horas |
| Resolución | El agente evalúa denuncia y descargo | 24 horas |
| Efecto | Si se sostiene, el hecho se incorpora al score | Al resolver |

**Reglas de integridad.**

1. Una denuncia individual nunca modifica el score. Se requiere el threshold de denuncias independientes configurado.
2. Denuncias provenientes de LPs vinculados entre sí por financiamiento común o co-spending computan como una sola.
3. El techo de efecto de las denuncias es el tramo de fee diferencial. Nunca producen bloqueo por sí solas.
4. Las denuncias pierden peso por decaimiento temporal.

**Sanción de denuncia maliciosa.** Si la resolución determina que la denuncia carecía de fundamento y fue coordinada, el stake del denunciante se ejecuta según la política del pool y el hecho se registra sobre el perfil del denunciante. Sin costo por denuncia falsa, el mecanismo se convierte en un vector de ataque contra competidores.

---

## Paso 3: Disputa de un score

| Causal | Contenido | Efecto si prospera |
|---|---|---|
| **Error de hecho** | El hecho disparador no ocurrió, o la evidencia on-chain no lo respalda | Se elimina el hecho y se recalcula |
| **Error de atribución** | La dirección fue vinculada erróneamente a un cluster o a otra wallet | Se elimina la vinculación y se recalcula |
| **Explicación económica** | Existe justificación legítima del patrón detectado, verificable | El hecho se conserva con confidence degradado o se descarta según `typology-detection` Paso 2 |
| **Fuente incorrecta** | El proveedor de analytics corrigió su atribución | Se actualiza el hecho con la nueva información |
| **Caducidad** | El hecho quedó fuera de la ventana de análisis y el decaimiento no se aplicó | Se recalcula con decaimiento correcto |
| **Atribución fallida** | El actor acredita ser el originador de una operación bloqueada por falta de atribución | Se resuelve la atribución y se construye el perfil |

**Estándar de prueba.** La impugnación debe aportar evidencia verificable, preferentemente on-chain. Una afirmación sin respaldo no revierte un hecho documentado. La carga recae en el impugnante, salvo en el caso de error de hecho, donde basta demostrar que la evidencia citada no existe o no dice lo que el expediente afirma.

**Efecto suspensivo.** La disputa no suspende el score vigente. Un bloqueo se mantiene mientras se resuelve, salvo que el impugnante demuestre error de hecho manifiesto, en cuyo caso el operador puede disponer la suspensión preventiva.

---

## Paso 4: Rehabilitación de perfiles

Un score alto no debe ser permanente si el comportamiento cambia. El mecanismo ordinario es el `decay_factor`, pero existen supuestos que requieren tratamiento expreso.

| Supuesto | Tratamiento |
|---|---|
| Comportamiento sostenidamente limpio tras un score elevado | El decaimiento reduce el componente histórico de forma progresiva. Se documenta la trayectoria |
| Wallet bloqueada que aporta evidencia del origen de sus fondos | Revisión completa; si la evidencia acredita origen lícito, se recalcula |
| Hecho basado en un contrato que dejó de estar designado | Recálculo obligatorio. El sistema no puede sostener un override sobre una designación revocada |
| Wallet cuyo cluster fue reatribuido por el proveedor | Recálculo obligatorio |
| Score construido sobre una atribución de reenviador cuya clave fue revocada | Marcado para revisión; la atribución que lo sustentaba dejó de ser confiable |

**Revisión periódica obligatoria de bloqueos.** Todo score en tramo de bloqueo que no derive de un override de sanciones se revisa según el calendario configurado. Un bloqueo sostenido sin revisión es una medida sin control de proporcionalidad.

---

## Paso 5: Tratamiento del fee diferencial

Si el score que fundó un fee diferencial se revierte, el fee cobrado debe tratarse.

| Situación | Tratamiento |
|---|---|
| El fee está en escrow y no venció el timelock | Se libera al participante, no al pool |
| El fee está en escrow y venció el timelock | Se restituye desde el fondo de compensación, según la política del pool |
| El fee se liberó al pool | Restitución sujeta a la política del operador. Si no hay mecanismo de restitución, debe declararse expresamente al participante antes de operar |
| El score se revierte parcialmente y el tramo se mantiene | No corresponde restitución. Se documenta el recálculo |

**Advertencia de diseño.** Un sistema que cobra fee diferencial sin mecanismo de restitución transfiere al participante el costo de los falsos positivos del operador. La existencia y el alcance del mecanismo de restitución es una decisión que el operador debe tomar de forma expresa y comunicar, porque afecta la defensibilidad del modelo económico.

---

## Paso 6: Registro y efectos sistémicos

Toda resolución se registra y produce efectos más allá del caso.

| Efecto | Contenido |
|---|---|
| Recálculo | Nuevo `ScoreResult` con referencia al `audit_hash` del anterior y al de la resolución |
| Alimentación de `model-validation` | Las disputas resueltas a favor del participante son casos etiquetados negativos y alimentan la tasa de falsos positivos |
| Propagación al registro compartido | Si el score se corrigió y había sido compartido con otros pools, la corrección se propaga. Un error no corregido se replica |
| Ajuste de fuente | Si la causa fue un error de un proveedor, se registra sobre la confiabilidad de esa fuente |
| Patrón de disputas | Un mismo tipo de hecho impugnado con éxito de forma recurrente indica descalibración y se eleva a `model-validation` |

---

## Output estructurado

```json
{
  "impugnacion_id": "...",
  "tipo": "challenge-denuncia | disputa-score | revision-nueva-evidencia | revision-periodica",
  "address": "0x...",
  "impugnante": "titular | lp-denunciado | operador | sistema",
  "admisibilidad": {
    "admitida": true,
    "titularidad_acreditada": true,
    "materia_impugnable": true,
    "motivo_rechazo": null
  },
  "causal": "error-de-hecho | error-de-atribucion | explicacion-economica | fuente-incorrecta | caducidad | atribucion-fallida",
  "evidencia_aportada": [
    {"descripcion": "...", "tipo": "onchain | documental | declarativa", "verificable": true}
  ],
  "resolucion": {
    "resultado": "ha-lugar | ha-lugar-parcial | sin-lugar",
    "hechos_eliminados": ["..."],
    "hechos_degradados": ["..."],
    "score_anterior": 0,
    "score_recalculado": 0,
    "tramo_anterior": "...",
    "tramo_nuevo": "...",
    "fundamento": "..."
  },
  "denuncia_maliciosa": {
    "determinada": false,
    "stake_ejecutado": false,
    "hecho_registrado_sobre_denunciante": false
  },
  "fee_diferencial": {
    "escrow_id": null,
    "estado": "en-escrow | liberado-al-pool | restituido | sin-restitucion",
    "monto": null
  },
  "efectos_sistemicos": {
    "propagado_a_registro_compartido": false,
    "caso_etiquetado_para_validacion": true,
    "fuente_observada": null,
    "patron_recurrente_detectado": false
  },
  "audit_hash_anterior": "...",
  "audit_hash_resolucion": "...",
  "siguiente_skill": "fact-scoring | cross-pool-intelligence | model-validation | cerrar"
}
```

> Esta skill no revierte overrides de sanciones bajo ninguna circunstancia.
> Tampoco resuelve por sí sola una disputa cuyo resultado implique
> desbloquear una wallet: esa resolución requiere aprobación del Oficial de
> Cumplimiento del operador, y el agente la eleva con su análisis.
