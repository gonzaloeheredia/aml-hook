---
name: model-validation
description: "Validar y documentar el desempeño del sistema de scoring: justificación de umbrales bajo el enfoque basado en riesgo, backtesting contra casos conocidos, medición de falsos positivos y negativos, análisis de sensibilidad de parámetros, detección de deriva del modelo y prueba independiente. Usar de forma periódica, ante toda modificación de parámetros gobernables, y antes de responder un due diligence de un protocolo cliente o un requerimiento de supervisor."
---

# Model Validation — Validación del Sistema de Scoring

## Rol en el agente

Un supervisor examina primero el sistema y después los casos. La pregunta que precede a cualquier otra es cómo se sabe que los umbrales funcionan.

Esta skill produce la evidencia que responde esa pregunta. Sin ella el paquete emite puntajes sin poder acreditar su calibración, lo cual es un incumplimiento del estándar de prueba independiente que la BSA exige a un programa AML y una debilidad directa frente a la exigencia del GAFI de que los controles sean proporcionales al riesgo identificado y estén fundados.

Es también el material con el que se responde el due diligence de un protocolo que evalúa integrar el hook.

---

## Inputs esperados

| Campo | Descripción |
|---|---|
| `periodo` | Ventana bajo validación |
| `pool_ids` | Pools incluidos |
| `scores_emitidos` | Serie de `ScoreResult` del período con su breakdown |
| `decisiones_ejecutadas` | Serie de outputs de `task-swap-decision` |
| `casos_etiquetados` | Conjunto de wallets con clasificación conocida ex post |
| `parametros_vigentes` | Valores efectivos de los parámetros gobernables |
| `historial_parametros` | Modificaciones ejecutadas y su fundamento |
| `disputas_resueltas` | Output de `dispute-remediation` del período |

---

## Paso 1: Justificación de umbrales

Cada parámetro gobernable debe tener un fundamento documentado. Un umbral sin justificación es arbitrario, y un control arbitrario no satisface el enfoque basado en riesgo.

Para cada parámetro, documentar:

| Elemento | Contenido |
|---|---|
| Valor vigente | |
| Fundamento normativo | Estándar o recomendación que orienta el valor |
| Fundamento empírico | Datos del pool que sustentan la calibración |
| Alternativas evaluadas | Valores considerados y motivo de su descarte |
| Fecha de última revisión | |
| Responsable de la decisión | Operador, DAO o Oficial de Cumplimiento |

**Ejemplo de fundamentación esperada.** El umbral de reporte no se justifica diciendo que es el habitual. Se justifica indicando el marco que lo orienta, la distribución de montos observada en el pool, la proporción de operaciones que quedan por encima y por debajo, y el efecto medido sobre la tasa de detección al moverlo.

---

## Paso 2: Conjunto de casos etiquetados

El backtesting requiere casos con clasificación conocida. Fuentes admisibles:

| Fuente | Tipo de etiqueta |
|---|---|
| Direcciones designadas con fecha de designación | Positivo confirmado, con momento conocido |
| Direcciones asociadas a exploits documentados | Positivo confirmado |
| Wallets identificadas en investigaciones públicas | Positivo confirmado |
| Disputas resueltas a favor del participante | Negativo confirmado |
| Wallets institucionales verificadas por el operador | Negativo confirmado |
| Casos sintéticos construidos por el operador | Positivo o negativo, con la advertencia de que son sintéticos |

**Requisito de honestidad temporal.** El backtesting debe evaluar qué habría producido el sistema con la información disponible en el momento del hecho, no con la información posterior. Una dirección designada en marzo no puede computarse como acierto si el modelo la detectó porque leyó la lista de abril. La skill debe reconstruir el estado de las fuentes en la fecha evaluada y declararlo.

Esta es la validación que más valor tiene y la más difícil de hacer bien: demuestra capacidad de detección anticipada, que es la promesa central del scoring conductual frente a los sistemas basados en listas.

---

## Paso 3: Métricas de desempeño

| Métrica | Definición | Relevancia |
|---|---|---|
| **Tasa de verdaderos positivos** | Positivos confirmados que el sistema ubicó en tramo de bloqueo o elevado | Capacidad de detección |
| **Tasa de falsos positivos** | Negativos confirmados que el sistema ubicó en tramo de bloqueo | Costo sobre usuarios legítimos y fuente de disputas |
| **Tasa de falsos negativos** | Positivos confirmados que el sistema ubicó en tramo estándar | Exposición del operador |
| **Detección anticipada** | Positivos que el sistema elevó antes de la designación o del incidente | Diferencial frente a sistemas de listas |
| **Anticipación media** | Tiempo entre la elevación del score y la confirmación externa | Magnitud del diferencial |
| **Distribución de scores** | Histograma por tramo | Detecta concentración anómala en un tramo |
| **Contribución por dimensión** | Peso efectivo de cada dimensión en los scores del período | Detecta dimensiones inertes o dominantes |
| **Cobertura de atribución** | Proporción de swaps con originador atribuido | Indicador de alcance real del monitoreo |
| **Tasa de degradación** | Casos en que la salida se degradó por confidence insuficiente o gap crítico | Calidad del expediente |

**Asimetría de costos.** Un falso negativo expone al operador a responsabilidad regulatoria. Un falso positivo bloquea a un participante legítimo, genera una disputa y erosiona la adopción. No son equivalentes y el sistema no debe optimizar una sola. La validación informa ambas y el operador decide el punto de equilibrio, que se documenta como decisión de política.

---

## Paso 4: Análisis de sensibilidad

Para cada parámetro gobernable, medir el efecto de moverlo sobre las métricas del Paso 3, manteniendo el resto constante.

| Parámetro | Efecto a observar |
|---|---|
| `umbral_reporte_usd` | Detección de structuring y volumen de falsos positivos |
| `ventana_structuring_dias` | Detección de fraccionamiento lento frente a ruido de alta frecuencia |
| `min_splits_structuring` | Sensibilidad frente a operadores de alta rotación legítima |
| `velocity_spike_multiplier` | Falsos positivos sobre arbitrajistas y market makers |
| `decay_factor` | Persistencia del historial y capacidad de rehabilitación de una wallet |
| `sospecha_score_threshold` | Volumen de expedientes formales generados |
| `profundidad_hops` | Cobertura de exposición indirecta y costo computacional |
| `denuncia_lp_threshold` | Resistencia a denuncias coordinadas maliciosas |

Un parámetro cuyo movimiento no altera ninguna métrica es un parámetro inerte, y su presencia sugiere que la dimensión asociada no está funcionando. La skill debe señalarlo.

---

## Paso 5: Detección de deriva

El comportamiento del pool cambia. Un modelo calibrado sobre una distribución que ya no existe produce resultados sistemáticamente sesgados.

| Indicador de deriva | Señal |
|---|---|
| Desplazamiento de la distribución de montos del pool | Los umbrales absolutos pierden correspondencia con el perfil real |
| Cambio en la mediana de antigüedad de las wallets | Las métricas relativas de `swap-behavior-analysis` se desplazan |
| Variación sostenida en la proporción de cada tramo | Posible descalibración |
| Aumento de disputas resueltas a favor del participante | Falsos positivos en crecimiento |
| Caída de la cobertura de atribución | Cambio en los canales de acceso al pool |
| Aumento de eventos en modo degradado | Deterioro de las fuentes |

Ante deriva detectada, la skill propone recalibración con su fundamento. No la ejecuta: toda modificación de parámetros gobernables pasa por Timelock de la DAO.

---

## Paso 6: Prueba independiente

El estándar exige que quien valida no sea quien opera. La skill produce el paquete que un tercero necesita para revisar el sistema sin acceso a los parámetros efectivos, que son competitivamente sensibles.

| Contenido del paquete | Detalle |
|---|---|
| Metodología | Estructura de dimensiones, algoritmo, reglas de override e integridad |
| Métricas del período | Resultados del Paso 3 |
| Distribuciones | Histogramas y series, sin exponer valores de umbral |
| Casos de prueba reproducibles | Entradas sintéticas y salidas esperadas |
| Registro de cambios | Modificaciones de parámetros con fundamento y bloque |
| Limitaciones declaradas | Gaps conocidos del modelo |

**Separación entre transparencia y superficie de ataque.** El paquete debe permitir auditar el sistema sin permitir calibrar el comportamiento para eludirlo. La regla operativa es que la metodología es pública y los valores efectivos de umbral no lo son. Un revisor puede verificar que el método es razonable; un actor adversario no puede deducir a qué monto quedarse por debajo.

---

## Paso 7: Limitaciones estructurales a declarar

Toda validación honesta declara qué no puede hacer el sistema. Omitirlo es lo que un supervisor sanciona.

| Limitación | Contenido |
|---|---|
| Ausencia de identidad | El sistema evalúa comportamiento, no personas. Un actor con múltiples wallets no correlacionadas presenta perfiles independientes |
| Latencia del score | El `beforeSwap` lee el resultado del ciclo anterior. Existe una ventana entre el comportamiento y su reflejo en el score |
| Dependencia de terceros | La atribución de cluster es un juicio de un proveedor comercial, no verificable de forma independiente |
| Profundidad finita | El análisis de exposición se detiene en la profundidad configurada |
| Cobertura de atribución | Las operaciones no atribuidas quedan fuera del monitoreo, cualquiera sea la política aplicada |
| Adversario adaptativo | Un actor que conoce la metodología puede diseñar comportamiento por debajo de los umbrales |

---

## Output estructurado

```json
{
  "periodo": {"desde": "...", "hasta": "..."},
  "pools": ["0x..."],
  "justificacion_umbrales": [
    {
      "parametro": "...",
      "valor": null,
      "fundamento_normativo": "...",
      "fundamento_empirico": "...",
      "alternativas_evaluadas": ["..."],
      "ultima_revision": "...",
      "responsable": "..."
    }
  ],
  "backtesting": {
    "casos_evaluados": 0,
    "positivos_confirmados": 0,
    "negativos_confirmados": 0,
    "reconstruccion_temporal_aplicada": true,
    "tasa_verdaderos_positivos": 0.0,
    "tasa_falsos_positivos": 0.0,
    "tasa_falsos_negativos": 0.0,
    "deteccion_anticipada": 0,
    "anticipacion_media_dias": 0.0
  },
  "distribucion": {
    "por_tramo": {"estandar": 0, "elevado": 0, "bloqueo": 0},
    "contribucion_por_dimension": {"S": 0.0, "ST": 0.0, "MX": 0.0, "NW": 0.0, "GEO": 0.0, "MT": 0.0},
    "cobertura_atribucion_pct": 0.0,
    "tasa_degradacion_pct": 0.0
  },
  "sensibilidad": [
    {"parametro": "...", "delta_aplicado": "...", "efecto_tvp": 0.0, "efecto_tfp": 0.0, "inerte": false}
  ],
  "deriva": {
    "detectada": false,
    "indicadores": ["..."],
    "recalibracion_propuesta": [
      {"parametro": "...", "valor_actual": null, "valor_propuesto": null, "fundamento": "..."}
    ]
  },
  "prueba_independiente": {
    "paquete_generado": true,
    "revisor": null,
    "fecha": null,
    "hallazgos": []
  },
  "limitaciones_declaradas": ["..."],
  "conclusion": "sistema-adecuado | requiere-recalibracion | requiere-revision-metodologica",
  "audit_hash": "..."
}
```

> Esta skill no modifica parámetros. Produce evidencia y propuestas
> fundadas. Toda modificación de parámetros gobernables se ejecuta por
> Timelock de la DAO, con registro on-chain del fundamento.
