---
name: fact-scoring
description: "Módulo de puntuación AML/CFT de wallets (score 0–100) con justificación normativa GAFI/OFAC/BSA por dimensión. Produce el score que AML Hook consume en beforeSwap para determinar la salida ternaria: permitir, fee diferencial o revertir. Usar siempre que task-swap-decision deba producir un rating cuantificado e integrable en el expediente de evidencia de task-regulatory-report."
---

# Fact Scoring — Módulo de Puntuación de Wallets AML/CFT

## Propósito y alcance

Este módulo es el motor de evaluación de riesgo del Compliance Officer Agent
de AML Hook. Su responsabilidad es tomar los hechos observados sobre una
dirección (wallet) y traducirlos a un risk score numérico (0–100) con
trazabilidad normativa auditada, listo para ser escrito en el oracle
on-chain y consumido por el hook en el momento del swap.

El módulo no toma decisiones arbitrarias: cada puntaje asignado a cada
hecho se deriva de estándares emitidos por organismos multilaterales o
autoridades competentes. La fuente primaria es el GAFI (Grupo de Acción
Financiera Internacional / FATF — Financial Action Task Force), cuyas 40
Recomendaciones y documentos técnicos complementarios constituyen el
estándar que este módulo operacionaliza. Los marcos de aplicación son la
BSA (Bank Secrecy Act) y el régimen de sanciones de OFAC (Office of
Foreign Assets Control) en Estados Unidos, y MiCA (Markets in Crypto-Assets
Regulation) junto con el TFR (Transfer of Funds Regulation) en la Unión
Europea.

El output del módulo (score, breakdown por dimensión y justificación
normativa por hecho) cumple dos funciones:

1. **Función on-chain.** El `score_final` se firma criptográficamente y se
   escribe en `ComplianceOracle`. `AMLHook.beforeSwap` lo lee y aplica la
   salida ternaria sin latencia adicional.
2. **Función documental.** El `ScoreResult` completo se integra como
   sección obligatoria del expediente de evidencia generado por
   `task-regulatory-report`.

**Restricción arquitectónica.** El módulo opera off-chain y de forma
asincrónica respecto del swap. El hook nunca invoca este módulo en tiempo
de ejecución: lee un score precalculado. Toda lógica de este archivo asume
cómputo previo y cacheo, no evaluación en el `beforeSwap`.

---

## Marco normativo de referencia

### GAFI — Las 40 Recomendaciones (2012, actualizadas 2023)

**Recomendación 1 — Evaluación de Riesgos y Enfoque Basado en Riesgo (EBR)**

El EBR es el principio rector de todo el sistema de scoring. Exige que los
controles sean proporcionales al riesgo identificado: no todo lo que no es
perfectamente limpio merece el mismo nivel de respuesta. Un sistema que
trata igual el riesgo bajo y el alto no cumple con el EBR. El score continuo
(0–100) es la implementación técnica del EBR, y la salida ternaria del hook
(permitir / fee diferencial / revertir) es su traducción operativa: la
respuesta se gradúa en lugar de ser binaria.

**Recomendación 10 — Debida Diligencia y monitoreo continuo**

Exige monitoreo continuo de las transacciones a lo largo de toda la relación,
para detectar si son consistentes con el perfil de riesgo conocido. En el
contexto de un pool permissionless no existe relación comercial ni
documentación de identidad, pero sí existe historial de comportamiento
verificable on-chain. El perfil acumulativo de la wallet es el sustituto
funcional del perfil del cliente, y es precisamente lo que ninguna solución
de verificación puntual puede construir.

El tramo MEDIO (fee diferencial) es el equivalente funcional de la Debida
Diligencia Reforzada (DDR / EDD — Enhanced Due Diligence): no implica
rechazo automático sino fricción económica, monitoreo reforzado y registro
del evento.

**Recomendación 15 — Nuevas Tecnologías**

Exige identificar y evaluar los riesgos de LA/FT (Lavado de Activos /
Financiamiento del Terrorismo) que surgen de nuevas tecnologías, productos
y servicios. La nota interpretativa incorporada en 2019 extendió estas
obligaciones expresamente a los activos virtuales y a los VASP (Virtual
Asset Service Provider).

**Recomendación 16 — Travel Rule**

Obliga a transmitir información del ordenante y del beneficiario en formato
IVMS 101 (InterVASP Messaging Standard 101) cuando un VASP ejecuta una
transferencia de activos virtuales por cuenta de un cliente hacia otro VASP.
El umbral que recomienda el GAFI es de USD o EUR 1.000. En Estados Unidos la
obligación se codifica en 31 CFR § 1010.410(e) y (f) con umbral de USD 3.000,
y la propuesta de reducirlo a USD 250 para operaciones transfronterizas no
fue finalizada. En la Unión Europea el TFR eliminó el umbral mínimo para
transferencias de criptoactivos.

**La Travel Rule no es una obligación del hook y no puede serlo.** El
supuesto de hecho de la Recomendación 16 es una transmisión de fondos por
cuenta de un cliente entre dos instituciones, con ordenante y beneficiario
diferenciados. Un swap dentro de un pool no reúne ninguno de esos elementos:
no hay dos instituciones, no hay ordenante y beneficiario distintos, el
usuario conserva la custodia en ambos extremos, y no existe un VASP receptor
al que dirigir un mensaje. Un hook no tiene destinatario para un IVMS 101.

La función que la Recomendación 16 sí cumple dentro de este sistema es otra:
delimita el perímetro donde el compliance ya existe. Cuando los fondos
llegaron al pool desde un VASP que cumplió con la Travel Rule, el riesgo de
anonimato de la contraparte en el tramo previo es menor, y ese hecho opera
como mitigante. Fuera de ese perímetro no hay régimen de transmisión de
datos aplicable, y ese vacío es precisamente el espacio que el monitoreo
conductual ocupa.

**Recomendación 20 — Reporte de Operaciones Sospechosas**

Cuando existe sospecha, o motivos razonables para sospechar, que los fondos
son producto de actividad criminal o están relacionados con financiamiento
del terrorismo, corresponde reportar.

El principio crítico: el umbral de activación es **sospecha razonable**, no
certeza. Un score que alcanza el umbral de reporte no necesita demostrar que
la wallet lavó fondos; necesita demostrar que existe sospecha razonable
basada en patrones observables. El campo `justificacion` de cada hecho
disparador documenta exactamente qué combinación de circunstancias generó
esa sospecha.

Segundo principio (Rec. 20): **no existe umbral mínimo de monto**. Esto
fundamenta por qué el módulo pondera el structuring de montos pequeños con
el mismo peso que operaciones de alto valor, y por qué el hook no puede
escalar sus controles únicamente en función del `amountSpecified` del swap
en curso.

### GAFI — Indicadores de Alerta en Activos Virtuales (2020)

Sobre la base de más de cien estudios de caso, el GAFI identificó seis
categorías de indicadores de alerta:

- **Categoría 1:** Tamaño y frecuencia de transacciones (structuring)
- **Categoría 2:** Patrones de transacciones (frecuencia, múltiples cuentas)
- **Categoría 3:** Anonimato (mixers, privacy coins, servicios sin controles)
- **Categoría 4:** Perfil de remitentes y beneficiarios inconsistente
- **Categoría 5:** Origen de fondos vinculado a actividad ilícita
- **Categoría 6:** Riesgos geográficos

**Principio metodológico central:** un único indicador no indica
necesariamente actividad criminal. Es la presencia de múltiples indicadores
combinados, sin explicación económica lógica, lo que eleva la sospecha. Este
principio fundamenta el `context_multiplier` del algoritmo.

### Estados Unidos

| Marco | Contenido relevante |
|---|---|
| BSA — Bank Secrecy Act (31 U.S.C. § 5311 y ss.) | Régimen de reporte y conservación de registros. Define el estándar de monitoreo transaccional razonable. |
| 31 CFR § 1010.320 | Régimen del SAR (Suspicious Activity Report). Plazo de presentación: 30 días corridos desde la detección inicial. |
| FinCEN FIN-2013-G001 y guía de 2019 sobre CVC | Aplicación del régimen de money transmitters a monedas virtuales convertibles. Determina cuándo un actor del ecosistema queda alcanzado. |
| OFAC — IEEPA (50 U.S.C. § 1701 y ss.), 31 CFR Part 501 | Obligación de bloquear bienes de personas designadas, reportar el bloqueo dentro de los 10 días hábiles y mantener el activo segregado. |
| OFAC Sanctions Compliance Guidance for the Virtual Currency Industry (2021) | Expectativa expresa de screening de direcciones y monitoreo de exposición indirecta. |

### Unión Europea

| Marco | Contenido relevante |
|---|---|
| MiCA — Reglamento (UE) 2023/1114 | Régimen de autorización y conducta de los CASP (Crypto-Asset Service Provider). |
| TFR — Reglamento (UE) 2023/1113 | Travel Rule europea. Sin umbral mínimo para transferencias de criptoactivos. |
| Reglamento (UE) 2024/1624 (AMLR) y creación de AMLA | Régimen AML/CFT unificado; obligaciones de debida diligencia y monitoreo continuo. |
| Listas consolidadas de sanciones de la UE | Screening obligatorio para entidades sujetas al derecho de la Unión. |

---

## 1. Estructura de entrada

El módulo recibe un `FactBundle` con los hechos relevantes extraídos por
`task-onchain-evidence`:

```json
{
  "wallet": {
    "address": "0x...",
    "chain_id": 1,
    "account_type": "EOA | SMART_ACCOUNT | UNKNOWN",
    "controllers": ["0x...", "0x..."],
    "multisig_threshold": "3/5 | null",
    "first_seen_block": 0,
    "antiguedad_dias": 0,
    "swaps_totales": 0,
    "contrapartes_distintas": 0,
    "protocolos_distintos": 0,
    "jurisdiccion_inferida": "<ISO 3166-1 alpha-2 | null>"
  },
  "swap": {
    "pool_id": "0x...",
    "amount_specified": "0",
    "zero_for_one": true,
    "monto_usd_estimado": 0.0,
    "currency_in": "0x...",
    "currency_out": "0x...",
    "block_timestamp": "<ISO 8601>"
  },
  "facts": [<FactEvent>, ...]
}
```

Cada `FactEvent`:

```json
{
  "fact_id": "<identificador único>",
  "type": "<tipo de hecho — ver catálogo>",
  "observado_en": "<fecha ISO 8601>",
  "fuente": "LISTA_OFICIAL | ANALYTICS | EXPLORADOR | ORACLE_INTERNO | DENUNCIA_LP | INFERENCIA",
  "confidence": "HIGH | MEDIUM | LOW",
  "evidencia_onchain": {
    "tx_hash": "0x... | null",
    "block_number": 0
  },
  "payload": { ... }
}
```

**Niveles de confidence:**
- `HIGH`: hecho verificado en lista oficial o transacción on-chain confirmada
- `MEDIUM`: hecho derivado del motor de analytics o calculado sobre datos verificados
- `LOW`: hecho inferido por análisis estadístico sin confirmación independiente

**Regla de admisibilidad.** Ningún `FactEvent` con `fuente: INFERENCIA` y
`confidence: LOW` puede ser el único sustento de un score ≥ 71. El tramo de
bloqueo exige al menos un hecho con `confidence: HIGH`.

---

## 2. Catálogo de hechos por dimensión

### 2.1 Dimensión S — Sanciones

Fuente: GAFI Rec. 6 y 7; listas OFAC SDN, ONU y UE; OFAC Virtual Currency
Guidance 2021.

| Tipo | Descripción | base_weight |
|---|---|---|
| `OFAC_MATCH_DIRECTO` | La dirección figura en la lista SDN (Specially Designated Nationals) de OFAC. Bloqueo incondicional sin cálculo adicional. | +100 (override) |
| `ONU_MATCH_DIRECTO` | La dirección figura en las listas del Consejo de Seguridad de la ONU. | +100 (override) |
| `UE_MATCH_DIRECTO` | La dirección figura en las listas consolidadas de sanciones de la Unión Europea. | +100 (override) |
| `CONTRATO_SANCIONADO_DIRECTO` | La wallet interactuó directamente con un contrato designado (Tornado Cash, Blender.io, Sinbad). | +100 (override) |
| `FINANCIAMIENTO_TERRORISMO` | Nexo documentado con financiamiento del terrorismo o proliferación. | +100 (override) |
| `MATCH_INDIRECTO_CONTRAPARTE` | Una contraparte directa de la wallet figura en alguna de las listas anteriores. | +50 |
| `VINCULO_CLUSTER_SANCIONADO` | La wallet pertenece a un cluster atribuido por analytics a una entidad designada. | +45 |

### 2.2 Dimensión ST — Structuring y Fraccionamiento

Fuente: Categoría 1 del Informe GAFI 2020.

El structuring en activos virtuales es directamente homologable al
structuring en efectivo. Es la tipología que ninguna verificación puntual
puede detectar, y la razón principal por la que el perfil acumulativo
existe.

| Tipo | Descripción | base_weight |
|---|---|---|
| `STRUCTURING_PROXIMIDAD_UMBRAL` | El `amountSpecified` del swap se ubica entre el 80% y el 99% del umbral de reporte configurado. | +15 |
| `STRUCTURING_PATRON_SPLIT` | N swaps en ventana T con suma acumulada ≥ umbral, sin que ninguno individual lo supere. Implementación directa de Categoría 1 GAFI 2020. | +25 |
| `STRUCTURING_MONTO_REDONDO` | Montos exactamente redondos combinados con alta frecuencia o patrón repetitivo. | +10 |
| `STRUCTURING_VELOCITY_SPIKE` | El volumen del período supera 5x la media histórica de la wallet sin correlato con actividad del pool. | +20 |
| `STRUCTURING_CROSS_WALLET` | El mismo patrón de fraccionamiento se detecta coordinado entre wallets vinculadas por co-spending o financiamiento común (smurfing). | +35 |
| `STRUCTURING_PATRON_ESCALONADO` | Swaps de alto valor en sucesión rápida seguidos de inactividad prolongada. Indicador de layering temporal. | +18 |
| `STRUCTURING_DIRECCIONAL_UNILATERAL` | Serie de swaps con `zeroForOne` constante y montos homogéneos, sin retorno ni rebalanceo. Patrón de extracción, no de trading. | +15 |

**Parámetros configurables:**
- `umbral_reporte_usd`: default 10.000 USD
- `ventana_structuring_dias`: default 30 días; 1 día para patrones intradiarios
- `min_splits`: default 3

### 2.3 Dimensión MX — Exposición a Mixers y Anonimización

Fuente: Categoría 3 del Informe GAFI 2020; OFAC Virtual Currency Guidance 2021.

El único propósito funcional de un mixer es cortar la trazabilidad de los
fondos. No existe razón económica legítima que justifique de forma
consistente su uso.

| Tipo | Descripción | base_weight |
|---|---|---|
| `MIXER_INTERACCION_DIRECTA` | Interacción directa con un mixer no designado (Railgun, Wasabi, CoinJoin) dentro de la ventana de lookback. | +30 |
| `MIXER_INTERACCION_INDIRECTA` | Los fondos provienen de una wallet que interactuó con un mixer. | +20 |
| `MIXER_POST_TIMING` | El swap ocurre dentro de las 72 horas posteriores a una interacción con mixer. | +15 |
| `PRIVACY_COIN_SIN_JUSTIFICACION` | Conversión hacia o desde una moneda de privacidad mejorada sin correlato económico. | +20 |
| `BRIDGE_CHAIN_HOPPING` | Fondos que transitan por tres o más cadenas en menos de 24 horas antes del swap. | +22 |
| `ORIGEN_OPACO_MAYORITARIO` | Más del 50% de los fondos entrantes no tiene origen razonablemente atribuible. | +25 |

**Parámetro configurable:** `mixer_lookback_dias`, default 90.

### 2.4 Dimensión NW — Comportamiento de Red y Contrapartes

Fuente: Categorías 2, 4 y 5 del Informe GAFI 2020; GAFI Rec. 10.

Esta dimensión implementa el monitoreo continuo: no solo qué hace esta
wallet, sino con quién interactúa y qué hacen esas contrapartes.

| Tipo | Descripción | base_weight |
|---|---|---|
| `CONTRAPARTE_ALTO_RIESGO` | Una contraparte directa tiene score ≥ 71 en el oracle. | +25 |
| `CONTRAPARTE_RIESGO_MEDIO` | Una contraparte directa tiene score 31–70. | +10 |
| `WALLET_NUEVA_OPERACION_ALTA` | Wallet con menos de 30 días de antigüedad ejecuta un swap por encima del umbral configurable. | +20 |
| `ACCOUNT_AGE_VS_SWAP_SIZE` | Anomalía estadística entre la antigüedad de la wallet y el volumen intentado, medida contra la distribución del pool. | +22 |
| `INBOUND_ONLY_MICRO_CLUSTER` | La wallet recibió transferencias unidireccionales pequeñas desde múltiples direcciones sin contrapartida, en ventana corta. Patrón de preparación de wallets intermediarias. | +22 |
| `CONCENTRACION_CONTRAPARTE` | La wallet interactúa casi exclusivamente con un protocolo objetivo y con wallets propias. Baja diversidad de contrapartes respecto de la mediana del pool. | +18 |
| `TRANSFERENCIA_RAPIDA_BALANCE_TOTAL` | La wallet mueve más del 90% de sus fondos inmediatamente después de recibirlos. Red flag explícito Categoría 2 GAFI 2020. | +25 |
| `VINCULO_DARKNET` | Fondos rastreables a mercados de la darknet conocidos. Categoría 5 GAFI 2020. | +40 |
| `VINCULO_RANSOMWARE` | Fondos rastreables a direcciones vinculadas a esquemas de ransomware. Categoría 5 GAFI 2020. | +45 |
| `FONDOS_DE_PROTOCOLO_EXPLOTADO` | Fondos rastreables a un exploit documentado. | +35 |
| `DENUNCIA_LP_VALIDADA` | Denuncias independientes de LPs (Liquidity Providers) con stake, por encima del threshold y superado el período de challenge. | +20 |
| `SEÑAL_EXTERNA_VERIFICADA` | Hecho publicado por otro pool del registro compartido y verificado de forma independiente contra su evidencia on-chain. | Hereda el peso del hecho original |
| `SEÑAL_EXTERNA_NO_VERIFICADA` | Hecho publicado por otro pool sin verificación independiente. Techo en tramo de fee diferencial. | Peso del hecho original × 0.5 |
| `ATRIBUCION_INCONSISTENTE` | Divergencia entre el originador declarado en `hookData` sin firma y el destinatario efectivo de los fondos. | +20 |

### 2.4 bis Dimensión DF — Tipologías nativas de DeFi

Fuente: Categorías 2, 4 y 5 del Informe GAFI 2020, aplicadas a mecánica de protocolo. Se computan dentro de la dimensión NW a efectos del agregado.

| Tipo | Descripción | base_weight |
|---|---|---|
| `SWAP_CLAIMS_INTERNOS_6909` | Operación liquidada sobre claims internos del PoolManager sin transferencia real del ERC-20, en un activo que implementa controles a nivel de token. | +25 |
| `SANDWICH_EXTRACCION` | Operaciones de la misma dirección o de direcciones vinculadas envolviendo una operación ajena en el mismo bloque. | +18 |
| `FLASH_LOAN_MANIPULACION` | Préstamo sin colateral, swap de alto impacto y repago en la misma transacción, con desplazamiento del precio del pool respecto de la referencia externa. | +30 |
| `RUG_PULL_RETIRO_LIQUIDEZ` | Remoción de posición de magnitud anómala precedida de acumulación concentrada. | +35 |
| `WASH_TRADING_LP` | Swaps recíprocos entre direcciones vinculadas sin resultado económico neto. | +25 |
| `DRENAJE_POR_APROBACION` | Uso de una aprobación previa para extraer saldo de un tercero, seguido de swap. | +40 |
| `ADDRESS_POISONING` | Emisión de transferencias de valor despreciable desde direcciones con prefijo y sufijo coincidentes con contrapartes habituales del objetivo. | +30 |
| `ESTRATIFICACION_NFT` | Operaciones sobre activos no fungibles a precio desconectado del mercado, entre direcciones vinculadas. | +22 |
| `SALTO_CADENA_VIA_CEX` | Depósito en dirección atribuida a exchange y reaparición de valor equivalente en otra red en ventana corta. | +20 |
| `PRODUCTO_ESTAFA_INVERSION` | Convergencia de múltiples remitentes sin relación entre sí, con patrón de montos y frecuencia característico y sin contraprestación identificable. | +35 |
| `PATRON_EVASION_ESTATAL` | Combinación de exposición a exploits documentados, velocidad de estratificación y uso intensivo de infraestructura de anonimización. | +45 |

**Regla de recepción frente a uso.** Ninguno de estos hechos puede fundarse en transferencias entrantes no solicitadas. Recibir fondos no es un acto de la wallet receptora. Solo el uso posterior de esos fondos constituye comportamiento atribuible. La ausencia de esta distinción convierte al sistema en un vector de ataque contra terceros.

### 2.5 Dimensión GEO — Riesgos Geográficos

Fuente: Categoría 6 del Informe GAFI 2020; GAFI Rec. 19; listas gris y negra
del GAFI; programas de sanciones comprehensivas.

La atribución geográfica de una wallet es inferencial. Todo hecho de esta
dimensión debe declarar la base de la inferencia (VASP de origen
identificado, nodo de entrada, patrón horario, jurisdicción del contrato
contraparte) y no admite `confidence: HIGH` salvo que exista atribución
documentada por el motor de analytics.

| Tipo | Descripción | base_weight |
|---|---|---|
| `GEO_LISTA_NEGRA_GAFI` | Exposición a jurisdicción en la lista negra del GAFI. | +30 |
| `GEO_LISTA_GRIS_GAFI` | Exposición a jurisdicción bajo monitoreo reforzado del GAFI. | +15 |
| `GEO_REGIMEN_SANCIONES_COMPREHENSIVAS` | Origen o destino asociado a un país bajo régimen comprehensivo (OFAC, ONU, UE). | +35 |
| `GEO_SERVICIO_NO_REGULADO` | Los fondos provienen de un servicio centralizado sin controles AML equivalentes al estándar GAFI. | +15 |

### 2.6 Dimensión MT — Hechos Mitigantes

Fuente: GAFI Rec. 10 y EBR.

Los mitigantes reducen el score. Nunca pueden llevarlo por debajo de 0 ni
neutralizar un override de sanciones.

| Tipo | Descripción | base_weight |
|---|---|---|
| `HISTORIAL_LIMPIO_LARGO` | Más de 365 días de actividad continua sin hechos de riesgo registrados. | −10 |
| `PERFIL_TRANSACCIONAL_COHERENTE` | El patrón de swaps es estadísticamente consistente con el histórico de la propia wallet y con la mediana del pool. | −8 |
| `TRAVEL_RULE_CUMPLIDA_TRAMO_PREVIO` | El tramo previo de los fondos incluye información IVMS 101 verificable. | −10 |
| `CONTRAPARTE_INSTITUCIONAL_VERIFICADA` | La contraparte es una entidad regulada en jurisdicción GAFI con controles propios documentados. | −12 |
| `ATTESTATION_VIGENTE_TERCERO` | La wallet presenta una attestation válida de un proveedor externo (Predicate, Civic, PureFi, allowlist de Permissioned Pools). Reduce el riesgo de identidad, no el de comportamiento. | −12 |
| `SMART_ACCOUNT_PREREGISTRADA` | Smart Account institucional con verificación de controladores completada y cacheada dentro del período de vigencia. | −15 |
| `DIVERSIDAD_PROTOCOLOS_ALTA` | La wallet interactúa con un número de protocolos distintos por encima de la mediana del pool. Perfil incompatible con wallet de ataque de uso único. | −8 |

**Regla de tope de mitigantes.** La suma de `raw_score_MT` no puede exceder
40 puntos. Un conjunto amplio de mitigantes débiles no puede neutralizar un
hecho de riesgo grave.

---

## 3. Algoritmo de puntuación

### 3.1 Score por dimensión

Para cada dimensión D ∈ {S, ST, MX, NW, GEO, MT}:

```
raw_score_D = Σ (base_weight_i × confidence_modifier_i × context_multiplier_i)
              para cada FactEvent de tipo perteneciente a D
```

**Confidence modifier:**
- `HIGH` → × 1.0
- `MEDIUM` → × 0.85
- `LOW` → × 0.60

**Context multiplier** (refleja el principio GAFI de que la combinación de
múltiples indicadores es más significativa que cada uno por separado):
- Hecho recurrente en los últimos 30 días (mismo tipo): × 1.3
- Hecho combinado con otro hecho de la misma dimensión en el mismo caso: × 1.2
- Hecho verificado por múltiples fuentes independientes: × 1.1

Los multiplicadores son aditivos: un hecho recurrente, combinado y
multifuente tiene multiplicador total 1.6, no multiplicativo, para evitar
inflación exponencial.

### 3.2 Score agregado

```
raw_total = raw_score_S + raw_score_ST + raw_score_MX
            + raw_score_NW + raw_score_GEO − min(raw_score_MT, 40)

final_score = clamp(raw_total, 0, 100)
```

Si está presente cualquier hecho de override de la dimensión S:
`final_score = 100`, sin cálculo de las dimensiones restantes.

### 3.3 Score histórico y decaimiento temporal

El perfil de riesgo integra el historial de la wallet. Fundamento: GAFI
Rec. 10 exige monitoreo continuo que incluye el historial transaccional. Una
wallet que ayer tuvo score 80 y hoy aparece limpia no debe ser tratada como
si su historial no existiera.

```
score_final = (score_historico × decay_factor)
              + (score_presente × (1 − decay_factor))
```

- `decay_factor` default: 0.4 (40% historial, 60% hechos presentes)
- Si no existe historial previo en el oracle: `decay_factor = 0.0`

### 3.4 Actualización disparada por afterSwap

El componente acumulativo se materializa en el `afterSwap` del hook. Cada
swap ejecutado emite un evento que el motor off-chain consume y que dispara
un recálculo:

```
1. afterSwap emite SwapObserved(wallet, amountSpecified, zeroForOne,
   counterparty, poolId, blockNumber)
2. El motor incorpora el evento al historial de la wallet
3. Se re-evalúan las dimensiones ST y NW sobre la ventana actualizada
4. Se recalcula score_final con el nuevo score_presente
5. El resultado firmado se escribe en ComplianceOracle
6. El próximo beforeSwap de esa wallet lee el score actualizado
```

**Latencia declarada.** El score que lee el `beforeSwap` es el resultante
del ciclo anterior. El módulo debe registrar en `ScoreResult` el
`block_number` de última actualización, para que el expediente de evidencia
documente con precisión qué información estaba disponible al momento de cada
decisión. Esta declaración es un requisito de defensibilidad: un supervisor
debe poder verificar que la decisión fue razonable con la información
entonces disponible, no con información posterior.

### 3.5 Resistencia a manipulación

El scoring es un vector de ataque si es predecible o influenciable. Reglas
obligatorias:

1. Ningún parámetro del algoritmo se publica con sus valores efectivos por
   pool. Los rangos de salida sí son públicos; los umbrales internos, no.
2. `DENUNCIA_LP_VALIDADA` nunca puede por sí solo llevar una wallet al
   tramo de bloqueo. Su techo efectivo es el tramo de fee diferencial.
3. Los mitigantes tienen tope agregado de 40 puntos.
4. Toda modificación de parámetros gobernables se ejecuta a través del
   Timelock de la DAO y queda registrada on-chain.

---

## 4. Output del módulo

```json
{
  "wallet": "0x...",
  "score_final": 0,
  "nivel_riesgo": "BLOQUEO | ELEVADO | ESTANDAR",
  "salida_hook": "REVERT | FEE_DIFERENCIAL | ALLOW",
  "score_breakdown": {
    "sanciones": 0,
    "structuring": 0,
    "exposicion_mixer": 0,
    "comportamiento_red": 0,
    "riesgo_geografico": 0,
    "tipologias_defi": 0,
    "señales_externas": 0,
    "mitigantes": 0,
    "componente_historico": 0
  },
  "hechos_disparadores": [
    {
      "fact_id": "<id>",
      "type": "<tipo>",
      "contribucion_score": 0,
      "confidence": "HIGH | MEDIUM | LOW",
      "base_regulatoria": "<referencia GAFI / OFAC / BSA / MiCA específica>",
      "justificacion": "<explicación en lenguaje natural>",
      "evidencia_onchain": {"tx_hash": "0x...", "block_number": 0}
    }
  ],
  "flags_regulatorios": [
    {
      "tipo": "SOSPECHA_RAZONABLE_ALCANZADA | EDD_REQUERIDA | BLOQUEO_OFAC | REVISION_HUMANA_REQUERIDA | CONFIDENCE_INSUFICIENTE | ATRIBUCION_FALLIDA | SUSTENTO_EXTERNO_INSUFICIENTE | IMPUGNACION_EN_TRAMITE",
      "descripcion": "<descripción>",
      "recomendacion": "<acción recomendada>"
    }
  ],
  "vigencia": {
    "calculado_en_block": 0,
    "calculado_en": "<ISO 8601>",
    "proxima_revision": "<ISO 8601>"
  },
  "firma_oracle": "<firma ECDSA del payload score+wallet+block para verificación on-chain>",
  "audit_hash": "<SHA-256 del ScoreResult serializado>"
}
```

### 4.1 Mapeo score → salida del hook

| Rango | Nivel | Salida del hook | Fundamento regulatorio |
|---|---|---|---|
| 0–30 | **ESTÁNDAR** | `ALLOW` — fee estándar | GAFI Rec. 1 y 10: los controles deben ser proporcionales; no corresponde fricción sobre perfiles de riesgo documentadamente bajo |
| 31–70 | **ELEVADO** | `FEE_DIFERENCIAL` — 3x el fee estándar, evento emitido | GAFI Rec. 10: DDR para perfiles atípicos sin sanción confirmada. No existe obligación de bloquear; sí de monitorear y aplicar escrutinio reforzado |
| 71–99 | **BLOQUEO** | `REVERT` con razón registrada en evento | GAFI Rec. 20 y BSA: sospecha razonable alcanzada; el operador no puede procesar la operación sin controles adicionales |
| 100 | **BLOQUEO** | `REVERT` + activación de `task-blocking-protocol` | GAFI Rec. 6, IEEPA y 31 CFR Part 501: bloqueo incondicional ante designación. Sin discrecionalidad |

**Distinción crítica entre 71–99 y 100.** El tramo 71–99 es un rechazo de
la operación. El score 100 por match de sanciones no es un rechazo: es un
bloqueo. Bajo el régimen de OFAC los fondos adeudados a una parte designada
deben quedar bloqueados y segregados con rastro auditable, no simplemente
devueltos. El tratamiento operativo de esa diferencia corresponde a
`task-blocking-protocol`.

### 4.2 Umbral de sospecha razonable

El módulo señala cuándo la sospecha razonable ha sido alcanzada, pero no
presenta ningún reporte. Esa obligación requiere juicio humano y recae en el
Oficial de Cumplimiento del operador del pool.

`SOSPECHA_RAZONABLE_ALCANZADA` se emite cuando: `score_final ≥ 65` **y** al
menos dos hechos de distintas dimensiones están presentes. La combinación de
umbral de score y multiplicidad de señales implementa el estándar de sospecha
razonable basada en múltiples indicadores de la GAFI Rec. 20.

Fundamento: el umbral es sospecha razonable, no certeza. No se necesita
probar que la wallet lavó fondos para emitir la señal. Se necesita demostrar
que existe sospecha razonable basada en patrones observables y documentados.

### 4.3 Recomendación de próxima revisión

| Score | Próxima revisión |
|---|---|
| 0–20 | 90 días o 100 swaps, lo que ocurra primero |
| 21–50 | 30 días o 25 swaps |
| 51–70 | 7 días o 5 swaps |
| 71–100 | Inmediata — cada swap re-evalúa |

---

## 5. Integración con el expediente de evidencia

El `ScoreResult` se integra como sección obligatoria **"2. NIVEL DE RIESGO
Y SCORING"** del expediente generado por `task-regulatory-report`:

```
2. NIVEL DE RIESGO Y SCORING
═══════════════════════════════════════
Wallet:          0x...
Score de riesgo: [XX/100]
Nivel:           [BLOQUEO / ELEVADO / ESTÁNDAR]
Salida del hook: [REVERT / FEE_DIFERENCIAL / ALLOW]
Calculado en:    bloque [N] — [timestamp]

Breakdown por dimensión:
  Sanciones                [XX pts]
  Structuring              [XX pts]
  Exposición a mixers      [XX pts]
  Comportamiento de red    [XX pts]
  Riesgo geográfico        [XX pts]
  Mitigantes               [−XX pts]
  Componente histórico     [XX pts]

Hechos que contribuyen al score:
  1. [TIPO_HECHO] — Contribución: +XX pts — Confidence: [HIGH]
     Base regulatoria: [GAFI Rec. X / 31 CFR § XXXX / MiCA art. X]
     Evidencia on-chain: tx [0x...] — bloque [N]
     Justificación: [explicación en lenguaje natural]

Flags regulatorios:
  [FLAG_TYPE]: [descripción y recomendación]

Próxima revisión recomendada: [fecha]
Audit hash: [SHA-256]
```

El campo `base_regulatoria` en cada hecho disparador es crítico para la
defensibilidad: permite seguir la cadena desde la conclusión hasta el
estándar que la fundamenta. Un supervisor que audite el caso puede verificar
por qué cada hecho fue considerado relevante y bajo qué norma.

---

## 6. Reglas de integridad del scoring

1. **Ningún score sin justificación.** Cada punto asignado debe tener un
   hecho documentado con su `base_regulatoria` y `justificacion`. No se
   asignan puntos por inferencias no sustentadas.

2. **Los matches de sanciones son override incondicional.** No admiten
   reducción por mitigantes. El score es 100 y la salida es `REVERT` con
   activación del protocolo de bloqueo, sin excepción.

3. **Los mitigantes no pueden ocultar hechos.** Un score de 15 con
   mitigantes aplicados debe mostrar igualmente los hechos de riesgo
   detectados y su contribución bruta.

4. **Confidence LOW requiere nota explícita.** Si algún hecho disparador
   tiene `confidence: LOW`, el expediente debe indicarlo y señalar que
   requiere verificación adicional antes de acciones definitivas.

5. **El score histórico requiere cita del cálculo previo.** Si el componente
   histórico contribuye, debe indicarse el `audit_hash` y el bloque del
   `ScoreResult` anterior.

6. **Toda decisión de bloqueo exige al menos un hecho HIGH.** Un score ≥ 71
   construido exclusivamente sobre hechos MEDIUM y LOW emite
   `CONFIDENCE_INSUFICIENTE` y degrada la salida a `FEE_DIFERENCIAL`, con
   registro del hecho en el expediente.

7. **La firma del oracle es obligatoria.** Ningún score se escribe on-chain
   sin firma verificable por `SignatureVerifier`.

8. **Sin sujeto no hay score.** Si `originator-attribution` no resolvió la
   atribución, no se calcula score. No se construye perfil sobre routers,
   agregadores ni contratos de infraestructura, y no se inventa un sujeto
   para poder puntuarlo.

9. **Las señales externas no fundan un bloqueo por sí solas.** Un score en
   tramo de bloqueo exige al menos un hecho propio con `confidence: HIGH`, o
   una señal externa verificada de forma independiente contra su evidencia
   on-chain.

10. **Recepción no es uso.** Los hechos derivados de transferencias entrantes
    no solicitadas se marcan como tales y no computan como comportamiento de
    la wallet receptora.

---

## 7. Parámetros gobernables vs. inmutables

### Inmutables

- Override incondicional ante matches en listas de sanciones
- El mapeo score → salida del hook (0–30 / 31–70 / 71–100)
- La obligación de emitir `audit_hash` y `firma_oracle` en cada ScoreResult
- El umbral de dos dimensiones para `SOSPECHA_RAZONABLE_ALCANZADA`
- La regla 6 (bloqueo exige al menos un hecho HIGH)
- El tope agregado de mitigantes

### Gobernables mediante Timelock de la DAO

| Parámetro | Default | Justificación para ajuste |
|---|---|---|
| `umbral_reporte_usd` | 10.000 USD | Ajustable según el perfil de riesgo del pool y el marco aplicable al operador |
| `ventana_structuring_dias` | 30 días | Pools con alta frecuencia de swaps pequeños pueden requerir ventana más larga |
| `min_splits_structuring` | 3 | Ajustable para reducir falsos positivos en pools de alta rotación |
| `velocity_spike_multiplier` | 5x | Pools con volumen naturalmente variable pueden requerir factor más alto |
| `mixer_lookback_dias` | 90 días | Extendible según la política de cobertura histórica |
| `decay_factor` | 0.4 | Ajustable según la política de memoria sobre wallets |
| `sospecha_score_threshold` | 65 | Ajustable según la política interna del operador |
| `wallet_nueva_umbral_usd` | 5.000 USD | Ajustable según el ticket promedio del pool |
| `fee_multiplier_tramo_medio` | 3x | Ajustable dentro del rango habilitado por gobernanza |
| `denuncia_lp_threshold` | 3 denuncias independientes | Ajustable según la cantidad de LPs del pool |
| `politica_atribucion` | restrictiva | Decisión de producto del operador; ver `originator-attribution` |
| `peso_señal_externa_no_verificada` | 0.5 | Ajustable según la confianza en el registro compartido |
| `umbral_reputacion_degradacion_pool` | Configurable | Punto en el que un pool emisor entra en estado degradado |
| `challenge_denuncia_horas` | 72 | Período de descargo de la wallet denunciada |
| `revision_periodica_bloqueos_dias` | Configurable | Control de proporcionalidad de bloqueos sostenidos |

---

*AML Hook — Compliance Officer Agent — fact-scoring SKILL v2.0*

*Referencias normativas:*
*FATF (2020). Virtual Assets Red Flag Indicators of Money Laundering and Terrorist Financing. París: FATF/OECD.*
*FATF (2021). Updated Guidance for a Risk-Based Approach to Virtual Assets and VASPs. París: FATF/OECD.*
*FATF (2023). The FATF Recommendations. París: FATF/OECD.*
*OFAC (2021). Sanctions Compliance Guidance for the Virtual Currency Industry. Washington: U.S. Department of the Treasury.*
*FinCEN (2019). Application of FinCEN's Regulations to Certain Business Models Involving Convertible Virtual Currencies. FIN-2019-G001.*
*Reglamento (UE) 2023/1114 (MiCA) y Reglamento (UE) 2023/1113 (TFR).*
