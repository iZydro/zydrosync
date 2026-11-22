import Domain
import Foundation
@testable import SyncCore
import Testing

@Suite("RetryPolicy")
struct RetryPolicyTests {
    let policy = RetryPolicy(base: 30, cap: 6 * 3600)

    @Test("Crece ×2 por intento y respeta [d/2, d]")
    func growth() {
        #expect(policy.delay(afterAttempt: 1, random: 0) == 15)
        #expect(policy.delay(afterAttempt: 1, random: 1) == 30)
        #expect(policy.delay(afterAttempt: 2, random: 0) == 30)
        #expect(policy.delay(afterAttempt: 3, random: 0.5) == 90)
    }

    @Test("Tope de 6 h, sin desbordar con muchos intentos")
    func cap() {
        #expect(policy.delay(afterAttempt: 20, random: 1) == 6 * 3600)
        #expect(policy.delay(afterAttempt: 10_000, random: 0) == 3 * 3600)
    }
}

@Suite("UploadOutcome.classify")
struct UploadOutcomeTests {
    let now = F.t0

    @Test("Clasificación por código", arguments: [
        (200, "success"), (201, "success"), (204, "success"),
        (401, "unauthorized"), (403, "unauthorized"),
        (400, "permanent"), (404, "permanent"), (409, "permanent"), (413, "permanent"), (422, "permanent"),
        (408, "retry"), (429, "retry"), (500, "retry"), (502, "retry"), (503, "retry"),
    ])
    func byStatus(status: Int, expected: String) {
        let kind = switch UploadOutcome.classify(status: status, retryAfter: nil, body: nil, now: now) {
        case .success: "success"
        case .unauthorized: "unauthorized"
        case .permanent: "permanent"
        case .retry: "retry"
        }
        #expect(kind == expected)
    }

    @Test("Retry-After en segundos y como fecha HTTP")
    func retryAfter() {
        #expect(UploadOutcome.parseRetryAfter("120", now: now) == 120)
        let httpDate = "Tue, 10 Nov 2026 00:00:00 GMT"
        let target = ISO8601DateFormatter().date(from: "2026-11-10T00:00:00Z")!
        #expect(UploadOutcome.parseRetryAfter(httpDate, now: target.addingTimeInterval(-60)) == 60)
        #expect(UploadOutcome.parseRetryAfter("basura", now: now) == nil)
        #expect(UploadOutcome.parseRetryAfter(nil, now: now) == nil)
    }

    @Test("Mensaje de problem+json")
    func problemDetail() {
        let body = Data(#"{"title":"Unprocessable","detail":"distanceM debe ser ≥ 0"}"#.utf8)
        #expect(UploadOutcome.classify(status: 422, retryAfter: nil, body: body, now: now)
            == .permanent(status: 422, message: "422 distanceM debe ser ≥ 0"))
    }

    @Test("Errores de red: transitorios salvo URL inválida")
    func networkErrors() {
        if case .retry = UploadOutcome.classify(error: URLError(.notConnectedToInternet)) {} else { Issue.record("debería reintentar") }
        if case .retry = UploadOutcome.classify(error: URLError(.timedOut)) {} else { Issue.record("debería reintentar") }
        if case .permanent = UploadOutcome.classify(error: URLError(.unsupportedURL)) {} else { Issue.record("debería ser permanente") }
    }
}

@Suite("SyncQueue")
struct SyncQueueTests {
    let t0 = F.t0

    func makeQueue(_ store: InMemoryQueueStore = InMemoryQueueStore(), random: Double = 0) throws -> SyncQueue {
        try SyncQueue(store: store, policy: RetryPolicy(base: 30, cap: 6 * 3600), random: { random })
    }

    @Test("Encolar y avanzar el ancla es UNA escritura")
    func atomicEnqueueAndAnchor() async throws {
        let store = InMemoryQueueStore()
        let queue = try makeQueue(store)
        let added = try await queue.enqueue([F.header(1, start: t0), F.header(2, start: t0)], priority: .live,
                                            advancingAnchorTo: Data("A1".utf8), now: t0)
        #expect(added == 2)
        #expect(store.saveCount == 1)
        #expect(store.current?.anchor == Data("A1".utf8))
        #expect(store.current?.items.count == 2)
    }

    @Test("Encolar dos veces no duplica ni resetea una ya enviada")
    func dedupe() async throws {
        let queue = try makeQueue()
        let h = F.header(1, start: t0)
        try await queue.enqueue([h], priority: .live, advancingAnchorTo: nil, now: t0)
        try await queue.record(.success(status: 201), for: h.id, payloadBytes: 100, now: t0)
        let added = try await queue.enqueue([h], priority: .historic, advancingAnchorTo: nil, now: t0)
        #expect(added == 0)
        #expect(await queue.item(h.id)?.status == .sent)
        #expect(await queue.item(h.id)?.priority == .live)
    }

    @Test("Orden: live antes que histórico; dentro, la más reciente primero")
    func ordering() async throws {
        let queue = try makeQueue()
        let old = F.header(1, start: t0.addingTimeInterval(-86400 * 30))
        let recent = F.header(2, start: t0.addingTimeInterval(-3600))
        let historicNewest = F.header(3, start: t0)
        try await queue.enqueue([old, recent], priority: .live, advancingAnchorTo: nil, now: t0)
        try await queue.enqueue([historicNewest], priority: .historic, advancingAnchorTo: nil, now: t0)
        #expect(await queue.nextDue(now: t0)?.id == recent.id)
        #expect(await queue.nextDue(now: t0, excluding: [recent.id])?.id == old.id)
        #expect(await queue.nextDue(now: t0, excluding: [recent.id, old.id])?.id == historicNewest.id)
    }

    @Test("Reintento: cuenta el intento y programa con backoff")
    func retryBackoff() async throws {
        let queue = try makeQueue(random: 0)
        let h = F.header(1, start: t0)
        try await queue.enqueue([h], priority: .live, advancingAnchorTo: nil, now: t0)
        try await queue.record(.retry(status: 503, after: nil, message: "503"), for: h.id, payloadBytes: nil, now: t0)
        var item = try #require(await queue.item(h.id))
        #expect(item.attempts == 1)
        #expect(item.nextAttemptAt == t0.addingTimeInterval(15))
        #expect(await queue.nextDue(now: t0.addingTimeInterval(14)) == nil)
        #expect(await queue.nextDue(now: t0.addingTimeInterval(15))?.id == h.id)

        try await queue.record(.retry(status: nil, after: nil, message: "offline"), for: h.id, payloadBytes: nil, now: t0)
        item = try #require(await queue.item(h.id))
        #expect(item.attempts == 2)
        #expect(item.nextAttemptAt == t0.addingTimeInterval(30))
    }

    @Test("Retry-After del servidor manda sobre el backoff")
    func retryAfterWins() async throws {
        let queue = try makeQueue()
        let h = F.header(1, start: t0)
        try await queue.enqueue([h], priority: .live, advancingAnchorTo: nil, now: t0)
        try await queue.record(.retry(status: 429, after: 600, message: "429"), for: h.id, payloadBytes: nil, now: t0)
        #expect(await queue.item(h.id)?.nextAttemptAt == t0.addingTimeInterval(600))
    }

    @Test("401: pausa toda la cola sin marcar el elemento como fallido; al cambiar token se reanuda")
    func unauthorizedPauses() async throws {
        let queue = try makeQueue()
        let a = F.header(1, start: t0), b = F.header(2, start: t0.addingTimeInterval(-60))
        try await queue.enqueue([a, b], priority: .live, advancingAnchorTo: nil, now: t0)
        try await queue.record(.unauthorized(status: 401), for: a.id, payloadBytes: nil, now: t0)
        #expect(await queue.isAuthPaused)
        #expect(await queue.item(a.id)?.status == .pending)
        #expect(await queue.item(a.id)?.attempts == 0)
        #expect(await queue.nextDue(now: t0) == nil)

        try await queue.resumeAfterCredentialsChange(now: t0)
        #expect(await queue.isAuthPaused == false)
        #expect(await queue.nextDue(now: t0)?.id == a.id)
    }

    @Test("Error permanente: no vuelve a salir; reintento manual lo recupera")
    func permanentAndManualRetry() async throws {
        let queue = try makeQueue()
        let h = F.header(1, start: t0)
        try await queue.enqueue([h], priority: .live, advancingAnchorTo: nil, now: t0)
        try await queue.record(.permanent(status: 422, message: "422"), for: h.id, payloadBytes: nil, now: t0)
        #expect(await queue.item(h.id)?.status == .failed)
        #expect(await queue.nextDue(now: t0.addingTimeInterval(86400)) == nil)

        try await queue.retry(h.id, now: t0)
        #expect(await queue.item(h.id)?.status == .pending)
        #expect(await queue.nextDue(now: t0)?.id == h.id)
    }

    @Test("Próximo despertar: el pendiente más cercano; nada si está pausada o no hay pendientes")
    func nextWake() async throws {
        let queue = try makeQueue(random: 0)
        #expect(await queue.nextWakeDate() == nil)
        let a = F.header(1, start: t0), b = F.header(2, start: t0)
        try await queue.enqueue([a, b], priority: .live, advancingAnchorTo: nil, now: t0)
        try await queue.postpone(a.id, until: t0.addingTimeInterval(300), reason: "x")
        try await queue.record(.retry(status: 500, after: nil, message: "500"), for: b.id, payloadBytes: nil, now: t0)
        #expect(await queue.nextWakeDate() == t0.addingTimeInterval(15))
        try await queue.record(.success(status: 201), for: b.id, payloadBytes: nil, now: t0)
        #expect(await queue.nextWakeDate() == t0.addingTimeInterval(300))
        try await queue.record(.unauthorized(status: 401), for: a.id, payloadBytes: nil, now: t0)
        #expect(await queue.nextWakeDate() == nil)
    }

    @Test("Borrar enviados: quita solo los enviados y reinicia el ancla, en una escritura")
    func forgetSent() async throws {
        let store = InMemoryQueueStore()
        let queue = try makeQueue(store)
        let sent = F.header(1, start: t0), pending = F.header(2, start: t0), failed = F.header(3, start: t0)
        try await queue.enqueue([sent, pending, failed], priority: .live, advancingAnchorTo: Data("A".utf8), now: t0)
        try await queue.record(.success(status: 201), for: sent.id, payloadBytes: nil, now: t0)
        try await queue.record(.permanent(status: 422, message: "x"), for: failed.id, payloadBytes: nil, now: t0)
        let savesBefore = store.saveCount

        let removed = try await queue.forgetSentAndRediscover()

        #expect(removed == 1)
        #expect(store.saveCount == savesBefore + 1)
        #expect(await queue.item(sent.id) == nil)
        #expect(await queue.item(pending.id)?.status == .pending)
        #expect(await queue.item(failed.id)?.status == .failed)
        #expect(await queue.anchor == nil)
        #expect(store.current?.anchor == nil)
    }

    @Test("Aplazar no cuenta como intento")
    func postponeDoesNotCount() async throws {
        let queue = try makeQueue()
        let h = F.header(1, start: t0)
        try await queue.enqueue([h], priority: .live, advancingAnchorTo: nil, now: t0)
        try await queue.postpone(h.id, until: t0.addingTimeInterval(300), reason: "ruta")
        #expect(await queue.item(h.id)?.attempts == 0)
        #expect(await queue.nextDue(now: t0) == nil)
    }

    @Test("Persistencia: una cola nueva sobre el mismo almacén ve el mismo estado")
    func persistence() async throws {
        let store = InMemoryQueueStore()
        let h = F.header(1, start: t0)
        do {
            let queue = try makeQueue(store)
            try await queue.enqueue([h], priority: .live, advancingAnchorTo: Data("A".utf8), now: t0)
            try await queue.record(.retry(status: 500, after: nil, message: "500"), for: h.id, payloadBytes: 1234, now: t0)
        }
        let reopened = try makeQueue(store)
        #expect(await reopened.anchor == Data("A".utf8))
        let item = try #require(await reopened.item(h.id))
        #expect(item.attempts == 1)
        #expect(item.payloadBytes == 1234)
    }

    @Test("FileQueueStore: ida y vuelta en disco; un fichero corrupto se aparta")
    func fileStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileQueueStore(url: dir.appendingPathComponent("queue.json"))

        var manifest = QueueManifest()
        manifest.items = [QueueItem(header: F.header(1, start: t0), priority: .live, now: t0)]
        manifest.anchor = Data([1, 2, 3])
        try store.save(manifest)
        #expect(try store.load() == manifest)

        try Data("{no es json".utf8).write(to: store.url)
        #expect(try store.load() == nil)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers.contains { $0.contains("corrupt") })
    }
}
