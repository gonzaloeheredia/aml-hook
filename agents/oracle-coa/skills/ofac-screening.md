---
name: ofac-screening
description: "Verificar si una dirección, su cluster, sus controladores o sus contrapartes están alcanzados por sanciones internacionales. Cubre OFAC SDN (Estados Unidos), listas del Consejo de Seguridad de la ONU y listas consolidadas de la Unión Europea, incluidos contratos inteligentes designados. Usar en toda evaluación de wallet, con prioridad sobre cualquier otro análisis: un match de sanciones es override incondicional y detiene el flujo."
---

# OFAC Screening — Verificación de Sanciones

## Rol en el agente

Esta skill verifica si existe coincidencia entre una dirección y las listas
de sanciones vigentes. Clasifica el hallazgo, determina si es un verdadero
positivo y activa la acción obligatoria. No decide por sí misma la salida
del swap: emite el `FactEvent` de override y deriva a
`task-blocking-protocol`.

Es la Capa 1 de la arquitectura del hook: rápida, de bajo costo en gas y sin
dependencia externa en tiempo de ejecución. El mapping on-chain de
direcciones designadas se consulta directamente en el `beforeSwap`.

---

## Inputs esperados

| Campo | Descripción |
|---|---|
| `address` | Dirección bajo verificación |
| `tipo_cuenta` | Output de `wallet-screening` Paso 1 |
| `controllers` | Controladores, si se trata de una Smart Account |
| `cluster_name` | Entidad atribuida por el motor de analytics |
| `contrapartes_directas` | Direcciones con las que la wallet interactuó directamente |
| `contratos_interactuados` | Contratos con los que la wallet interactuó |
| `resultado_oracle` | Output del mapping on-chain de direcciones designadas |

---

## Paso 1: Listas aplicables

| Lista | Emisor | Alcance |
|---|---|---|
| SDN List (Specially Designated Nationals) | OFAC — Departamento del Tesoro de Estados Unidos | Alcance amplio: transacciones en USD, con nexo estadounidense, o con participación de personas estadounidenses |
| Non-SDN listas sectoriales (SSI, CAPTA, NS-MBS) | OFAC | Restricciones parciales según programa; no implican bloqueo total |
| Consolidated Sanctions List | Consejo de Seguridad de la ONU | Universal |
| Consolidated List of Persons, Groups and Entities | Unión Europea | Obligatorio para entidades sujetas al derecho de la Unión y para operaciones con nexo UE |

**Direcciones y contratos designados.** Desde 2018 OFAC incorpora
direcciones de activos virtuales de forma expresa en la SDN. En agosto de
2022 designó por primera vez un contrato inteligente en su totalidad
(Tornado Cash), extendiendo la lógica de designación de personas a código
autónomo. La skill debe verificar tanto direcciones de wallet como
direcciones de contrato.

---

## Paso 2: Clasificación del hallazgo

| Categoría | Criterio |
|---|---|
| **Verdadero positivo directo** | La dirección exacta figura en una lista vigente |
| **Verdadero positivo por cluster** | La dirección pertenece a un cluster atribuido por el motor de analytics a una entidad designada |
| **Exposición indirecta** | La dirección interactuó con una dirección designada, sin figurar ella misma |
| **Falso positivo** | Coincidencia superficial descartada con fundamento explícito |

En direcciones no existe ambigüedad de transliteración ni homonimia: el
match de una dirección exacta es determinístico. La ambigüedad aparece en
dos supuestos, que deben documentarse con especial cuidado:

1. **Atribución de cluster.** Depende del criterio del proveedor de
   analytics y no es verificable de forma independiente por el operador.
   Corresponde `confidence: MEDIUM`, salvo confirmación por segunda fuente.
2. **Identificación de controladores de Smart Accounts.** La correspondencia
   entre un controlador y una persona designada por nombre requiere una
   inferencia externa a la cadena. Corresponde revisión humana.

No se descarta ningún hallazgo sin fundamento explícito registrado.

---

## Paso 3: Exposición indirecta

La exposición indirecta no es un match, pero tampoco es irrelevante. La guía
de OFAC para la industria de moneda virtual expresa la expectativa de
monitoreo de exposición, no solo de coincidencia directa.

| Situación | Tratamiento |
|---|---|
| Contraparte directa designada | `MATCH_INDIRECTO_CONTRAPARTE` (+50). No es override, pero por sí solo ubica a la wallet en el tramo de riesgo elevado o superior |
| Interacción con contrato designado | `CONTRATO_SANCIONADO_DIRECTO` — override. La interacción con un contrato designado es una operación con una entidad designada |
| Fondos con exposición indirecta a distancia mayor a un salto | Se pondera por porcentaje de exposición y cantidad de saltos; alimenta la dimensión GEO o NW según corresponda |

**Umbral de materialidad.** La exposición indirecta por debajo de un
porcentaje mínimo configurable no genera `FactEvent`, para evitar que la
contaminación difusa del ecosistema produzca falsos positivos masivos. El
umbral es un parámetro gobernable y debe justificarse bajo el EBR.

---

## Paso 4: Jurisdicciones restringidas

Verificar si el origen o el destino inferido está asociado a:

- Programas de sanciones comprehensivas por país
- Programas sectoriales
- Lista negra del GAFI (jurisdicciones de alto riesgo sujetas a
  contramedidas)
- Lista gris del GAFI (jurisdicciones bajo monitoreo reforzado)

La atribución jurisdiccional de una wallet es inferencial. Todo hallazgo de
este paso debe declarar la base de la inferencia y no admite
`confidence: HIGH` salvo atribución documentada.

---

## Paso 5: Acción obligatoria

| Resultado | Acción |
|---|---|
| Falso positivo documentado | Continuar el análisis; registrar la verificación y su fundamento |
| Exposición indirecta por debajo del umbral | Registrar sin emitir FactEvent |
| Exposición indirecta material | Emitir `MATCH_INDIRECTO_CONTRAPARTE`; continuar el análisis |
| Verdadero positivo por cluster | Emitir `VINCULO_CLUSTER_SANCIONADO`; elevar a revisión humana |
| Programa sectorial (no SDN) | La operación específica puede o no estar prohibida. Elevar a revisión humana antes de procesar |
| Verdadero positivo directo | Emitir override. Score 100. Salida `REVERT`. Activar `task-blocking-protocol` de forma inmediata |

**Regla de precedencia.** Esta skill se ejecuta antes que cualquier otra
skill de dominio. Un match directo detiene el flujo: no se completa
`swap-behavior-analysis` ni `typology-detection`, porque el resultado no
puede modificarse.

---

## Paso 6: Registro de la verificación negativa

Un screening sin hallazgos es un resultado que debe registrarse. La
defensibilidad del sistema depende de poder demostrar que la verificación se
ejecutó, contra qué listas, en qué versión y en qué momento.

Cada verificación registra:

| Campo | Contenido |
|---|---|
| Listas consultadas | Identificación de cada lista |
| Versión o fecha de la lista | Fecha de la última actualización del registro consultado |
| Bloque de consulta | Bloque en el que se ejecutó la verificación on-chain |
| Resultado | Sin hallazgos / hallazgos y su clasificación |
| Fuente | Oracle on-chain / API del proveedor / registro público |

**Antigüedad de las listas.** Si la última actualización del registro
on-chain supera el período máximo configurado, la skill emite
`LISTA_DESACTUALIZADA` y el operador debe decidir si opera en modo degradado
o suspende el pool. Un screening contra una lista vencida no satisface el
estándar.

---

## Output estructurado

```json
{
  "address": "0x...",
  "hits": [
    {
      "lista": "OFAC_SDN | ONU | UE | OFAC_SECTORIAL",
      "entrada": "...",
      "objeto_del_match": "DIRECCION | CONTRATO | CLUSTER | CONTROLADOR",
      "clasificacion": "verdadero-positivo-directo | verdadero-positivo-cluster | exposicion-indirecta | falso-positivo",
      "confidence": "HIGH | MEDIUM | LOW",
      "fundamento": "..."
    }
  ],
  "exposicion_indirecta": {
    "detectada": false,
    "porcentaje": 0,
    "hops": 0,
    "supera_umbral_materialidad": false
  },
  "jurisdiccion_restringida": {
    "detectada": false,
    "base_inferencia": "...",
    "programa": "..."
  },
  "verificacion": {
    "listas_consultadas": ["..."],
    "fecha_ultima_actualizacion_lista": "...",
    "block_number_consulta": 0,
    "lista_desactualizada": false
  },
  "override_activado": false,
  "accion_requerida": "continuar | revision-humana | revert | bloquear-y-segregar",
  "facts_emitidos": [],
  "siguiente_skill": "task-blocking-protocol | wallet-screening | fact-scoring"
}
```

> Ante verdadero positivo directo en SDN, ONU o UE, o ante interacción con
> contrato designado, esta skill activa `task-blocking-protocol` con
> prioridad crítica. La salida del hook es `REVERT`, y el tratamiento de los
> fondos afectados no es una devolución simple: corresponde bloqueo y
> segregación con rastro auditable.
