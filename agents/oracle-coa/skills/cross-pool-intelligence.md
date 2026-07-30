---
name: cross-pool-intelligence
description: "Gestionar el registro de señales compartidas entre los pools que integran AML Hook: qué se comparte, cómo se pondera una señal externa frente a una propia, cómo se propagan las correcciones, y cómo se evita que un pool malicioso o mal calibrado contamine el registro común. Usar al incorporar señales externas al perfil de una wallet, al publicar una señal propia, y ante toda corrección de un score previamente compartido."
---

# Cross-Pool Intelligence — Registro Compartido de Señales

## Rol en el agente

El efecto de red es el activo defensivo del producto. Una wallet señalada en un pool tiene score elevado en los demás, y el registro acumula inteligencia que un competidor no puede replicar sin adopción real del protocolo. Cuantos más pools, mejor la detección; cuantos más participantes, más señales.

Ese mismo mecanismo es el vector de ataque más grave del sistema. Un registro compartido sin control de calidad propaga errores a escala, permite que un operador malicioso degrade a competidores, y convierte un falso positivo local en un bloqueo global.

Esta skill define qué entra al registro, con qué peso sale, y cómo se corrige.

---

## Inputs esperados

| Campo | Descripción |
|---|---|
| `operacion` | `PUBLICAR` o `CONSULTAR` |
| `address` | Dirección sobre la que se publica o consulta |
| `score_result` | `ScoreResult` propio, en operación de publicación |
| `pool_origen` | Pool que publica la señal |
| `señales_externas` | Señales disponibles en el registro, en operación de consulta |
| `reputacion_pools` | Historial de calidad de las señales de cada pool emisor |

---

## Paso 1: Qué se comparte y qué no

La regla es compartir hechos verificables, no juicios.

| Se comparte | No se comparte |
|---|---|
| Hechos con evidencia on-chain identificada por `tx_hash` y bloque | El score numérico final |
| Tipo de hecho y su categoría GAFI | El breakdown por dimensión |
| Confidence del hecho y su fuente | Los umbrales aplicados |
| Bloque de observación | La metodología de ponderación del pool emisor |
| Identificador del pool emisor | La identidad de los denunciantes |
| `audit_hash` de la observación | El expediente completo |

**Fundamento de la exclusión del score.** El score es el resultado de aplicar una metodología y unos umbrales que son específicos del pool y competitivamente sensibles. Compartirlo obligaría a los demás pools a heredar una calibración ajena, y publicaría de facto la configuración interna. Lo que viaja entre pools es la observación; la valoración la hace cada pool con sus propios parámetros.

**Fundamento de la exclusión de los denunciantes.** Publicar la identidad de un LP que denunció lo expone a represalias y desalienta el uso del mecanismo.

---

## Paso 2: Requisitos de admisión al registro

Una señal solo se publica si cumple, de forma acumulativa:

| Requisito | Contenido |
|---|---|
| Evidencia on-chain | El hecho remite a una transacción concreta, verificable de forma independiente por cualquier pool |
| Confidence mínimo | No se publican hechos con `confidence: LOW` |
| Origen no derivado | No se republican señales recibidas de otro pool; se cita la original |
| Atribución resuelta | No se publican señales sobre direcciones cuyo originador no fue atribuido |
| Firma del pool emisor | La señal lleva firma verificable del operador que la emite |

**Prohibición de circularidad.** Una señal recibida no puede reemitirse como propia. Sin esta regla, una única observación errónea se multiplica entre pools y adquiere la apariencia de confirmación independiente. Cada señal conserva la identidad de su emisor original y su `audit_hash`.

---

## Paso 3: Ponderación de la señal externa

Una señal ajena no puede pesar lo mismo que una observación propia. El pool que consulta no controló la fuente, no vio el contexto y no puede verificar la calibración del emisor.

| Factor | Efecto sobre el peso |
|---|---|
| **Verificabilidad independiente** | Si el pool consultante puede confirmar la evidencia on-chain por sí mismo, la señal se trata como propia. Es el caso ideal y el que la regla de evidencia on-chain busca maximizar |
| **Confidence del emisor** | Se hereda; nunca se eleva |
| **Reputación del emisor** | Ajuste por el historial de calidad de sus señales, medido en el Paso 5 |
| **Independencia** | N señales de pools distintos sobre el mismo hecho refuerzan; N señales derivadas de una misma observación original no |
| **Antigüedad** | Decaimiento temporal equivalente al de los hechos propios |
| **Tipo de hecho** | Los hechos de sanciones se verifican siempre contra la lista, nunca se aceptan por señal externa |

**Regla de techo.** Las señales externas no verificadas de forma independiente tienen techo en el tramo de fee diferencial. Un bloqueo exige al menos un hecho propio con `confidence: HIGH`, o una señal externa que el pool consultante haya verificado por sí mismo contra la evidencia on-chain citada.

Esta regla es la protección central contra la contaminación del registro. Impide que un pool malicioso o mal calibrado produzca bloqueos en pools ajenos.

---

## Paso 4: Defensa contra abuso

| Vector | Defensa |
|---|---|
| **Pool malicioso que señala competidores** | Techo de señales externas; verificación independiente exigida para bloqueo; reputación del emisor |
| **Pool mal calibrado que genera ruido** | Reputación por tasa de señales desmentidas; señales de emisores degradados pierden peso |
| **Sybil de pools** | El alta de un pool en el registro requiere umbral mínimo de liquidez y antigüedad, y se gobierna por Timelock |
| **Amplificación circular** | Prohibición de republicación; cada señal conserva emisor original |
| **Envenenamiento por dust** | Los hechos derivados de transferencias entrantes no solicitadas se marcan como tales y no computan como comportamiento del receptor |
| **Denuncia coordinada entre pools vinculados** | Los pools vinculados por operador común computan como un único emisor |

**Ataque de envenenamiento por transferencia entrante.** Cualquiera puede enviar fondos a cualquier dirección. Un actor que quiera degradar una wallet ajena puede enviarle fondos desde una dirección contaminada. El sistema debe distinguir entre fondos que la wallet recibió y fondos que la wallet usó: solo el uso posterior de esos fondos es comportamiento atribuible. Esta distinción es obligatoria y su ausencia convierte al sistema en un arma contra terceros.

---

## Paso 5: Reputación del pool emisor

| Métrica | Definición |
|---|---|
| Señales emitidas | Volumen del período |
| Tasa de confirmación | Señales que otros pools verificaron de forma independiente y confirmaron |
| Tasa de desmentido | Señales revertidas por `dispute-remediation` en el pool emisor o desmentidas por verificación ajena |
| Tasa de corrección propagada | Señales que el emisor corrigió por iniciativa propia |
| Cobertura de evidencia | Proporción de señales con evidencia on-chain verificable |

Un emisor con tasa de desmentido sostenida por encima del umbral configurado entra en estado degradado: sus señales siguen registrándose pero con peso reducido, y no pueden fundar tramo elevado en pools ajenos. La salida del estado degradado requiere un período de señales confirmadas.

**Valor del comportamiento correctivo.** Un emisor que corrige sus propios errores y propaga la corrección mejora su reputación. El incentivo debe favorecer la corrección, no el ocultamiento.

---

## Paso 6: Propagación de correcciones

Un error corregido en el pool de origen y no propagado sigue produciendo efectos en los demás. La propagación es obligatoria.

| Evento en el pool de origen | Obligación |
|---|---|
| Hecho eliminado por `dispute-remediation` | Retracción de la señal, con referencia al `audit_hash` de la resolución |
| Hecho degradado en confidence | Actualización de la señal |
| Cluster reatribuido por el proveedor | Actualización o retracción |
| Contrato que dejó de estar designado | Retracción obligatoria |
| Clave de reenviador revocada que sustentaba la atribución | Marcado de la señal para revisión |

Los pools consultantes que incorporaron una señal retractada deben recalcular los perfiles afectados. La skill mantiene el índice de qué pools consumieron cada señal, para hacer efectiva la propagación.

---

## Paso 7: Gobernanza del registro

| Decisión | Mecanismo |
|---|---|
| Alta y baja de pools | Timelock de la DAO |
| Umbral de reputación para degradación | Parámetro gobernable |
| Requisitos mínimos de liquidez y antigüedad para el alta | Parámetro gobernable |
| Techo de peso de señales externas | Inmutable |
| Prohibición de republicación | Inmutable |
| Exclusión del score del contenido compartido | Inmutable |
| Verificación de sanciones contra lista, nunca por señal ajena | Inmutable |

---

## Output estructurado

```json
{
  "operacion": "PUBLICAR | CONSULTAR",
  "address": "0x...",
  "publicacion": {
    "señales_publicadas": [
      {
        "tipo_hecho": "...",
        "categoria_gafi": [1],
        "confidence": "HIGH | MEDIUM",
        "evidencia_onchain": {"tx_hash": "0x...", "block_number": 0},
        "pool_emisor": "0x...",
        "audit_hash": "...",
        "firma_emisor": "..."
      }
    ],
    "señales_rechazadas": [
      {"motivo": "confidence-insuficiente | sin-evidencia-onchain | derivada | atribucion-no-resuelta"}
    ]
  },
  "consulta": {
    "señales_recibidas": 0,
    "emisores_distintos": 0,
    "emisores_independientes": 0,
    "señales_verificadas_localmente": 0,
    "señales_de_emisores_degradados": 0,
    "peso_agregado_aplicado": 0.0,
    "techo_aplicado": "fee-diferencial | sin-techo",
    "facts_emitidos": []
  },
  "defensas_activadas": ["dust-poisoning | republicacion | emisor-degradado | pools-vinculados"],
  "reputacion_emisores": [
    {"pool": "0x...", "tasa_confirmacion": 0.0, "tasa_desmentido": 0.0, "estado": "activo | degradado"}
  ],
  "retracciones_procesadas": [
    {"señal": "...", "motivo": "...", "pools_notificados": 0, "perfiles_a_recalcular": 0}
  ],
  "siguiente_skill": "fact-scoring | dispute-remediation"
}
```

> El registro compartido nunca sustituye la verificación propia. Un pool que
> bloquea una wallet exclusivamente por señales ajenas no verificadas no
> puede fundamentar la medida ante un supervisor, y traslada a un tercero
> una decisión de la que es responsable.
