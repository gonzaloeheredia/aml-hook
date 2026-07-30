# AML Hook — Compliance Officer Agent

Paquete Python con el loop agentico Claude y el sistema de skills modulares, orientado al scoring conductual de wallets para AML Hook, hook de compliance de Uniswap v4.

Derivado del Compliance Officer Agent para entidades financieras. Esta versión elimina el marco argentino, las skills ajenas a AML/CFT y el flujo basado en identidad verificada del cliente, y lo reemplaza por análisis conductual de direcciones on-chain bajo los marcos de Estados Unidos, la Unión Europea y las Recomendaciones del GAFI.

```
agent/
├── aml_hook_agent/
│   ├── config.py              # Env, modelo, cliente Anthropic
│   ├── runtime_config.py      # Overrides desde configuración del operador
│   ├── token_usage.py         # Contador de tokens / presupuesto
│   ├── prompts/               # system.md — prompt madre con disciplina forense
│   ├── tools_def.py           # Schemas de tools para Claude
│   ├── tool_executor.py       # Despacho de tools
│   ├── fact_scoring.py        # Score 0–100 GAFI/OFAC/BSA
│   ├── attribution.py         # Resolución del originador y registro de reenviadores
│   ├── integrations/          # OpenSanctions, Etherscan, analytics, Forta, GoPlus
│   ├── oracle_writer.py       # Firma y escritura del score en ComplianceOracle
│   ├── shared_registry.py     # Publicación y consulta de señales entre pools
│   ├── agent.py               # Loop: score_wallet + run_dictamen + run_consulta
│   ├── skills_registry.py     # Carga skills markdown
│   └── memory.py              # Perfiles de wallet y expedientes
├── skills/                    # Dominio + tareas + fact-scoring
├── data/                      # normativa_seed.json + overrides locales
└── docs/
```

---

## Responsabilidades del agente

### 1. Scoring de wallets

El agente ejecuta el flujo completo sobre una dirección: resuelve la atribución del originador, verifica sanciones, recopila evidencia on-chain, aplica las skills de dominio, corre `fact-scoring` y produce el score 0–100 con su salida ternaria.

El score se firma criptográficamente y se escribe en `ComplianceOracle`. `AMLHook.beforeSwap` lo lee y aplica la salida sin latencia adicional.

Punto de entrada: `score_wallet()`.

### 2. Elaboración del expediente de evidencia

Dictamen técnico con scoring justificado, hallazgos por dimensión con cita de norma, tipologías identificadas y recomendaciones. Cuando corresponde, anexo de sustento para un eventual SAR ante FinCEN.

El destinatario de todo output documental es el Oficial de Cumplimiento del operador del pool. El agente no presenta reportes ante ninguna autoridad.

Punto de entrada: `run_dictamen()`. Skill responsable: `task-regulatory-report`.

### 3. Respuesta en el módulo de consulta normativa

El agente responde consultando el corpus cargado en sesión mediante `search_normativa`, y declara si la materia no está cubierta. Nunca responde desde memoria de entrenamiento en este módulo.

Punto de entrada: `run_consulta()`.

---

## Restricción arquitectónica fundamental

El agente opera off-chain y de forma asincrónica. El hook nunca lo invoca en tiempo de ejecución: lee un score precalculado.

```
[Motor off-chain]                        [On-chain]

evento detectado
      │
      ▼
  originator-attribution
      │
      ├── no resuelta ──────────────▶ REVERT (ATTRIBUTION_FAILED)
      │
      ▼
  agente ejecuta el flujo
      │
      ▼
  ScoreResult firmado ──────────▶  ComplianceOracle.setScore()
                                          │
                                          ▼
                                  AMLHook.beforeSwap()
                                    lee score → salida ternaria
                                          │
                                          ▼
                                  AMLHook.afterSwap()
                                    emite SwapObserved
      │                                   │
      └───────────◀───────────────────────┘
        recálculo incremental
```

---

## Prompt madre

`prompts/system.md` contiene el system prompt del loop agentico. Gobierna la disciplina forense: citación obligatoria con `tx_hash` y bloque, lectura correcta de exploradores, distinción entre no encontrado, no consultado y sin respuesta, manejo de paginación y ventana efectiva, prohibición de inferencia sobre valores, tratamiento del output de analytics como juicio de terceros, y distinción entre recepción y uso de fondos.

Incluye una lista de autoverificación de doce puntos que el agente recorre antes de emitir cualquier output.

---

## Stack

- **Claude** (`anthropic`) — temperature 0, stop sequences, max_tokens 4096
- **Tools:** `search_normativa`, `get_wallet_data`, `get_wallet_analytics`, `screen_sanctions`, `check_contract_security`, `get_forta_alerts`, `query_wallet_history`, `evaluate_risk_factors`, `resolve_originator`, `query_shared_registry`, `write_oracle_score`
- **Persistencia:** in-memory (`memory.py`) — PostgreSQL pendiente según `docs/schema.sql`
- **Skills:** markdown cargadas dinámicamente por `skills_registry.py`

---

## Setup

```bash
cd agent
python -m venv .venv
source .venv/bin/activate      # Linux/Mac; en Windows .venv\Scripts\activate
pip install -r requirements.txt
pip install -e .
```

```bash
ANTHROPIC_API_KEY=sk-ant-...
MOCK_MODE=false
MODEL_NAME=claude-sonnet-4-6
ETHERSCAN_API_KEY=
OPENSANCTIONS_API_KEY=
CHAINALYSIS_API_KEY=
FORTA_API_KEY=
GOPLUS_API_KEY=
GOPLUS_API_SECRET=
ORACLE_SIGNER_KEY=
ORACLE_CONTRACT_ADDRESS=
SHARED_REGISTRY_ADDRESS=
RPC_URL=
RPC_TRACE_URL=
```

---

## Sistema de skills

```
DIMENSIÓN 1: DOMINIO                    DIMENSIÓN 2: TIPO DE TAREA

├── originator-attribution               ├── task-swap-intake
├── ofac-screening                       ├── task-onchain-evidence
├── wallet-screening                     ├── task-swap-decision
├── swap-behavior-analysis               ├── task-blocking-protocol
├── typology-detection                   └── task-regulatory-report
├── cross-pool-intelligence
└── protocol-obligations

── SCORING ──                            ── CONTROL DEL SISTEMA ──
└── fact-scoring                         ├── model-validation
                                         └── dispute-remediation
```

### Flujo de trabajo estándar

```
[INPUT: swap / afterSwap / denuncia LP / revisión / impugnación]
          │
          ▼
  task-swap-intake
          │
          ▼
  originator-attribution           ◀── PRECEDENCIA ABSOLUTA
  ──────────────────────
  Sin sujeto atribuido no hay
  análisis. Política fail-closed:
  el swap revierte.
          │
          ▼
  ofac-screening                   ◀── PRECEDENCIA SOBRE DOMINIO
  ──────────────
  Match directo → task-blocking-protocol
          │
          ▼
  task-onchain-evidence
          │
          ▼
  wallet-screening
          │
          ▼
  swap-behavior-analysis
          │
          ▼
  typology-detection
          │
          ▼
  cross-pool-intelligence (consulta)
          │
          ▼
  fact-scoring
          │
          ▼
  task-swap-decision
          │
      ┌───┼────────────────┬─────────────────────┐
      ▼   ▼                ▼                     ▼
task-blocking-  task-regulatory-  cross-pool-      dispute-
protocol        report            intelligence     remediation
                                  (publicación)
                                       │
                                       ▼
                                 model-validation
                                 (periódica)
```

### Reglas de precedencia

1. `originator-attribution` se ejecuta antes que todo. Sin sujeto no hay análisis.
2. `ofac-screening` se ejecuta antes que toda otra skill de dominio.
3. `swap-behavior-analysis` es obligatoria antes de emitir cualquier score en tramo de bloqueo.
4. `protocol-obligations` se ejecuta al configurar un pool y antes de todo anexo de sustento para SAR.

### Flujo incremental post-swap

```
afterSwap emite SwapObserved
          │
          ▼
  task-swap-intake (modo POST_SWAP)
          │
          ├─ score vigente, sin hechos nuevos S/MX/GEO ─▶ swap-behavior-analysis
          │                                               + fact-scoring incremental → oracle
          ├─ score vencido o invalidado ────────────────▶ flujo completo
          └─ receptor con hit de sanciones ─────────────▶ task-blocking-protocol
```

### Tabla de combinaciones frecuentes

| Caso | Skills de dominio | Flujo |
|---|---|---|
| Swap por router no registrado | `originator-attribution` | intake → atribución → **REVERT** |
| Swap por reenviador confiable | Flujo completo | intake → atribución → ofac → evidence → dominio → scoring → decisión |
| Wallet nueva sin score | `ofac-screening` + `wallet-screening` | flujo completo |
| Actualización post-swap | `swap-behavior-analysis` | incremental |
| Hit en OFAC SDN | `ofac-screening` | intake → atribución → **blocking-protocol** → report |
| Structuring o smurfing | `swap-behavior-analysis` + `typology-detection` | flujo completo → report |
| Manipulación por flash loan | `typology-detection` | flujo completo → report |
| Swap de claims internos ERC-6909 | `typology-detection` | flujo completo → report |
| Address poisoning sobre un tercero | `typology-detection` | flujo completo, con regla de recepción frente a uso |
| Señal recibida de otro pool | `cross-pool-intelligence` | consulta → scoring con techo aplicado |
| Denuncia de LP en challenge | `dispute-remediation` | challenge → resolución → scoring |
| Wallet que impugna su bloqueo | `dispute-remediation` | admisibilidad → resolución → recálculo |
| Validación periódica | `model-validation` | backtesting → sensibilidad → deriva |
| Configuración de pool nuevo | `protocol-obligations` | intake → dominio → report |

---

## Reglas de autonomía del agente

| Límite | Condición |
|---|---|
| **Reversión inmediata** | Atribución del originador no resuelta bajo política restrictiva |
| **Bloqueo inmediato** | Match confirmado en OFAC SDN, ONU o UE |
| **Bloqueo inmediato** | Interacción con contrato designado |
| **Bloqueo inmediato** | Nexo con financiamiento del terrorismo o proliferación |
| **Bloqueo preventivo + revisión humana** | Controlador designado en una Smart Account |
| **Revisión humana requerida** | Match por atribución de cluster |
| **Revisión humana requerida** | Score ≥ 71 sin ningún hecho de confidence HIGH |
| **Revisión humana requerida** | Bloqueo sustentado solo en señales externas no verificadas |
| **Revisión humana requerida** | Resolución de disputa que implique desbloquear una wallet |
| **Suspensión de la evaluación** | Indisponibilidad de fuentes de Nivel 1 |
| **Asesoramiento legal requerido** | Calificación del operador como sujeto obligado bajo la BSA |

El agente nunca:

- Presenta un reporte ante ninguna autoridad
- Responde directamente un requerimiento de autoridad
- Informa al sujeto evaluado sobre la existencia de un análisis o un reporte
- Libera fondos de custodia sin instrucción documentada del Oficial de Cumplimiento
- Desbloquea una wallet con override de sanciones activo
- Modifica parámetros gobernables fuera del Timelock de la DAO
- Publica los valores efectivos de los umbrales
- Republica como propia una señal recibida de otro pool
- Construye un perfil sobre un router, un agregador o un contrato de infraestructura
- Concluye que una entidad es sujeto obligado ni que una conducta constituye un delito

---

## Marco normativo

| Marco | Alcance |
|---|---|
| GAFI — 40 Recomendaciones (2023) | Estándar base de todo el scoring |
| GAFI — Indicadores de Alerta en Activos Virtuales (2020) | Catálogo de tipologías; seis categorías |
| GAFI — Guía sobre activos virtuales y VASPs (2021) | Calificación de actores en entornos descentralizados |
| OFAC — IEEPA, 31 CFR Part 501 | Bloqueo, segregación y reporte de bienes bloqueados |
| OFAC — Guía para la industria de moneda virtual (2021) | Screening de direcciones y monitoreo de exposición |
| BSA — 31 U.S.C. § 5311 y ss., 31 CFR § 1010.320 | Programa AML, monitoreo y régimen del SAR |
| BSA — 31 CFR § 1010.410(e) y (f) | Travel Rule estadounidense; umbral USD 3.000 |
| MiCA — Reglamento (UE) 2023/1114 | Régimen de los CASP |
| TFR — Reglamento (UE) 2023/1113 | Travel Rule europea; umbral cero |
| AMLR — Reglamento (UE) 2024/1624 | Régimen unificado de debida diligencia |

**Travel Rule.** Aplica a transferencias entre VASPs, no al swap. Un swap no reúne los elementos del supuesto de hecho: no hay dos instituciones, no hay ordenante y beneficiario diferenciados, el usuario conserva la custodia en ambos extremos y no existe VASP receptor. Dentro del sistema cumple tres funciones: mitigante sobre el tramo previo de los fondos, obligación propia del operador si presta servicios custodiados, y delimitación del perímetro donde el compliance ya existe. Ver `protocol-obligations` Paso 3 bis.

---

## Configuración en `config.py`

```python
SKILLS_ENABLED = True

DOMAIN_SKILLS = [
    "originator-attribution",
    "ofac-screening",
    "wallet-screening",
    "swap-behavior-analysis",
    "typology-detection",
    "cross-pool-intelligence",
    "protocol-obligations",
]

SYSTEM_SKILLS = [
    "model-validation",
    "dispute-remediation",
]

DEFAULT_TASK_FLOW = [
    "task-swap-intake",
    "originator-attribution",
    "ofac-screening",
    "task-onchain-evidence",
    "wallet-screening",
    "swap-behavior-analysis",
    "typology-detection",
    "cross-pool-intelligence",
    "fact-scoring",
    "task-swap-decision",
]

INCREMENTAL_FLOW = [
    "task-swap-intake",
    "swap-behavior-analysis",
    "fact-scoring",
    "task-swap-decision",
]

SKILL_PRECEDENCE = ["originator-attribution", "ofac-screening"]

SCORE_TO_HOOK_OUTPUT = {
    (0, 30):   "ALLOW",
    (31, 70):  "FEE_DIFERENCIAL",
    (71, 100): "REVERT",
}

ATTRIBUTION_POLICY = "restrictiva"       # restrictiva | diferida | elevada | permissive
DEFERRED_RESOLUTION_ENABLED = True
TRUSTED_FORWARDERS = []                  # gobernado por Timelock de la DAO

GOVERNABLE_PARAMS = {
    "umbral_reporte_usd": 10_000,
    "ventana_structuring_dias": 30,
    "min_splits_structuring": 3,
    "velocity_spike_multiplier": 5,
    "mixer_lookback_dias": 90,
    "decay_factor": 0.4,
    "sospecha_score_threshold": 65,
    "wallet_nueva_umbral_usd": 5_000,
    "fee_multiplier_tramo_medio": 3,
    "denuncia_lp_threshold": 3,
    "profundidad_hops": 3,
    "escrow_timelock_horas": 48,
    "politica_atribucion": "restrictiva",
    "peso_senal_externa_no_verificada": 0.5,
    "umbral_reputacion_degradacion_pool": 0.2,
    "challenge_denuncia_horas": 72,
    "revision_periodica_bloqueos_dias": 90,
}

INMUTABLES = [
    "override_sanciones",
    "mapeo_score_salida",
    "firma_oracle_obligatoria",
    "umbral_dos_dimensiones_sospecha",
    "hecho_high_para_bloqueo",
    "tope_mitigantes",
    "techo_senales_externas",
    "prohibicion_republicacion",
    "exclusion_score_registro_compartido",
    "verificacion_sanciones_contra_lista",
]

RETENCION_REGISTROS_ANIOS = 5
```

---

## Cambios respecto de la versión para entidades financieras

| Skill original | Estado | Reemplazo |
|---|---|---|
| `aml-cft-screening` | Reescrita | `typology-detection` |
| `crypto-asset-screening` | Reescrita | `wallet-screening` |
| `defi-onchain-risk` | Reescrita | `swap-behavior-analysis` |
| `sanctions-screening` | Reescrita | `ofac-screening` |
| `vasp-regulatory-compliance` | Reescrita | `protocol-obligations` |
| `kyc-due-diligence` | Eliminada | No hay onboarding ni identidad verificada |
| `data-privacy-compliance` | Eliminada | Fuera del alcance AML |
| `regulatory-compliance-sectoral` | Eliminada | Licenciamiento sectorial ajeno al hook |
| `task-intake-triage` | Reescrita | `task-swap-intake` |
| `task-investigation` | Reescrita | `task-onchain-evidence` |
| `task-risk-assessment` | Reescrita | `task-swap-decision` |
| `task-escalation` | Reescrita | `task-blocking-protocol` |
| `task-report-drafting` | Reescrita | `task-regulatory-report` |
| `fact-scoring` | Adaptada y ampliada | Catálogo reorientado a wallets, dimensión DeFi incorporada |
| — | Nueva | `originator-attribution` |
| — | Nueva | `model-validation` |
| — | Nueva | `dispute-remediation` |
| — | Nueva | `cross-pool-intelligence` |
| — | Nuevo | `prompts/system.md` |

Eliminado: toda referencia a UIF, CNV, BCRA, AFIP, SIRO, ROS/RFT, Ley 25.246, Resoluciones UIF, PEP, UBO, expediente KYC documental, fuentes OSINT de identidad y organismos supervisores argentinos.

---

*AML Hook — Compliance Officer Agent v3.0*
*Gonzalo Emanuel Heredia — Uniswap Hook Incubator, Cohort 10*
