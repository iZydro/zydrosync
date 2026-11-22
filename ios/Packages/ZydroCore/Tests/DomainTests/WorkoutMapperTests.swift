@testable import Domain
import Foundation
import Testing

@Suite("WorkoutMapper")
struct WorkoutMapperTests {
    @Test("Cabecera: fechas ISO con ms en UTC, duraciones y totales redondeados")
    func header() {
        let p = WorkoutMapper.payload(from: Fixtures.workout())
        #expect(p.schemaVersion == 1)
        #expect(p.workoutId == "8C1E0B3A-1111-4222-8333-944455556666")
        #expect(p.sport == "running")
        #expect(p.startDate == "2026-11-20T07:00:00.000Z")
        #expect(p.endDate == "2026-11-20T07:10:30.000Z")
        #expect(p.durationSec == 600)
        #expect(p.elapsedSec == 630)
        #expect(p.distanceM == 2012.35)
        #expect(p.activeEnergyKcal == 150.56)
        #expect(p.elevationAscendedM == 12.35)
        #expect(p.weather == .init(temperatureC: 11, humidityPct: 81.3))
        #expect(p.timeZone == "Europe/Madrid")
    }

    @Test("Ruta: columnar, offsets desde startDate y precisión fija")
    func route() throws {
        let p = WorkoutMapper.payload(from: Fixtures.workout())
        let r = try #require(p.route)
        #expect(r.t == [0.5, 1.5])
        #expect(r.lat == [39.4699075, 39.4699075])
        #expect(r.lon == [-0.3762882, -0.3762882])
        #expect(r.alt == [15.7, 15.7])
        #expect(r.hAcc == [3.2, 3.2])
        #expect(r.speed == [3.46, 3.46])
        #expect(r.course == [271.4, 271.4])
        #expect(r.segmentStarts == nil)
    }

    @Test("Varias rutas: se concatenan y segmentStarts marca dónde empieza cada una")
    func multipleSegments() throws {
        let raw = Fixtures.workout(routes: [
            [Fixtures.location(0), Fixtures.location(1)],
            [],
            [Fixtures.location(100), Fixtures.location(101), Fixtures.location(102)],
        ])
        let r = try #require(WorkoutMapper.payload(from: raw).route)
        #expect(r.count == 5)
        #expect(r.segmentStarts == [0, 2])
        #expect(r.t == [0, 1, 100, 101, 102])
    }

    @Test("Todos los arrays de la ruta tienen la misma longitud, aunque se descarten puntos")
    func routeArraysAligned() throws {
        var bad = Fixtures.location(2)
        bad.latitude = .nan
        var noAlt = Fixtures.location(3)
        noAlt.altitude = .infinity
        let raw = Fixtures.workout(routes: [[Fixtures.location(1), bad, noAlt]])
        let r = try #require(WorkoutMapper.payload(from: raw).route)
        let counts = [r.t, r.lat, r.lon, r.alt, r.hAcc, r.vAcc, r.speed, r.course].map(\.count)
        #expect(Set(counts) == [2])
        #expect(r.alt == [15.7, -1])
    }

    @Test("Cinta: sin ruta aunque HealthKit devolviera puntos; sin ruta si no hay puntos")
    func indoorAndEmptyRoute() {
        #expect(WorkoutMapper.payload(from: Fixtures.workout(indoor: true)).route == nil)
        #expect(WorkoutMapper.payload(from: Fixtures.workout(routes: [])).route == nil)
        #expect(WorkoutMapper.payload(from: Fixtures.workout(routes: [[]])).route == nil)
    }

    @Test("Series instantáneas: sin array d")
    func instantSeries() throws {
        let raw = Fixtures.workout(series: [.heartRate: [
            Fixtures.sample(0, 0, 120.0004), Fixtures.sample(5, 0, 131),
        ]])
        let hr = try #require(WorkoutMapper.payload(from: raw).series.heartRate)
        #expect(hr.t == [0, 5])
        #expect(hr.d == nil)
        #expect(hr.v == [120, 131])
    }

    @Test("Series cumulativas: con d; offsets negativos permitidos")
    func cumulativeSeries() throws {
        let raw = Fixtures.workout(series: [.distance: [
            Fixtures.sample(-1.5, 3, 4.2), Fixtures.sample(1.5, 3, 8.4),
        ]])
        let dist = try #require(WorkoutMapper.payload(from: raw).series.distance)
        #expect(dist.t == [-1.5, 1.5])
        #expect(dist.d == [3, 3])
        #expect(dist.v == [4.2, 8.4])
    }

    @Test("Cadencia: elimina la cuantización 7/8 pasos del Watch (caso real: Ultra 3)")
    func cadenceQuantization() throws {
        // Bloques de 2,556 s con 7 u 8 pasos, como en el JSON real. Bloque a bloque daría
        // 164,3 / 187,8 ppm alternando.
        let steps = (0 ..< 12).map { i in
            Fixtures.sample(Double(i) * 2.556, 2.556, i % 2 == 0 ? 7 : 8)
        }
        let p = WorkoutMapper.payload(from: Fixtures.workout(series: [.steps: steps]))
        let cad = try #require(p.series.cadence)
        // 4 bloques = 10,224 s, 30 pasos → 176,056 ppm; 12 bloques → 3 ventanas.
        #expect(cad.v == [176.056, 176.056, 176.056])
        #expect(cad.t == [0, 10.224, 20.448])
        #expect(p.stepCount == 90)
        #expect(p.series.steps?.v.count == 12)
    }

    @Test("Cadencia: un hueco > 1 s cierra la ventana; ventanas < 5 s se descartan")
    func cadenceGapsAndTail() throws {
        let raw = Fixtures.workout(series: [.steps: [
            Fixtures.sample(0, 6, 18),     // ventana corta por el hueco: 6 s → 180 ppm
            Fixtures.sample(20, 10, 29),   // tras pausa: 174 ppm
            Fixtures.sample(30, 3, 9),     // cola de 3 s: descartada
        ]])
        let cad = try #require(WorkoutMapper.payload(from: raw).series.cadence)
        #expect(cad.v == [180, 174])
        #expect(cad.t == [0, 20])
        #expect(cad.d == [6, 10])
    }

    @Test("Cadencia: muestras de duración 0 se ignoran (no dividen por cero)")
    func cadenceZeroDuration() {
        let raw = Fixtures.workout(series: [.steps: [Fixtures.sample(0, 0, 5)]])
        #expect(WorkoutMapper.payload(from: raw).series.cadence == nil)
    }

    @Test("Unión de muestras asociadas + ventana: sin duplicados y ordenada")
    func sampleUnion() {
        let a = [Fixtures.sample(5, 0, 150), Fixtures.sample(0, 0, 140)]
        let b = [Fixtures.sample(0, 0, 140), Fixtures.sample(10, 0, 155), Fixtures.sample(5, 0, 150)]
        let merged = SampleMerge.union(a, b)
        #expect(merged.map(\.value) == [140, 150, 155])
    }

    @Test("Sin datos: series ausentes, stepCount nil")
    func emptySeries() {
        let p = WorkoutMapper.payload(from: Fixtures.workout(series: [.power: []]))
        #expect(p.series == WorkoutPayload.Series())
        #expect(p.stepCount == nil)
    }

    @Test("Valores no finitos se descartan (JSONEncoder fallaría con NaN)")
    func nonFiniteSamples() throws {
        let raw = Fixtures.workout(series: [.power: [Fixtures.sample(0, 0, .nan), Fixtures.sample(1, 0, 250)]])
        let power = try #require(WorkoutMapper.payload(from: raw).series.power)
        #expect(power.v == [250])
        #expect(throws: Never.self) { try PayloadEncoding.json(WorkoutMapper.payload(from: raw)) }
    }

    @Test("Eventos: offset y duración")
    func events() {
        let raw = Fixtures.workout(events: [
            RawEvent(kind: .pause, interval: DateInterval(start: Fixtures.at(120.25), duration: 0)),
            RawEvent(kind: .segment, interval: DateInterval(start: Fixtures.at(0), duration: 300.5)),
        ])
        let events = WorkoutMapper.payload(from: raw).events
        #expect(events == [.init(type: .pause, t: 120.25, d: 0), .init(type: .segment, t: 0, d: 300.5)])
    }

    @Test("El redondeo produce decimales cortos en el JSON (sin colas binarias)")
    func roundingPrintsShort() throws {
        let raw = Fixtures.workout(routes: [[Fixtures.location(0.1, lat: 39.46990751, lon: -0.37628819)]])
        let json = try String(decoding: PayloadEncoding.json(WorkoutMapper.payload(from: raw)), as: UTF8.self)
        #expect(json.contains("\"lat\":[39.4699075]"))
        #expect(json.contains("\"lon\":[-0.3762882]"))
        #expect(json.contains("\"t\":[0.1]"))
    }
}
