import Domain
import Foundation
@testable import SyncCore
import Testing

@Suite("Reconciliación con el servidor e histórico")
struct ReconcileTests {
    struct Harness {
        let clock: TestClock
        let store = InMemoryQueueStore()
        let queue: SyncQueue
        let source = FakeSource()
        let uploader = FakeUploader()
        let catalog: FakeCatalog
        let engine: SyncEngine

        init(now: Date = F.t0) throws {
            clock = TestClock(now)
            queue = try SyncQueue(store: store, random: { 0 })
            catalog = FakeCatalog(uploader: uploader)
            let clock = self.clock
            engine = SyncEngine(queue: queue, source: source, uploader: uploader, catalog: catalog, clock: { clock.now })
        }
    }

    let t0 = F.t0

    // MARK: Cola

    @Test("Enviada que el servidor ya no tiene: falta en el servidor, y no vuelve a la cola sola")
    func missingIsNotResentAutomatically() async throws {
        let h = try Harness()
        let run = F.header(1, start: t0.addingTimeInterval(-86400))
        await h.source.add(run)
        #expect(await h.engine.sync().sent == 1)

        await h.catalog.deleteOnServer(run.id)
        let report = await h.engine.sync(reconcile: true)

        #expect(report.reconcile?.nowMissing == 1)
        #expect(report.sent == 0)
        #expect(await h.queue.item(run.id)?.status == .missingOnServer)
        #expect(await h.queue.nextDue(now: h.clock.now) == nil)
        #expect(await h.uploader.uploaded == [run.id])
    }

    @Test("Reenviar las que faltan: se suben y vuelven a estar en el servidor")
    func resendMissing() async throws {
        let h = try Harness()
        let run = F.header(1, start: t0.addingTimeInterval(-86400))
        await h.source.add(run)
        await h.engine.sync()
        await h.catalog.deleteOnServer(run.id)
        await h.engine.sync(reconcile: true)

        try await h.queue.resendAllMissing(now: h.clock.now)
        let report = await h.engine.sync()

        #expect(report.sent == 1)
        #expect(await h.uploader.uploaded == [run.id, run.id])
        let item = try #require(await h.queue.item(run.id))
        #expect(item.status == .sent)
        #expect(item.forceUpload == nil)
    }

    @Test("Reenvío pedido por el usuario: se sube aunque el servidor ya la tenga")
    func forcedResendIgnoresServer() async throws {
        let h = try Harness()
        let run = F.header(1, start: t0.addingTimeInterval(-86400))
        await h.source.add(run)
        await h.engine.sync()

        try await h.queue.resend([run.id], now: h.clock.now)
        let report = await h.engine.sync(reconcile: true)

        #expect(report.reconcile?.alreadyOnServer == 0)
        #expect(report.sent == 1)
        #expect(await h.uploader.uploaded == [run.id, run.id])
    }

    @Test("Pendiente que el servidor ya tiene (p. ej. tras reinstalar): se marca enviada sin subirla")
    func alreadyOnServerIsNotUploaded() async throws {
        let h = try Harness()
        let run = F.header(1, start: t0.addingTimeInterval(-86400))
        await h.source.add(run)
        await h.catalog.preload(run.id)

        let report = await h.engine.sync()

        #expect(report.reconcile?.alreadyOnServer == 1)
        #expect(report.sent == 0)
        #expect(await h.uploader.uploaded.isEmpty)
        let item = try #require(await h.queue.item(run.id))
        #expect(item.status == .sent)
        #expect(item.serverConfirmedAt == h.clock.now)
        #expect(item.sentAt == nil)
    }

    @Test("Si reaparece en el servidor, deja de faltar")
    func reappears() async throws {
        let queue = try SyncQueue(store: InMemoryQueueStore())
        let run = F.header(1, start: t0)
        try await queue.enqueue([run], priority: .live, advancingAnchorTo: nil, now: t0)
        try await queue.record(.success(status: 201), for: run.id, payloadBytes: 1, now: t0)
        try await queue.reconcile(serverIDs: [], now: t0)
        #expect(await queue.item(run.id)?.status == .missingOnServer)

        let result = try await queue.reconcile(serverIDs: [run.id], now: t0)

        #expect(result.reappeared == 1)
        #expect(await queue.item(run.id)?.status == .sent)
    }

    @Test("Se compara sola una vez al día; el botón fuerza la comparación")
    func dailyReconcile() async throws {
        let h = try Harness()
        await h.engine.sync()
        await h.engine.sync()
        #expect(await h.catalog.calls == 1)

        await h.engine.sync(reconcile: true)
        #expect(await h.catalog.calls == 2)

        h.clock.advance(24 * 3600)
        await h.engine.sync()
        #expect(await h.catalog.calls == 3)
    }

    @Test("Si la lista del servidor falla, no se toca nada y se sigue enviando")
    func catalogFailureIsHarmless() async throws {
        let h = try Harness()
        let sent = F.header(1, start: t0.addingTimeInterval(-2 * 86400))
        await h.source.add(sent)
        await h.engine.sync()
        await h.catalog.fail(.failure("sin red"))
        let fresh = F.header(2, start: t0.addingTimeInterval(-86400))
        await h.source.add(fresh)

        let report = await h.engine.sync(reconcile: true)

        #expect(report.reconcileError == "sin red")
        #expect(report.sent == 1)
        #expect(await h.queue.item(sent.id)?.status == .sent)
    }

    // MARK: Histórico

    @Test("Histórico: encola desde la fecha, no pisa lo ya encolado y no envía lo que el servidor tiene")
    func historyImport() async throws {
        let h = try Harness()
        let old1 = F.header(1, start: t0.addingTimeInterval(-300 * 86400))
        let old2 = F.header(2, start: t0.addingTimeInterval(-200 * 86400))
        let older = F.header(3, start: t0.addingTimeInterval(-400 * 86400))
        let recent = F.header(4, start: t0.addingTimeInterval(-86400))
        for run in [older, old1, old2, recent] { await h.source.add(run) }
        await h.engine.sync() // solo la reciente (las demás son anteriores al corte de instalación)
        #expect(await h.uploader.uploaded == [recent.id])
        await h.catalog.preload(old2.id)

        let result = try await h.engine.importHistory(since: t0.addingTimeInterval(-365 * 86400))
        let report = await h.engine.sync(reconcile: true)

        #expect(result.found == 3)          // old1, old2 y la reciente (ya encolada)
        #expect(result.added == 2)
        #expect(report.reconcile?.alreadyOnServer == 1)
        #expect(report.sent == 1)
        #expect(await h.uploader.uploaded == [recent.id, old1.id])
        #expect(await h.queue.item(older.id) == nil)
        #expect(await h.queue.item(recent.id)?.priority == .live)
        let progress = await h.queue.snapshot().historic
        #expect(progress.total == 2 && progress.done == 2 && progress.pending == 0)
    }

    @Test("Histórico: no toma carreras de la última hora (aún pueden estar llegando del reloj)")
    func historyExcludesLastHour() async throws {
        let h = try Harness()
        await h.source.add(F.header(1, start: t0.addingTimeInterval(-1800), duration: 600))
        let result = try await h.engine.importHistory(since: t0.addingTimeInterval(-86400))
        #expect(result.found == 0)
    }

    @Test("Cancelar el histórico quita lo pendiente y conserva lo enviado")
    func cancelHistory() async throws {
        let queue = try SyncQueue(store: InMemoryQueueStore())
        let a = F.header(1, start: t0), b = F.header(2, start: t0.addingTimeInterval(60))
        try await queue.enqueueHistoric([a, b], since: t0, now: t0)
        try await queue.record(.success(status: 201), for: a.id, payloadBytes: 1, now: t0)

        let removed = try await queue.cancelHistoricImport()

        #expect(removed == 1)
        #expect(await queue.item(a.id)?.status == .sent)
        #expect(await queue.item(b.id) == nil)
        #expect(await queue.snapshot().historyImportSince == t0)
    }

    @Test("Sincronizar ahora adelanta los reintentos programados sin tocar el contador")
    func expedite() async throws {
        let queue = try SyncQueue(store: InMemoryQueueStore(), random: { 0 })
        let run = F.header(1, start: t0)
        try await queue.enqueue([run], priority: .live, advancingAnchorTo: nil, now: t0)
        try await queue.record(.retry(status: 503, after: nil, message: "x"), for: run.id, payloadBytes: nil, now: t0)
        #expect(await queue.nextDue(now: t0) == nil)

        try await queue.expedite(now: t0)

        #expect(await queue.nextDue(now: t0)?.id == run.id)
        #expect(await queue.item(run.id)?.attempts == 1)
    }

    @Test("Una cola guardada por la versión anterior se sigue leyendo")
    func decodesPreviousManifest() throws {
        let json = """
        {"version":1,"authPaused":false,"installDate":"2026-11-20T10:00:00Z","anchor":"QTE=",
         "items":[{"id":"D061E7CC-5018-43B5-BE58-C09F8D89B005","priority":0,
                   "workoutStart":"2026-11-22T06:08:20Z","workoutEnd":"2026-11-22T07:04:37Z",
                   "distanceMeters":10087.6,"discoveredAt":"2026-11-22T07:10:00Z","status":"sent",
                   "attempts":0,"nextAttemptAt":"2026-11-22T07:10:00Z","sentAt":"2026-11-22T07:12:00Z",
                   "payloadBytes":76800,"lastHTTPStatus":201}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(QueueManifest.self, from: Data(json.utf8))
        #expect(manifest.items.first?.status == .sent)
        #expect(manifest.items.first?.forceUpload == nil)
        #expect(manifest.lastReconciledAt == nil)
    }
}
