---
name: originator-attribution
description: "Determinar quién es el actor real detrás de la dirección que llega al hook, cuando el msg.sender es un router, un agregador, un contrato de protocolo o una Smart Account. Cubre lectura de hookData firmado, registro de reenviadores confiables, métodos subsidiarios de resolución y la política de bloqueo ante atribución fallida. Usar siempre como primera skill de dominio, antes incluso de ofac-screening: sin actor atribuido no hay sujeto sobre el cual verificar sanciones ni construir perfil."
---

# Originator Attribution — Identificación del Actor Real

## Rol en el agente

Esta skill responde a la pregunta que condiciona todas las demás: sobre quién se está haciendo el análisis.

En Uniswap v4 el `msg.sender` que recibe el hook rara vez es la wallet del usuario. La mayoría de los swaps llega a través del Universal Router, de un agregador, de un contrato de estrategia o de una Smart Account. Un sistema que puntúa esa dirección construye el perfil de riesgo de una pieza de infraestructura compartida por millones de operaciones, no el de un actor.

El resultado es doblemente inútil. El perfil del router converge al promedio del ecosistema y nunca alcanza un umbral relevante, de modo que el sistema no detecta nada. Y si por algún motivo lo alcanzara, bloquearía de forma indiscriminada a todos los usuarios de ese router.

Esta skill se ejecuta antes que cualquier otra skill de dominio. Su output determina si existe un sujeto evaluable y, en caso afirmativo, cuál es.

---

## Principio rector: una operación sin sujeto atribuible no se ejecuta

Una operación cuyo actor no puede identificarse es funcionalmente equivalente a la apertura de una caja de seguridad anónima. Ningún marco AML admite ese supuesto. La debida diligencia sobre un sujeto indeterminado es imposible por definición, y un sistema que registra "verificado" sobre una operación no atribuida produce un rastro de auditoría falso, que es peor que no producir ninguno.

**La política por defecto de AML Hook es fail-closed.** Si la atribución no se resuelve con confianza suficiente, el swap revierte.

El único mecanismo de excepción es el registro de reenviadores confiables descripto en el Paso 2. No hay otros. Un operador puede configurar una política permisiva, pero esa configuración se registra como decisión expresa del operador y se informa en el reporte agregado del pool como cobertura de monitoreo renunciada.

**Consecuencia operativa que el operador debe conocer.** Al día de hoy ningún router de uso general propaga el originador con firma verificable. En un pool abierto, la política fail-closed sin reenviadores registrados revierte la mayor parte del flujo. El modelo es viable en pools restringidos, donde el flujo llega por integradores conocidos que pueden registrarse. `protocol-obligations` debe advertir esto al configurar el pool.

---

## Inputs esperados

| Campo | Descripción |
|---|---|
| `msg_sender` | Dirección que el hook recibe como emisor |
| `hook_data` | Contenido del campo `hookData` del swap |
| `tx_hash` | Transacción que contiene el swap |
| `tx_origin` | Dirección que originó la transacción |
| `pool_id` | Pool involucrado |
| `registro_reenviadores` | Registro de routers e integradores habilitados del pool |
| `trace_disponible` | Si el nodo expone el trace de la transacción |

---

## Paso 1: Clasificación del msg.sender

| Clase | Criterio de detección | Tratamiento |
|---|---|---|
| **EOA directa** | `EXTCODESIZE == 0` y `msg_sender == tx_origin` | Atribución directa. El emisor es el actor |
| **Reenviador confiable** | Dirección presente en el registro del pool | Resolución por `hookData` firmado |
| **Router o agregador no registrado** | Contrato de infraestructura fuera del registro | Atribución fallida salvo `hookData` firmado válido |
| **Smart Account** | Contrato con interfaz de multisig o de cuenta abstracta | Atribución a la propia cuenta; verificación de controladores en `wallet-screening` |
| **Contrato de estrategia** | Contrato que opera fondos agrupados de terceros | Caso no resoluble; ver Paso 4 |
| **Contrato no identificado** | Contrato sin atribución conocida | Atribución fallida |

**Mantenimiento del registro.** Una dirección de router no reconocida se clasifica como no identificada, no como infraestructura benigna. El default seguro es asumir que no se sabe.

---

## Paso 2: Registro de reenviadores confiables

Es el único mecanismo que permite operar con flujo mediado sin renunciar a la atribución.

### 2.1 Requisitos de registro

Un router, agregador o integrador se incorpora al registro cuando cumple, de forma acumulativa:

| Requisito | Contenido |
|---|---|
| Propagación del originador | Incluye en `hookData` la dirección del usuario final |
| Firma verificable | El payload lleva firma ECDSA de una clave registrada, validable por `SignatureVerifier` |
| Protección contra reutilización | El payload incluye nonce y bloque o deadline, de modo que una firma no pueda reutilizarse en otra operación |
| Vinculación a la operación | La firma cubre, como mínimo: originador, `poolId`, `amountSpecified` y `zeroForOne` |
| Responsabilidad declarada | El integrador asume ante el operador del pool la exactitud del dato propagado |

### 2.2 Alta y baja

El alta y la baja de reenviadores son parámetros gobernables y se ejecutan por Timelock de la DAO. Toda modificación queda registrada on-chain con su fundamento.

La baja de un reenviador tiene efecto inmediato sobre el flujo entrante y efecto retroactivo sobre el perfil: los eventos atribuidos a través de una clave posteriormente revocada se marcan para revisión, porque la atribución que los sustentaba dejó de ser confiable.

### 2.3 Validación en cada swap

No basta con que el emisor esté en el registro. En cada operación se verifica:

1. Que el `hookData` contenga un payload con la estructura esperada
2. Que la firma sea válida contra una clave vigente del registro
3. Que el nonce no haya sido usado
4. Que el bloque o deadline no esté vencido
5. Que los parámetros firmados coincidan con los parámetros efectivos del swap

Si cualquiera de las cinco verificaciones falla, la atribución es fallida, con independencia de que el emisor figure en el registro. Un reenviador registrado que envía un payload inválido no produce una atribución degradada: produce una atribución fallida y un hecho de riesgo propio.

---

## Paso 3: Métodos subsidiarios

Se aplican únicamente cuando el operador configuró una política distinta de la restrictiva, o para resolución diferida de eventos ya bloqueados. Ordenados por valor probatorio.

### 3.1 hookData sin firma
Una declaración del propio emisor sobre su identidad. No es evidencia. `confidence: LOW`. Nunca sustenta por sí sola una atribución en política restrictiva.

### 3.2 tx.origin
Siempre disponible, sin cooperación de terceros. No es el actor real cuando existe abstracción de cuenta, relayers, meta-transacciones o patrocinio de gas: en ERC-4337 el `tx.origin` es el bundler, que es infraestructura tanto como el router. `confidence: MEDIUM` solo tras verificar la ausencia de esos patrones.

### 3.3 Trace de la transacción
Permite reconstruir la cadena de llamadas y ver el flujo completo, incluidos agregadores multisalto. Requiere nodo con trace habilitado y tiene costo computacional alto. `confidence: MEDIUM` a `HIGH` según la limpieza de la cadena reconstruida.

### 3.4 Flujo de fondos
Identificar qué dirección recibió el activo de salida. En ausencia de todo lo anterior, quien recibe el producto de la operación es el mejor candidato disponible. El destinatario puede ser otra wallet intermediaria del mismo actor o un tercero en operaciones compuestas. `confidence: LOW`.

---

## Paso 4: Casos no resolubles

Situaciones donde ningún método produce un actor individual, incluso con cooperación del integrador.

| Caso | Motivo |
|---|---|
| Contrato de estrategia con fondos agrupados | El swap se ejecuta por cuenta de N depositantes. No existe un actor individual atribuible a la operación |
| Agregador multisalto | El swap en este pool es un tramo de una ruta; el actor puede no tener relación directa con este par |
| Relayer o patrocinador de gas | Tanto `msg.sender` como `tx.origin` son infraestructura |
| Bundler ERC-4337 | El actor está dentro de la UserOperation, no en el nivel de la transacción |
| Liquidación o ejecución automatizada | El swap lo dispara un tercero por cuenta de una posición ajena |

En estos casos la atribución individual es imposible, no fallida. El operador decide si admite el flujo mediante un régimen específico, en el que el sujeto evaluado pasa a ser el contrato intermediario y su propio programa de control, o si lo rechaza. La decisión se documenta en `protocol-obligations` y se registra como criterio del pool.

---

## Paso 5: Políticas de atribución fallida

| Política | Comportamiento | Estado |
|---|---|---|
| **Restrictiva** | El swap revierte con código de razón de atribución fallida | **Default de AML Hook** |
| **Diferida** | El swap revierte y el evento se encola para resolución por trace; si se resuelve, el perfil se construye y el actor puede operar en adelante | Complemento recomendado de la restrictiva |
| **Elevada** | El swap procede con fee diferencial | Disponible. Requiere configuración expresa |
| **Permissive** | El swap procede con fee estándar y se registra como no atribuido | Disponible. Requiere configuración expresa y se informa como cobertura renunciada |

**Regla de registro.** Con cualquier política, una atribución fallida nunca se registra como verificación satisfactoria. La proporción de swaps no atribuidos es un indicador de desempeño del sistema y se informa en el reporte agregado del pool: un pool con cobertura de atribución baja tiene un sistema de monitoreo débil, con independencia de la calidad de su scoring.

---

## Paso 6: Verificación cruzada

Cuando hay más de un método disponible, contrastar los resultados.

| Situación | Interpretación |
|---|---|
| `hookData` firmado coincide con el destinatario de los fondos | Atribución sólida. `confidence: HIGH` |
| `hookData` firmado difiere del destinatario de los fondos | Puede ser legítimo, si el usuario envía a otra wallet propia. Registrar ambas como vinculadas |
| `hookData` sin firma difiere del destinatario de los fondos | Señal de riesgo propia. Emitir `ATRIBUCION_INCONSISTENTE` |
| `tx_origin` difiere del destinatario, sin patrón de relayer | Posible operación por cuenta de tercero. Registrar vinculación |

La divergencia entre la identidad declarada y el destino económico de la operación es información en sí misma. No se descarta: se registra.

---

## Output estructurado

```json
{
  "msg_sender": "0x...",
  "clase_sender": "EOA_DIRECTA | REENVIADOR_CONFIABLE | ROUTER_NO_REGISTRADO | SMART_ACCOUNT | CONTRATO_ESTRATEGIA | CONTRATO_NO_IDENTIFICADO",
  "atribucion": {
    "resuelta": true,
    "address_originador": "0x...",
    "metodo": "DIRECTA | HOOKDATA_FIRMADO | HOOKDATA_SIN_FIRMA | TX_ORIGIN | TRACE | FLUJO_DE_FONDOS",
    "confidence": "HIGH | MEDIUM | LOW",
    "verificacion_cruzada": "coincidente | divergente | no-aplicable"
  },
  "reenviador": {
    "registrado": false,
    "firma_valida": null,
    "nonce_valido": null,
    "deadline_valido": null,
    "parametros_coincidentes": null,
    "motivo_rechazo": null
  },
  "caso_no_resoluble": {
    "es": false,
    "motivo": null
  },
  "direcciones_vinculadas": [
    {"address": "0x...", "rol": "msg_sender | tx_origin | destinatario_fondos"}
  ],
  "politica_aplicada": "restrictiva | diferida | elevada | permissive",
  "salida_forzada": "REVERT | null",
  "codigo_razon": "ATTRIBUTION_FAILED | null",
  "encolado_para_resolucion": false,
  "address_a_evaluar": "0x...",
  "facts_emitidos": [],
  "siguiente_skill": "ofac-screening | cerrar-por-atribucion-fallida"
}
```

> Si `atribucion.resuelta: false` bajo política restrictiva, la skill emite
> `salida_forzada: REVERT` y el flujo termina. No se ejecuta screening de
> sanciones ni se construye perfil, porque no hay sujeto. El evento se
> registra como no atribuido y, si la política diferida está activa, se
> encola para resolución posterior.

> El sistema nunca inventa un sujeto para poder puntuarlo. Una atribución
> forzada produce un perfil falso, y un perfil falso contamina el registro
> compartido entre pools.
