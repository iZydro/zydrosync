import Domain
import Foundation
@testable import SyncCore
import Testing

@Suite("SyncEngine")
struct SyncEngineTests {
    struct Harness {
        let clock: TestClock
        let store = InMemoryQueueStore()
        let queue: SyncQueue
        let source = FakeSource()
        let uploader = FakeUploader()
        let engine: SyncEngine

        init(now: Date = F.t0) throws {
            clock = TestClock(now)
            queue = try SyncQueue(store: store, random: { 0 })
            let clock = self.clock
            engine = SyncEngine(queue: queue, source: source, uploader: uploader, clock: { clock.now })
        }
    }

    @Test("Camino feliz: descubre, espera el asentamiento y envía")
    func happyPath() async throws {
        let h = try Harness()
        let run = F.header(1, start: F.t0.addingTimeInterval(-2000), duration: 1800) // terminó hace 200 s
        await h.source.add(run)

        var report = await h.engine.sync()
        #expect(report.discovered == 1)
        #expect(report.postponed == 1)  // descubierta ahora: 120 s de asentamiento
        #expect(await h.uploader.uploaded.isEmpty)

        h.clock.advance(121)
        report = await h.engine.sync()
        #expect(report.sent == 1)
        #expect(await h.uploader.uploaded == [run.id])
        #expect(await h.queue.item(run.id)?.status == .sent)
        let body = try #require(await h.uploader.bodies.first)
        let json = try JSONDecoder().decode(WorkoutPayload.self, from: Gzip.decompress(body))
        #expect(json.workoutId == run.id.uuidString)
    }

    @Test("Carreras antiguas no necesitan asentamiento")
    func oldRunsSkipSettle() async throws {
        let h = try Harness()
        let run = F.header(1, start: F.t0.addingTimeInterval(-86400))
        await h.source.add(run)
        let report = await h.engine.sync()
        #expect(report.sent == 1)
    }

    @Test("Primera ejecución: lo anterior a instalación − 48 h es histórico y no se encola")
    func firstRunCutoff() async throws {
        let h = try Harness()
        let recent = F.header(1, start: F.t0.addingTimeInterval(-36 * 3600))
        let old = F.header(2, start: F.t0.addingTimeInterval(-72 * 3600))
        await h.source.add(old)
        await h.source.add(recent)
        let report = await h.engine.sync()
        #expect(report.discovered == 1)
        #expect(await h.queue.item(old.id) == nil)
        #expect(await h.queue.item(recent.id)?.status == .sent)
    }

    @Test("Sin URL/token: descubre y encola (y avanza el ancla) pero no envía")
    func notConfigured() async throws {
        let h = try Harness()
        await h.uploader.setConfigured(false)
        await h.source.add(F.header(1, start: F.t0.addingTimeInterval(-86400)))
        let report = await h.engine.sync()
        #expect(report.discovered == 1)
        #expect(report.stoppedBecause == .notConfigured)
        #expect(await h.uploader.uploaded.isEmpty)
        #expect(await h.queue.anchor != nil)
    }

    @Test("iPhone bloqueado: para sin tocar la cola; al desbloquear, envía")
    func locked() async throws {
        let h = try Harness()
        let run = F.header(1, start: F.t0.addingTimeInterval(-86400))
        await h.source.add(run)
        await h.uploader.setConfigured(false)
        await h.engine.sync()                      // encola
        await h.uploader.setConfigured(true)
        await h.source.setLocked(true)

        var report = await h.engine.sync()
        #expect(report.stoppedBecause == .locked)
        #expect(await h.queue.item(run.id)?.attempts == 0)

        await h.source.setLocked(false)
        report = await h.engine.sync()
        #expect(report.sent == 1)
    }

    @Test("Al aire libre sin ruta y recién terminada: se aplaza; pasada la hora, se envía sin ruta")
    func waitsForRoute() async throws {
        let h = try Harness()
        let run = F.header(1, start: F.t0.addingTimeInterval(-2000), duration: 1800)
        await h.source.add(run, routePoints: 0)
        h.clock.advance(121)  // ya asentada (descubierta en t0 tras el primer sync)
        await h.engine.sync()
        h.clock.advance(121)
        var report = await h.engine.sync()
        #expect(report.postponed == 1)
        #expect(await h.queue.item(run.id)?.lastError == "Esperando la ruta GPS del reloj")

        h.clock.advance(3600)
        report = await h.engine.sync()
        #expect(report.sent == 1)
    }

    @Test("Cinta sin ruta: se envía sin esperar")
    func indoorNoRoute() async throws {
        let h = try Harness()
        await h.source.add(F.header(1, start: F.t0.addingTimeInterval(-86400), indoor: true), routePoints: 0)
        let report = await h.engine.sync()
        #expect(report.sent == 1)
    }

    @Test("401 detiene la pasada: no se intenta el resto")
    func unauthorizedStops() async throws {
        let h = try Harness()
        await h.source.add(F.header(1, start: F.t0.addingTimeInterval(-86400)))
        await h.source.add(F.header(2, start: F.t0.addingTimeInterval(-90000)))
        await h.uploader.enqueueOutcomes([.unauthorized(status: 401)])
        let report = await h.engine.sync()
        #expect(report.stoppedBecause == .unauthorized)
        #expect(await h.uploader.uploaded.count == 1)
        #expect(await h.queue.isAuthPaused)
    }

    @Test("Error transitorio: se reintenta en la siguiente pasada tras el backoff, no en la misma")
    func transientRetry() async throws {
        let h = try Harness()
        let run = F.header(1, start: F.t0.addingTimeInterval(-86400))
        await h.source.add(run)
        await h.uploader.enqueueOutcomes([.retry(status: 503, after: nil, message: "503")])
        var report = await h.engine.sync()
        #expect(report.retrying == 1)
        #expect(await h.uploader.uploaded.count == 1)

        h.clock.advance(16)
        report = await h.engine.sync()
        #expect(report.sent == 1)
        #expect(await h.uploader.uploaded.count == 2)
    }

    @Test("Borrada de Salud antes de enviarse: error permanente con motivo claro")
    func deletedFromHealth() async throws {
        let h = try Harness()
        let run = F.header(1, start: F.t0.addingTimeInterval(-86400))
        await h.source.add(run)
        await h.uploader.setConfigured(false)
        await h.engine.sync()
        await h.uploader.setConfigured(true)
        await h.source.delete(run.id)
        let report = await h.engine.sync()
        #expect(report.failed == 1)
        #expect(await h.queue.item(run.id)?.lastError == "Ya no está en Salud")
    }

    @Test("Tras borrar enviados, la siguiente pasada las redescubre y las reenvía")
    func forgetSentResends() async throws {
        let h = try Harness()
        let run = F.header(1, start: F.t0.addingTimeInterval(-86400))
        await h.source.add(run)
        #expect(await h.engine.sync().sent == 1)
        #expect(await h.engine.sync().sent == 0)

        try await h.queue.forgetSentAndRediscover()
        let report = await h.engine.sync()

        #expect(report.discovered == 1)
        #expect(report.sent == 1)
        #expect(await h.uploader.uploaded == [run.id, run.id])
    }

    @Test("El ancla evita redescubrir: la segunda pasada no encola nada nuevo")
    func anchorPreventsRediscovery() async throws {
        let h = try Harness()
        await h.source.add(F.header(1, start: F.t0.addingTimeInterval(-86400)))
        #expect(await h.engine.sync().discovered == 1)
        #expect(await h.engine.sync().discovered == 0)
        await h.source.add(F.header(2, start: F.t0.addingTimeInterval(-3600)))
        #expect(await h.engine.sync().discovered == 1)
    }
}
