# ZydroSync — app iOS

App iOS mínima que lee de HealthKit las carreras grabadas con la app Entreno del Apple Watch
y las envía a ZydroTrack (`POST /v1/workouts`, ver [contract/openapi.yaml](../contract/openapi.yaml)).
Descarta las carreras de Garmin Connect y de cualquier otra app.

Estado: **fase (c) — envío y cola**. Sincroniza al abrir la app y al volver a primer plano; la sincronización con la app cerrada llega en la fase (d).

## Estructura

Rutas relativas a `ios/`. El contrato está en `../contract/openapi.yaml` y el servidor de pruebas en `../tools/mock_server.py`.

```
App/                      SwiftUI (capa fina). En la fase (a), solo una pantalla de diagnóstico.
Packages/ZydroCore/
  Sources/Domain/         Sin HealthKit: modelos Raw*, WorkoutSourceFilter, WorkoutMapper, WorkoutPayload, gzip
  Sources/HealthReading/  Único módulo que importa HealthKit
  Sources/SyncCore/       Cola persistente (+ ancla), RetryPolicy, UploadOutcome, SyncEngine. Sin HealthKit ni red
  Sources/Transport/      Cliente HTTP (POST gzip) y token en Keychain
  Tests/                  swift-testing; se ejecutan en macOS con `swift test`
Config/Signing.xcconfig   Bundle id y Team ID personales
project.yml               XcodeGen
```

## Requisitos

- Xcode 16 o posterior (Swift 6, SDK iOS 17+). La app requiere iOS 17.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen). Es una herramienta de desarrollo, no una dependencia de la app:

  ```bash
  brew install xcodegen
  ```

## Entitlements

`App/ZydroTrackSync.entitlements`:

| Clave | Valor | Fase |
|---|---|---|
| `com.apple.developer.healthkit` | `true` | a |
| `com.apple.developer.healthkit.background-delivery` | `true` | d |

**No** se incluye `com.apple.developer.healthkit.access` (ni siquiera vacía): activa la capability
"Verifiable Health Records", que no se puede firmar con un *Personal Team* y solo sirve para registros clínicos.

Con firma automática, Xcode activa la capability HealthKit en el App ID a partir de este fichero.

## Info.plist

- `NSHealthShareUsageDescription`: obligatoria. Sin ella, la app aborta al pedir permisos.
- `NSHealthUpdateUsageDescription`: **no** se incluye. La app no escribe en Salud.
- `UIRequiredDeviceCapabilities`: `healthkit`.
- No hace falta permiso de ubicación: las rutas se leen de Salud, no de CoreLocation.
- `NSAppTransportSecurity › NSAllowsLocalNetworking` y `NSLocalNetworkUsageDescription`: solo para el servidor de pruebas en la red local. Se pueden quitar cuando el servidor real esté en HTTPS.
- Fase (d): `UIBackgroundModes` (`fetch`, `processing`) y `BGTaskSchedulerPermittedIdentifiers`.

## Instalar en tu iPhone sin publicarla

1. Edita `Config/Signing.xcconfig`:
   - `ZT_BUNDLE_ID`: cualquier identificador único, p. ej. `com.tunombre.zydrotrack.sync`.
   - `DEVELOPMENT_TEAM`: tu Team ID, de 10 caracteres (Xcode › Settings › Accounts › tu equipo). No lo elijas a mano en Signing & Capabilities: lo que pongas ahí se pierde al regenerar con XcodeGen.
2. Genera el proyecto y ábrelo:

   ```bash
   xcodegen generate && open ZydroTrackSync.xcodeproj
   ```

3. En el iPhone, activa Ajustes › Privacidad y seguridad › **Modo desarrollador** (iOS 16+; pide reiniciar).
4. Conecta el iPhone por cable (o por la misma Wi‑Fi si ya lo emparejaste), selecciónalo como destino y pulsa ⌘R.
5. Con una cuenta **gratuita** (*Personal Team*), la primera vez tienes que confiar en el certificado: Ajustes › General › VPN y gestión de dispositivos. La firma caduca a los **7 días**; hay que reinstalar desde Xcode.
   Con el **Apple Developer Program** (de pago), la firma de desarrollo dura un año.

> Pendiente de verificar en la fase (d): si el entitlement `background-delivery` se puede firmar
> con un *Personal Team*. Si no se puede, la sincronización automática requiere la cuenta de pago.

## Tests

```bash
cd Packages/ZydroCore && swift test
```

No necesitan simulador: Domain no importa HealthKit.

## Fase (a): qué probar en el dispositivo

La app abre una pantalla de diagnóstico.

1. **Permisos.** Pulsa "Solicitar permisos de lectura", activa todo en la hoja de Salud y comprueba que "Solicitud" pasa a "Ya solicitada".
   Después, desactiva la lectura de Entrenamientos en Ajustes › Salud › Acceso a datos y comprueba que la lista sale **vacía, sin error**. Es lo esperado: iOS no informa de las denegaciones de lectura.
2. **Filtro de origen.** En la lista de las últimas 50 carreras:
   - Las del Watch muestran la etiqueta verde **Watch**, con `productType` `Watch…`.
   - Las de Garmin muestran **No Watch**, con `productType` `iPhone…`. **Esto es lo más importante de verificar.**
   - Si alguna vez usaste Strava u otra app en el reloj, debería salir **App terceros**.
   Si alguna se clasifica mal, abre el detalle y pásame "Bundle", "productType" y "Dispositivo".
3. **Lectura completa.** Abre una carrera del Watch al aire libre y comprueba:
   - Ruta: los puntos deberían ser aproximadamente la duración en segundos (1 Hz), y el primer fix estar en los primeros segundos.
   - Series: `heartRate`, `speed`, `steps`, `distance`, `activeEnergy`, `power`, `strideLength`, `verticalOscillation` y `groundContactTime` con datos.
     Las cuatro últimas requieren Watch SE 2 / Series 6 o posterior con watchOS 9+.
   - **Columna lookup**: debería ser `associated` en todas. Si alguna sale como `timeWindowSameSource`, apúntala: significa que el Watch no asocia ese tipo al workout y la lectura depende del método alternativo.
   - "Tiempo de lectura" en una carrera larga (>2 h): me interesa el número para dimensionar la ventana de background.
4. **Cinta.** Abre una carrera en cinta: debería decir "Interior: sí", sin ruta, y con series.
5. **Consulta anclada.** Pulsa "Buscar carreras nuevas": la primera vez devuelve todo el histórico de running. Pulsa otra vez y debería devolver 0.
   Sal a correr (o graba una carrera corta de prueba en el Watch), espera a que aparezca en Salud y vuelve a pulsar: debería devolver 1.
6. **Dispositivo bloqueado.** Pulsa "Buscar carreras nuevas", bloquea el iPhone enseguida, espera unos 15 s y desbloquéalo. No debería haber errores.
   La comprobación real de este caso se hará en la fase (d), con background.
7. **Justo al terminar una carrera.** Abre el detalle en cuanto la carrera aparezca en Salud y otra vez a los 5 minutos. Si la primera vez faltan ruta o muestras, confirma el riesgo de sincronización parcial (la mitigación con espera de asentamiento llega en la fase c).

## Fase (b): qué probar en el dispositivo

En el detalle de una carrera, la sección **Payload JSON** › "Generar JSON".

1. **Tamaño real.** Hazlo con la carrera de 25 km y apunta JSON, gzip y "Mapeo + JSON + gzip".
   El test sintético de 2 h da 358 KB y 55 KB en gzip, pero una ruta real comprime peor.
   Espero entre 400 y 700 KB de JSON y entre 100 y 200 KB en gzip.
2. **Contenido.** Usa "Compartir JSON" (AirDrop al Mac o Archivos) y revisa:
   - `startDate` en UTC con milisegundos, y `timeZone` con tu zona.
   - `route.t` empieza cerca de 0 y llega aproximadamente a `elapsedSec`. Todos los arrays de `route` tienen la misma longitud.
   - `series.cadence.v` con valores de carrera, sobre 160–190 ppm.
   - `series.speed.v` en m/s: 3,33 m/s equivale a 5:00 min/km.
   - `stepCount` y `distanceM` coherentes con lo que muestra la app Fitness.
3. **Validar contra el esquema** (opcional, en el Mac):

   ```bash
   npx @redocly/cli lint ../contract/openapi.yaml
   ```

   Ese JSON es el que tendrá que aceptar el servidor: sirve como fixture para tus tests en ZydroTrack.

## Fase (c): qué probar en el dispositivo

### Preparar el servidor de pruebas en el Mac

```bash
python3 ../tools/mock_server.py --token prueba123 --port 8080 --dir /tmp/zydro-inbox
```

El nombre de red del Mac (para la URL) se obtiene con:

```bash
scutil --get LocalHostName
```

En la app, sección **Servidor**: URL `http://<ese-nombre>.local:8080/v1/workouts`, token `prueba123`, **Guardar**.
La primera vez iOS pide permiso de **red local**: acéptalo. iPhone y Mac deben estar en la misma Wi‑Fi.

### Pruebas

1. **Primer envío.** Al guardar se sincroniza solo. Las carreras del Watch de las 48 h anteriores al primer arranque de esta versión deberían quedar **Enviada**, y el servidor imprime una línea por carrera (`201 new … ruta=… gzip=… KB`). Las más antiguas no se envían: son histórico (fase e).
2. **Idempotencia.** Borra la app del iPhone y vuelve a instalarla desde Xcode (habrá que conceder otra vez el permiso de Salud y quizá volver a escribir el token). La cola empieza de cero y reenvía las mismas carreras: el servidor debe imprimir `200 dup` para cada una, sin crear ficheros nuevos.
3. **Token incorrecto.** Arranca el servidor con otro token (`--token otro`) y graba o importa una carrera nueva (o usa `--mode 401`). Debe aparecer *"Envío pausado: el servidor rechazó el token"*. Guarda el token correcto: se reanuda solo.
4. **Errores transitorios.** `--mode 500`: la carrera queda **Pendiente** con "intento 1 · siguiente dentro de 15–30 s". Pulsa "Sincronizar ahora" pasado ese tiempo: intento 2, espera de 30–60 s… Cambia a `--mode ok` y la siguiente sincronización la envía.
5. **`--mode flaky`**: una petición sí y otra no. Deben acabar todas enviadas, sin duplicados en el servidor.
6. **`--mode 429`**: el siguiente intento debe programarse a ~60 s (el `Retry-After` del servidor), no según el backoff.
7. **`--mode 422`**: la carrera queda en **Error** con el mensaje del servidor. "Reintentar todas las que tienen error" con el modo `ok` la recupera.
8. **Sin red.** Modo avión y "Sincronizar ahora": Pendiente con el error de red. Quita el modo avión y vuelve a sincronizar.
9. **Persistencia.** Con algo pendiente, cierra la app desde el multitarea y ábrela: la cola sigue igual (está en `Application Support/ZydroTrackSync/queue.json`).
10. **Carrera nueva.** Sal a correr (o graba una carrera corta). Al abrir la app después: aparece **Pendiente — "Esperando a que el reloj termine de sincronizar"** durante 2 minutos, y luego se envía. Comprueba en `/tmp/zydro-inbox/<UUID>.json` que trae ruta y FC completas.
