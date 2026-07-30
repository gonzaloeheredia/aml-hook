---
name: protocol-obligations
description: "Determinar qué obligaciones AML/CFT recaen sobre el operador de un pool que integra AML Hook, bajo los marcos de Estados Unidos (BSA, OFAC) y la Unión Europea (MiCA, TFR, AMLR), y qué evidencia debe conservar para acreditarlas. Usar al configurar un pool nuevo, al revisar el marco aplicable a un operador, o al determinar el destinatario y el estándar del expediente de evidencia."
---

# Protocol Obligations — Obligaciones del Operador del Pool

## Rol en el agente

Esta skill responde a la pregunta previa a todo lo demás: quién tiene la
obligación. AML Hook no es un sujeto obligado. El hook es infraestructura de
control; la obligación recae, en su caso, sobre el operador del pool, sobre
el emisor del activo o sobre la entidad que provee liquidez, según su propia
situación regulatoria.

La skill produce el mapa de obligaciones aplicables y el estándar de
evidencia correspondiente. No emite opinión jurídica vinculante ni determina
por sí sola la condición de sujeto obligado de ninguna entidad. Esa
determinación requiere asesoramiento legal específico del operador en su
jurisdicción.

---

## Inputs esperados

| Campo | Descripción |
|---|---|
| `operador` | Naturaleza de la entidad que opera el pool: protocolo, DAO, entidad registrada, emisor de activo |
| `jurisdiccion_operador` | Jurisdicción de constitución o de establecimiento efectivo |
| `jurisdiccion_usuarios` | Jurisdicciones desde las que se accede al pool |
| `tipo_activo` | Naturaleza de los activos del par: stablecoin, RWA tokenizado, activo nativo |
| `licencias_vigentes` | Registros y habilitaciones de la entidad operadora |
| `grado_de_control` | Capacidad efectiva del operador sobre el protocolo: parámetros, pausado, upgrade |

---

## Paso 1: Determinación del sujeto obligado

La condición de sujeto obligado depende del grado de control, no de la
etiqueta que la entidad se asigne. El criterio del GAFI en su guía
actualizada sobre activos virtuales es que la existencia de un actor con
control o influencia suficiente sobre el servicio puede calificarlo como
VASP (Virtual Asset Service Provider), aun cuando el servicio se presente
como descentralizado.

| Indicador de control | Relevancia |
|---|---|
| Capacidad de modificar parámetros del pool | Alta |
| Capacidad de pausar o suspender operaciones | Alta |
| Capacidad de actualizar contratos | Alta |
| Percepción de comisiones sobre la operatoria | Alta |
| Control de la interfaz de acceso | Media |
| Mantenimiento de una allowlist de participantes | Alta |
| Relación contractual con los participantes | Alta |
| Ausencia total de control operativo tras el deploy | Baja |

**Advertencia obligatoria.** La calificación de un protocolo DeFi o de su
operador como sujeto obligado bajo la BSA es una cuestión no resuelta de
forma uniforme, con criterios en evolución y litigios en curso. Esta skill
identifica los indicadores relevantes y produce una evaluación preliminar.
No sustituye el análisis legal específico, y todo output debe declararlo.

---

## Paso 2: Marco aplicable — Estados Unidos

### 2.1 Sanciones (OFAC)

Las obligaciones de OFAC aplican con independencia de la condición de sujeto
obligado bajo la BSA. Una persona estadounidense, o cualquier persona en una
transacción con nexo estadounidense, tiene prohibido operar con una parte
designada. No existe umbral mínimo ni excepción por descentralización.

| Obligación | Contenido |
|---|---|
| Prohibición de operar | Ninguna transacción con parte designada |
| Bloqueo de bienes | Los fondos adeudados a una parte designada deben bloquearse, no devolverse |
| Segregación | El activo bloqueado se mantiene segregado y no se dispone de él |
| Reporte del bloqueo | Comunicación a OFAC dentro de los 10 días hábiles del bloqueo |
| Reporte anual | Informe anual de bienes bloqueados |
| Conservación de registros | 5 años |

Referencia: IEEPA (50 U.S.C. § 1701 y ss.), 31 CFR Part 501, y la guía de
OFAC para la industria de moneda virtual (2021).

**Implicancia arquitectónica.** Un hook que simplemente revierte el swap
ante un match de sanciones no satisface el estándar de bloqueo y
segregación. El tratamiento correcto corresponde a `task-blocking-protocol`.

### 2.2 Bank Secrecy Act

Aplica si el operador califica como institución financiera bajo la BSA. En
tal caso:

| Obligación | Contenido |
|---|---|
| Programa AML | Programa escrito con controles internos, oficial designado, capacitación y prueba independiente |
| Monitoreo transaccional | Sistema razonable de detección de actividad sospechosa |
| SAR (Suspicious Activity Report) | Presentación ante FinCEN dentro de los 30 días corridos de la detección inicial |
| Confidencialidad del reporte | Prohibición de informar al sujeto reportado |
| Conservación de registros | 5 años |

Referencias: 31 U.S.C. § 5311 y ss.; 31 CFR § 1010.320; guía de FinCEN sobre
monedas virtuales convertibles.

**Rol del agente.** El agente produce evidencia y borradores. No presenta
ningún SAR. La presentación corresponde exclusivamente al Oficial de
Cumplimiento del operador, con revisión humana previa.

---

## Paso 3: Marco aplicable — Unión Europea

| Marco | Contenido | Aplicación al pool |
|---|---|---|
| MiCA — Reglamento (UE) 2023/1114 | Autorización y normas de conducta de los CASP (Crypto-Asset Service Provider) | Aplica si el operador presta servicios a personas en la Unión o tiene establecimiento en ella |
| TFR — Reglamento (UE) 2023/1113 | Travel Rule europea, sin umbral mínimo para transferencias de criptoactivos | Relevante para el tramo previo de los fondos y para el mitigante correspondiente |
| AMLR — Reglamento (UE) 2024/1624 | Régimen unificado de debida diligencia y monitoreo continuo | Aplica a las entidades obligadas según su calificación |
| Listas consolidadas de sanciones de la UE | Screening obligatorio | Aplica a toda entidad sujeta al derecho de la Unión |

Un DEX que opera bajo licencia europea necesita que sus pools tengan
verificación efectiva. Sin control a nivel de protocolo, el screening
ejecutado únicamente en la interfaz es evitable interactuando directamente
con el contrato, y por lo tanto no acredita cumplimiento.

---

## Paso 3 bis: Travel Rule — alcance real

La Travel Rule aplica a los activos virtuales desde que el GAFI extendió la Recomendación 16 en 2019. Los umbrales vigentes son heterogéneos.

| Jurisdicción | Umbral | Norma |
|---|---|---|
| Estándar GAFI | USD o EUR 1.000 | Recomendación 16 |
| Estados Unidos | USD 3.000 | 31 CFR § 1010.410(e) y (f). La propuesta de reducirlo a USD 250 para operaciones transfronterizas no fue finalizada |
| Unión Europea | Sin umbral mínimo | Reglamento (UE) 2023/1113 |

**No aplica al swap, y la distinción es material.** El supuesto de hecho es una transmisión de fondos por cuenta de un cliente entre dos instituciones, con ordenante y beneficiario diferenciados. Un swap dentro de un pool no reúne ninguno de esos elementos: no hay dos instituciones, no hay ordenante y beneficiario distintos, el usuario conserva la custodia en ambos extremos, y no existe un VASP receptor al que dirigir un mensaje IVMS 101.

Presentar la Travel Rule como una obligación que el hook satisface es incorrecto y perjudica la credibilidad del resto del análisis ante un revisor con formación regulatoria.

**Dónde sí importa, en tres supuestos:**

1. **Como mitigante.** Si los fondos llegaron al pool desde un VASP que cumplió, el riesgo de anonimato del tramo previo es menor. Genera `TRAVEL_RULE_CUMPLIDA_TRAMO_PREVIO`.
2. **Como obligación propia del operador.** Si el operador presta además servicios custodiados, la Travel Rule le aplica sobre esos flujos, con independencia del pool.
3. **Como delimitación del vacío.** La Recomendación 16 marca el perímetro donde el compliance ya existe. Las operaciones que no son transferencias entre VASPs quedan fuera de todo régimen de transmisión de datos. Ese vacío es el espacio funcional del monitoreo conductual, y ese es el argumento correcto: el hook no duplica la Travel Rule, cubre lo que la Travel Rule no alcanza.

---

## Paso 4: Estándar internacional de referencia

Con independencia de la jurisdicción, el prototipo y el expediente se
construyen sobre las Recomendaciones del GAFI como base común.

| Recomendación | Obligación operativa |
|---|---|
| Rec. 1 | Enfoque basado en riesgo; controles proporcionales al riesgo identificado |
| Rec. 6 y 7 | Sanciones financieras dirigidas; bloqueo sin demora |
| Rec. 10 | Monitoreo continuo a lo largo de la relación |
| Rec. 11 | Conservación de registros por un mínimo de 5 años |
| Rec. 15 | Evaluación de riesgos de nuevas tecnologías y activos virtuales |
| Rec. 16 | Travel Rule para transferencias entre VASPs. No aplica al swap; ver Paso 3 bis |
| Rec. 19 | Medidas reforzadas respecto de jurisdicciones de alto riesgo |
| Rec. 20 | Reporte ante sospecha razonable, sin umbral de monto |

La arquitectura modular permite ampliar la cobertura a marcos específicos
sin modificar la lógica central. Cada operador configura las capas que
correspondan a su situación.

---

## Paso 5: Estándar de evidencia exigible

Del mapa de obligaciones se deriva qué debe conservar el operador. Este es
el output práctico de la skill.

| Obligación | Evidencia que el agente produce |
|---|---|
| Monitoreo razonable | `ScoreResult` por wallet con hechos disparadores y base regulatoria |
| Proporcionalidad de la respuesta | Registro de la salida aplicada y su fundamento |
| Screening de sanciones | Registro de verificación con listas consultadas, versión y bloque |
| Detección de actividad sospechosa | Expediente de evidencia con tipologías identificadas |
| Bloqueo y segregación | Registro del protocolo de bloqueo con destino de los fondos |
| Conservación por 5 años | Eventos on-chain indexados con `audit_hash` |
| Confidencialidad | El expediente no se comunica al sujeto evaluado |

**Regla de suficiencia.** El estándar regulatorio no exige prevenir el cien
por ciento de la actividad ilícita. Exige un sistema razonable de monitoreo y
la documentación de lo actuado. El objetivo del expediente es acreditar la
razonabilidad del sistema y la trazabilidad de cada decisión, no demostrar
infalibilidad.

---

## Output estructurado

```json
{
  "operador": "...",
  "evaluacion_sujeto_obligado": {
    "indicadores_de_control_presentes": ["..."],
    "evaluacion_preliminar": "probable | posible | improbable | no-determinable",
    "advertencia": "Evaluación preliminar. No constituye asesoramiento legal. La calificación bajo BSA requiere análisis jurídico específico."
  },
  "marcos_aplicables": {
    "ofac": true,
    "bsa": "aplicable | condicional | no-determinado",
    "mica": false,
    "tfr": false,
    "amlr": false,
    "gafi_referencia": true
  },
  "obligaciones": [
    {"obligacion": "...", "marco": "...", "plazo": "...", "evidencia_requerida": "..."}
  ],
  "configuracion_recomendada_pool": {
    "modo": "permissive | restrictive",
    "politica_atribucion": "restrictiva | diferida | elevada | permissive",
    "reenviadores_confiables_requeridos": true,
    "advertencia_atribucion": "La política restrictiva revierte todo swap sin originador atribuido. Ningún router de uso general propaga hoy el originador con firma verificable: en un pool abierto sin reenviadores registrados, esta política revierte la mayor parte del flujo. Viable en pools restringidos con integradores conocidos.",
    "profundidad_hops": 3,
    "umbral_reporte_usd": 10000,
    "retencion_registros_anios": 5,
    "cobertura_claims_internos_erc6909": "El activo con controles a nivel de token no queda cubierto en la operatoria interna del PoolManager. Verificar si el hook cubre ese espacio.",
    "fundamento": "..."
  },
  "gaps_identificados": ["..."],
  "acciones_requeridas": [
    {"accion": "...", "responsable": "operador | oficial-de-cumplimiento | asesor-legal", "urgencia": "alta | media | baja"}
  ],
  "destinatario_expediente": "Oficial de Cumplimiento del operador del pool"
}
```

> Esta skill nunca concluye que una entidad es sujeto obligado. Produce la
> evaluación preliminar de los indicadores y deriva la determinación al
> asesor legal del operador. Toda configuración de pool que dependa de esa
> calificación queda pendiente hasta que el operador la confirme.
