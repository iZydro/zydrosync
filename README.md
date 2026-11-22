# ZydroSync

Copia de seguridad de entrenamientos del Apple Watch (y, más adelante, de otros datos de
Salud) en un servidor propio, multiusuario. Otros sistemas, como ZydroTrack, importan desde
ZydroSync con su API de lectura, igual que hoy importan de Strava.

```
contract/openapi.yaml   Contrato HTTP: fuente única de verdad para la app, el servidor y los importadores
ios/                    App iOS (SwiftUI, HealthKit) → ver ios/README.md
server/                 Servidor (ASP.NET Core + SQLite, un fichero por usuario) → ver server/README.md
tools/                  Herramientas en Python: servidor de pruebas y tests de contrato
```

## Flujo

```
Apple Watch → Salud (iPhone) → app ZydroSync ──POST /v1/workouts──► servidor ZydroSync ──► SQLite por usuario
                                                                         │
                                       importador de ZydroTrack ◄── GET /v1/workouts?after=<cursor>
```

## Estado

| Parte | Estado |
|---|---|
| iOS (a) permisos y lectura, (b) mapeo y JSON, (c) envío y cola | Hecho |
| iOS (d) background, (e) histórico y UI | Pendiente |
| Servidor S1: API y almacenamiento en local | Hecho |
| Servidor S2: despliegue en Lightsail · S3: API de lectura e importador · S4: multiusuario completo | Pendiente |

## Datos de salud y RGPD

Los entrenamientos con frecuencia cardíaca y ubicación son datos de salud: una categoría
especial del RGPD (art. 9). El servidor se aloja en la UE, cifra en tránsito y en reposo, y
debe permitir a cada usuario exportar y borrar todos sus datos.
