# Inventario D&L — Acermel

Sistema de inventario del centro de distribución y logística de Acermel
(metalúrgica, Esperanza, Santa Fe). Reemplaza una planilla de Excel.

Leé este archivo entero antes de tocar nada.

---

## Para qué existe

Tres problemas del Excel que este sistema tiene que resolver. Si una decisión
de diseño no apunta a uno de estos, está de más:

1. **Campos obligatorios de verdad.** En Excel una validación no se aplica si
   nadie toca la celda.
2. **Saldo reconstruible a cualquier fecha.** En Excel el stock de ayer deja
   de existir en cuanto alguien edita una celda.
3. **Multiusuario.** Varias personas cargando a la vez sin pisarse.

## Quién lo usa

| Rol | Dónde | Qué puede hacer |
|---|---|---|
| Planta | Celular / tablet | Solo registrar movimientos |
| Administración | Navegador | Todo: catálogo, correcciones, recuentos |
| Gerencia | Navegador | Solo consultar |

Una sola aplicación con tres permisos, no tres aplicaciones.

---

## Reglas inviolables

Estas no se discuten en una sesión de trabajo. Si una tarea parece pedir que
se rompa alguna, pará y preguntá.

### 1. El libro de movimientos es append-only

Nunca se edita ni se borra un movimiento. Para corregir se agrega otro con
signo contrario que referencia al original. Quedan las dos líneas.

Esto se garantiza en la base: la tabla `movimientos` no tiene policy de
UPDATE ni de DELETE. No agregues una.

### 2. El stock es una vista, nunca una tabla

`stock` se calcula sumando `movimientos`. No existe ningún número de stock
guardado en ningún lado. Nunca propongas una tabla o columna de stock
"para que sea más rápido".

### 3. Las validaciones viven en la base

Constraints, foreign keys y RLS en Postgres. La validación en el HTML es
cortesía para el usuario, nunca la única barrera. Toda regla nueva se
escribe primero como constraint.

### 4. Dos fechas por movimiento

- `fecha` — cuándo pasó en planta. La elige quien carga.
- `registrado` — cuándo se cargó. La pone la base, no se toca.

Sin las dos no se puede reconstruir el saldo cuando alguien carga con atraso.
Toda consulta de saldo histórico filtra por `fecha`, no por `registrado`.

### 5. Un código identifica una pieza en un estante

No es el árbol del producto. El BOM va en su propia tabla.

---

## Modelo de datos

### productos

| Campo | Notas |
|---|---|
| `codigo` | clave primaria, texto |
| `descripcion` | obligatoria |
| `tipo` | COR, SE, ACC, MP |
| `origen` | fabricado, comprado, importado |
| `posicion` | un solo campo de texto: A2, D3, PA |
| `etapa` | texto libre, solo para SE. En qué parte del proceso está |
| `familia` | para códigos con X (ver abajo) |
| `activo` | booleano |

`tipo` dice **qué es** la pieza. `origen` dice **de dónde viene**. Son
preguntas distintas y por eso son dos columnas: una chapa importada es MP y
es importada a la vez.

El centro de distribución **no guarda producto terminado**. No agregues PT
al enum de `tipo`.

### movimientos

| Campo | Notas |
|---|---|
| `id` | |
| `producto` | FK a productos.codigo |
| `fecha` | del hecho |
| `cantidad` | entero con signo, distinto de cero |
| `motivo` | FK a motivos |
| `nota` | opcional |
| `usuario` | quién cargó |
| `registrado` | automático |
| `corrige` | FK opcional a otro movimiento |

### motivos

Tabla, no enum en el código, para poder agregar motivos sin tocar la app.
Cada motivo tiene un `signo` (+1 o −1).

Entradas: COMPRA, INGRESO_PRODUCCIÓN, INGRESO_TERCEROS,
AJUSTE_RECUENTO_POSITIVO
Salidas: CONSUMO_PRODUCCIÓN, TRASLADO_OTRO_DEPÓSITO, ROTURA_BAJA, CHATARRA,
SALIDA_TERCEROS, AJUSTE_RECUENTO_NEGATIVO

### ubicaciones, usuarios, bom

- `ubicaciones` — las posiciones de planta.
- `usuarios` — vía Supabase Auth, con rol.
- `bom` — árbol de productos. Existe en el diseño pero **no se implementa
  todavía**. Es la V2, después de que el inventario esté andando.

---

## Nomenclatura de códigos

### COR — cortes

Todo lo que sale del láser y todavía no pasó por ningún proceso. Incluye las
figuras (pinza multiuso, bandejas, cafeteras recién cortadas), no solo las
formas geométricas.

- Geométricos: prefijo de forma + chapa + medida + espesor.
  `D` disco, `C` cuadrado, `R` rectángulo, `O` óvalo.
  Ejemplo: `D430-15806` = disco, chapa 430, ø158, espesor 0.6.
- Figuras: `F` + código numérico del producto final, sin guión y sin letras.
  Ejemplo: `F93439`.

### SE — semielaborados

Ya pasaron por algún proceso después del láser. Prefijo de tres letras más
guión: `CUE-` cuerpo, `DES-` desarrollo, `TAP-` tapa, `ARO-` aro, `FON-`
fondo, `BAS-` base.
Ejemplo: `DES-61134`.

### La X es comodín de familia

Una `X` en un código marca la posición que varía dentro de una familia.
`CUE-613X1` es **una fila real** del catálogo y **un solo estante**, y en
`familia` se listan los códigos que cubre.

**Nunca** es un dato pendiente de completar.

Un código con X no puede convivir con sus códigos expandidos cargados por
separado. Eso es una validación que hay que implementar.

### Regla de unicidad pendiente de implementar

Para los geométricos, el correlativo identifica la medida. Dos productos de
la misma chapa y la misma medida deben compartir correlativo y diferir solo
en el espesor.

Errores ya detectados en los datos actuales:

- `R304-00206` (19x17, esp 0.6) y `R304-01307` (19x17, esp 0.7)
- `R430-00206` (25,5x13, esp 0.6) y `R430-00107` (25,5x13, esp 0.7)

Esto solo se puede validar si medida y espesor son **campos de la tabla**,
no texto dentro de la descripción. Tenerlo en cuenta al diseñar el generador
de códigos.

### Códigos legacy

Hay códigos numéricos puros heredados del sistema viejo, como `3000406`. Hay
que decidir si se renombran o se marcan como legacy. Pendiente.

---

## Regla de datos

**Si en la nota hay una cantidad, son dos productos.**

"30 golpeadas, las demás sin" no es una observación: son dos stocks distintos
dentro de un campo de texto. El total queda bien pero nadie sabe cuántas de
cada una hay. Cuando aparezca un caso así, hay que partirlo en dos códigos.

---

## Stack

- **Base:** Supabase (Postgres). Proyecto `inventario-acermel`.
- **Front:** HTML y JavaScript en un archivo, sin framework ni build.
- **Hosting:** Vercel, conectado a este repo. Merge a `main` publica solo.

Mantener el front sin build mientras se pueda. Si en algún momento hace falta
un framework, planteálo y explicá qué se gana; no lo introduzcas de costado.

---

## Convenciones

- Todo en español: nombres de tablas, columnas, variables y textos de pantalla.
- Cantidades: entero con signo. Positivo entra, negativo sale.
- Las pantallas de planta se diseñan para una mano, con guantes y poca luz.
  Pocos botones, grandes, alto contraste.
- Los errores de la base se muestran al usuario tal como vienen. Que se vea
  qué regla se violó.

## Cómo trabajar

- Cambios en una rama, con link de preview de Vercel. No mergear a `main`
  sin probar, salvo que se indique.
- Cambios de esquema: SQL completo para pegar en el SQL Editor de Supabase,
  nunca instrucciones de clickear en la interfaz.

---

## Estado actual

Funcionando: base con tablas `productos` y `movimientos` de prueba, vista
`stock`, y una página que lee y escribe desde el celular. Es un casco para
validar la arquitectura, no el modelo final.

Próximo: reemplazar el esquema de prueba por el modelo completo, después
login y roles, después la pantalla de planta con escaneo.

El Excel original se está limpiando en paralelo. La migración con fecha de
corte viene después.
