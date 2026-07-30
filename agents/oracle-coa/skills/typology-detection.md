---
name: typology-detection
description: "Identificar a qué tipología AML/CFT documentada corresponde el comportamiento observado de una wallet, y anclarla en el indicador de alerta del GAFI que la define. Traduce hallazgos técnicos on-chain a categorías regulatorias reconocidas por supervisores. Usar después de wallet-screening y swap-behavior-analysis, antes de fact-scoring: es el paso que convierte evidencia técnica en fundamento normativo."
---

# Typology Detection — Identificación de Tipologías AML/CFT

## Rol en el agente

Esta skill responde a una pregunta específica: cómo se llama, en el
vocabulario de un supervisor, lo que el análisis técnico detectó. Sin esta
traducción, el expediente contiene métricas on-chain que un regulador no
tiene obligación de interpretar. Con ella, contiene tipologías reconocidas
con su indicador de alerta de referencia.

No produce score ni decide la salida del swap. Produce la clasificación y el
anclaje normativo que `fact-scoring` incorpora en el campo
`base_regulatoria` de cada hecho disparador.

---

## Inputs esperados

| Campo | Descripción |
|---|---|
| `output_wallet_screening` | Resultado de `wallet-screening` |
| `output_swap_behavior` | Resultado de `swap-behavior-analysis` |
| `patrones_detectados` | Listado consolidado de patrones técnicos |
| `contexto_pool` | Tipo de pool, par de activos, perfil de liquidez |

---

## Marco de referencia

Las seis categorías de indicadores de alerta del Informe GAFI sobre Activos
Virtuales (2020) son el eje de clasificación. Toda tipología identificada
debe mapearse a al menos una categoría.

| Categoría | Contenido |
|---|---|
| **1** | Tamaño y frecuencia de transacciones |
| **2** | Patrones de transacciones |
| **3** | Anonimato |
| **4** | Perfil de remitentes y beneficiarios |
| **5** | Origen de fondos |
| **6** | Riesgos geográficos |

**Principio metodológico.** La presencia de un único indicador no permite
concluir actividad ilícita. Es la combinación de indicadores sin explicación
económica lo que sustenta la sospecha. La skill debe informar cuántos
indicadores concurren y de qué categorías, porque esa multiplicidad es
precisamente lo que fundamenta el estándar de sospecha razonable.

---

## Paso 1: Catálogo de tipologías

### 1.1 Fraccionamiento y estructuración

| Tipología | Definición | Categoría GAFI | Evidencia on-chain requerida |
|---|---|---|---|
| **Structuring** | División deliberada de un monto en operaciones menores para evitar umbrales de reporte | 1 | Serie de swaps con suma acumulada por encima del umbral y ninguno individual que lo supere, en ventana acotada |
| **Smurfing** | Structuring distribuido entre múltiples wallets coordinadas | 1, 2 | Wallets vinculadas por financiamiento común o co-spending con patrón homogéneo y sincronía temporal |
| **Proximidad deliberada al umbral** | Montos concentrados apenas por debajo del umbral conocido | 1 | Distribución de montos con moda entre el 80% y el 99% del umbral |

### 1.2 Estratificación y ocultamiento del rastro

| Tipología | Definición | Categoría GAFI | Evidencia on-chain requerida |
|---|---|---|---|
| **Layering** | Sucesión de operaciones cuyo propósito es alejar los fondos de su origen | 2, 3 | Hop count elevado con intervalos comprimidos, sin lógica económica |
| **Chain-hopping** | Movimiento entre cadenas para romper la trazabilidad | 2, 3 | Tránsito por tres o más redes en menos de 24 horas antes del swap |
| **Peeling chain** | División progresiva de un monto a través de wallets intermediarias | 1, 2 | Cadena de transacciones con reducción sucesiva de monto |
| **Uso de mixer** | Empleo de un servicio cuyo único propósito funcional es cortar la trazabilidad | 3 | Interacción documentada con contrato de mezcla |
| **Post-mixer timing** | Operación ejecutada inmediatamente después de una interacción con mixer | 3 | Swap dentro de la ventana posterior configurada |

### 1.3 Origen ilícito de fondos

| Tipología | Definición | Categoría GAFI | Evidencia on-chain requerida |
|---|---|---|---|
| **Fondos de darknet** | Fondos rastreables a mercados ilícitos | 5 | Atribución de cluster por el motor de analytics |
| **Fondos de ransomware** | Fondos rastreables a esquemas de extorsión | 5 | Atribución de cluster |
| **Producto de exploit** | Fondos provenientes de un incidente documentado | 5 | Trazabilidad a direcciones asociadas al exploit |
| **Recirculación de fondos robados** | Reingreso al ecosistema de fondos con origen ilícito conocido, tras estratificación | 3, 5 | Combinación de trazabilidad al incidente y patrones de layering |

### 1.4 Esquemas de fraude en DeFi

| Tipología | Definición | Categoría GAFI | Evidencia on-chain requerida |
|---|---|---|---|
| **Exit liquidity scheme** | Extracción de liquidez del pool mediante una operación preparada | 2, 4 | Wallet nueva, volumen anómalo, concentración de contraparte, velocity elevada |
| **Wash trading** | Operaciones entre wallets vinculadas para simular volumen | 2, 4 | Swaps recíprocos entre direcciones con vinculación establecida |
| **Preparación de wallets intermediarias** | Creación de apariencia de actividad previa a un ataque | 2, 4 | Cluster de micro-transferencias entrantes unidireccionales |

### 1.5 Anonimato y contrapartes opacas

| Tipología | Definición | Categoría GAFI | Evidencia on-chain requerida |
|---|---|---|---|
| **Conversión a privacy coin** | Salida hacia activos de privacidad mejorada sin justificación | 3 | Traza de conversión sin correlato económico |
| **Contraparte sin controles** | Fondos provenientes de un servicio centralizado sin verificación de identidad | 3, 4 | Atribución de cluster a servicio sin controles documentados |
| **Origen opaco mayoritario** | Proporción relevante de fondos sin origen atribuible | 5 | Porcentaje de fondos no rastreables por encima del umbral |

### 1.6 Tipologías nativas del entorno DeFi

Estas tipologías no tienen equivalente en banca tradicional y son invisibles para todo catálogo construido sobre operatoria fiat. Su detección requiere lectura del estado del pool y de la mecánica del protocolo, no solo del flujo de fondos.

| Tipología | Definición | Categoría GAFI | Evidencia on-chain requerida |
|---|---|---|---|
| **Swap de claims internos ERC-6909** | Operación ejecutada sobre saldos internos del PoolManager, sin transferencia real de ERC-20. No invoca la función `transfer` del token y por lo tanto queda fuera del alcance de los mecanismos de bloqueo del emisor | 3, 5 | Swap con liquidación por `mint` o `burn` de claims sin `Transfer` del ERC-20 subyacente |
| **Extracción por sandwich** | Operaciones de compra y venta que encierran la de un tercero para capturar el diferencial de precio | 2, 4 | Dos operaciones de la misma dirección o de direcciones vinculadas en el mismo bloque, envolviendo una operación ajena |
| **Manipulación por flash loan** | Préstamo sin colateral usado para alterar el precio del pool dentro de una única transacción | 2, 5 | Préstamo, swap de alto impacto y repago en la misma transacción |
| **Rug pull por retiro de liquidez** | Retiro coordinado de liquidez que deja el pool sin profundidad | 2, 4 | Remoción de posición de magnitud anómala precedida de acumulación |
| **Wash trading con posiciones de LP** | Operaciones recíprocas que simulan volumen o generan pérdidas y ganancias artificiales entre direcciones vinculadas | 2, 4 | Swaps recíprocos con vinculación establecida y sin resultado económico neto |
| **Drenaje por aprobación de token** | Uso de una aprobación previamente concedida para extraer fondos de la wallet de la víctima | 5 | `transferFrom` ejecutado por un tercero sobre saldo de la víctima, seguido de swap |
| **Address poisoning y dust** | Envío de transferencias mínimas desde direcciones de apariencia similar, para inducir un error de copia en el destinatario | 2, 4 | Transferencias de valor despreciable desde direcciones con prefijo y sufijo coincidentes con contrapartes habituales |
| **Estratificación mediante NFT** | Compra y venta de activos no fungibles a precios arbitrarios como vehículo de transferencia de valor | 2, 3 | Operaciones NFT con precio desconectado del mercado de la colección, entre direcciones vinculadas |
| **Salto de cadena vía exchange centralizado** | Uso de un exchange como puente para romper la trazabilidad, en lugar de un bridge | 2, 3 | Depósito en dirección atribuida a exchange y reaparición de valor equivalente en otra red en ventana corta |
| **Ingreso de producto de estafa de inversión** | Fondos provenientes de esquemas de fraude a largo plazo con víctimas individuales | 5 | Convergencia de múltiples remitentes no relacionados hacia una wallet, con patrón de montos y frecuencia característico |
| **Evasión de sanciones por actor estatal** | Patrones documentados de grupos vinculados a Estados sancionados: fragmentación sistemática, uso intensivo de bridges, conversión inmediata a activos de privacidad | 3, 5, 6 | Combinación de exposición a exploits documentados, velocidad de estratificación y uso de infraestructura de anonimización |

**Nota sobre el swap de claims internos ERC-6909.** Esta tipología merece tratamiento diferenciado porque describe un punto ciego arquitectónico, no una conducta. El PoolManager de Uniswap v4 mueve saldos internamente mediante claims sin invocar `transfer` del token subyacente. Los mecanismos de bloqueo que el emisor de un activo implementa dentro de la función `transfer` de su ERC-20 se ejecutan únicamente en el perímetro del PoolManager, al entrar y al salir. Las operaciones internas quedan fuera de su alcance.

La consecuencia es que un activo con controles de transferencia a nivel de token no está controlado dentro del pool. El hook es el único punto arquitectónico que cubre ese espacio, porque intercepta la operación donde efectivamente ocurre. Toda evaluación de un pool con activos que implementan controles a nivel de token debe registrar si la operatoria interna está cubierta y por qué medio.

### 1.7 Riesgo geográfico

| Tipología | Definición | Categoría GAFI | Evidencia on-chain requerida |
|---|---|---|---|
| **Exposición a jurisdicción de alto riesgo** | Fondos con origen o destino inferido en jurisdicción listada por el GAFI | 6 | Atribución jurisdiccional documentada con base de inferencia declarada |
| **Nexo con régimen de sanciones comprehensivas** | Exposición a país bajo programa comprehensivo | 6 | Atribución documentada |

---

## Paso 2: Evaluación de explicación alternativa

Antes de confirmar una tipología, evaluar si existe una explicación
económica legítima. Este paso es obligatorio y su resultado se registra: un
expediente que no documenta haber considerado la hipótesis alternativa es
más débil ante un supervisor que uno que la descarta con fundamento.

| Patrón detectado | Explicación legítima posible | Criterio de descarte |
|---|---|---|
| Muchos swaps pequeños | Estrategia de ejecución fraccionada para reducir impacto de precio o slippage | El fraccionamiento por slippage se correlaciona con la profundidad de liquidez del pool; el structuring se correlaciona con el umbral de reporte |
| Alta velocidad de operación | Arbitraje o market making | El arbitraje presenta operaciones bidireccionales y correlación con desvíos de precio entre venues |
| Wallet nueva con volumen alto | Wallet nueva de una entidad establecida | Existencia de financiamiento desde una dirección con historial verificable |
| Uso de bridge previo | Búsqueda de liquidez o yield en otra red | Un solo bridge con permanencia de fondos en destino difiere de bridges encadenados inmediatos |
| Concentración de contraparte | Estrategia especializada en un único protocolo | La estrategia especializada mantiene diversidad de contrapartes dentro del protocolo |
| Dos operaciones envolviendo una ajena | Provisión de liquidez o rebalanceo coincidente en el bloque | El sandwich exhibe dirección opuesta entre ambas patas y resultado neto positivo a costa de la operación encerrada |
| Flash loan con swap de alto impacto | Arbitraje legítimo entre venues, liquidación de una posición en riesgo | El arbitraje deja el precio del pool más cerca del precio de referencia externo; la manipulación lo aleja |
| Retiro masivo de liquidez | Rebalanceo de cartera o salida por cambio de estrategia | El rug pull se precede de acumulación concentrada y coincide con actividad de las wallets vinculadas |
| Operaciones NFT a precio atípico | Mercado ilíquido con formación de precio irregular | La estratificación exhibe contrapartes vinculadas y ausencia de exposición real al riesgo de precio |
| Recepción de fondos desde múltiples remitentes | Actividad comercial legítima, recaudación, nómina | El producto de estafa presenta remitentes sin relación entre sí, montos en rangos característicos y ausencia de contraprestación identificable |
| Transferencias entrantes de valor despreciable | Airdrop, prueba de red, error | El envenenamiento de direcciones exhibe coincidencia de prefijo y sufijo con contrapartes habituales del receptor |

Si la explicación alternativa es plausible y no puede descartarse, la
tipología se registra con `confidence: LOW` y la skill lo declara. No se
suprime el hallazgo: se pondera.

---

## Paso 3: Consolidación

Producir el listado de tipologías confirmadas, con:

1. Nombre de la tipología
2. Categoría o categorías de indicador GAFI
3. Evidencia on-chain concreta con `tx_hash` y bloque
4. Explicación alternativa considerada y motivo de su descarte
5. Nivel de confidence

**Conteo de multiplicidad.** La skill informa cuántas categorías GAFI
distintas concurren. Este dato es el que sustenta el umbral de sospecha
razonable de `fact-scoring` sección 4.2.

---

## Output estructurado

```json
{
  "address": "0x...",
  "tipologias_identificadas": [
    {
      "tipologia": "structuring | smurfing | layering | chain-hopping | peeling | mixer | post-mixer-timing | darknet | ransomware | exploit | exit-liquidity | wash-trading | preparacion-wallets | privacy-coin | contraparte-opaca | origen-opaco | claims-internos-6909 | sandwich | flash-loan-manipulacion | rug-pull | wash-trading-lp | drenaje-aprobacion | address-poisoning | estratificacion-nft | salto-cadena-cex | producto-estafa-inversion | evasion-sanciones-estatal | geo-alto-riesgo",
      "categorias_gafi": [1, 2],
      "referencia": "Informe GAFI 2020 — Categoría X; GAFI Rec. Y",
      "evidencia": [
        {"descripcion": "...", "tx_hash": "0x...", "block_number": 0}
      ],
      "explicacion_alternativa_evaluada": "...",
      "motivo_descarte": "...",
      "confidence": "HIGH | MEDIUM | LOW"
    }
  ],
  "categorias_gafi_concurrentes": 0,
  "multiplicidad_suficiente_sospecha": false,
  "cobertura_claims_internos": {
    "activo_con_controles_a_nivel_token": false,
    "operatoria_interna_cubierta_por_hook": true,
    "observacion": "..."
  },
  "tipologias_descartadas": [
    {"tipologia": "...", "motivo": "explicación económica legítima verificada"}
  ],
  "facts_emitidos": [],
  "siguiente_skill": "fact-scoring"
}
```

> Esta skill no concluye que exista lavado de activos. Concluye que el
> comportamiento observado corresponde a una tipología documentada y que
> concurren N indicadores de alerta. La calificación de una operación como
> sospechosa es una decisión del Oficial de Cumplimiento del operador del
> pool, no del agente.
