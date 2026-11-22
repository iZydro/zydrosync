using System.Net;
using System.Net.Http.Json;
using System.Text.Json.Nodes;
using Microsoft.EntityFrameworkCore;
using ZydroSync.Api.Data;
using ZydroSync.Api.Workouts;

namespace ZydroSync.Api.Tests;

public sealed class IngestTests(ApiFactory api) : IClassFixture<ApiFactory>
{
    [Fact]
    public async Task New_workout_is_created_and_stored_as_sent()
    {
        var user = await api.CreateUserAsync();
        var id = Guid.NewGuid();
        var gzip = Payloads.Gzip(Payloads.Json(Payloads.Valid(id, routePoints: 3)));

        var response = await api.ClientWith(user.DeviceToken).SendAsync(Payloads.Post(id, gzip));

        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        var result = await response.Content.ReadFromJsonAsync<IngestResult>();
        Assert.Equal("created", result!.Status);
        Assert.Equal(id, result.WorkoutId);

        var stored = await api.WithUserDbAsync(user.Id, db => db.Workouts.AsNoTracking().SingleAsync(w => w.WorkoutId == id));
        Assert.Equal(gzip, stored.PayloadGzip);  // el gzip original, sin recomprimir
        Assert.Equal("running", stored.Sport);
        Assert.Equal(3, stored.RoutePoints);
        Assert.Equal(5012.34, stored.DistanceM);
        Assert.Equal(new DateTimeOffset(2026, 11, 20, 7, 0, 0, TimeSpan.Zero), stored.StartDate);
        Assert.Equal("Watch7,12", stored.SourceProductType);
    }

    [Fact]
    public async Task Same_content_again_is_duplicate_and_does_not_touch_seq()
    {
        var user = await api.CreateUserAsync();
        var client = api.ClientWith(user.DeviceToken);
        var id = Guid.NewGuid();
        var payload = Payloads.Valid(id);

        var first = await (await client.SendAsync(Payloads.PostGzip(id, payload))).Content.ReadFromJsonAsync<IngestResult>();
        var second = await client.SendAsync(Payloads.PostGzip(id, payload));

        Assert.Equal(HttpStatusCode.OK, second.StatusCode);
        var result = await second.Content.ReadFromJsonAsync<IngestResult>();
        Assert.Equal("duplicate", result!.Status);
        Assert.Equal(first!.ServerId, result.ServerId);
        Assert.Equal(1, await api.WithUserDbAsync(user.Id, db => db.Workouts.CountAsync()));
    }

    [Fact]
    public async Task Changed_content_is_updated_with_a_new_seq()
    {
        var user = await api.CreateUserAsync();
        var client = api.ClientWith(user.DeviceToken);
        var id = Guid.NewGuid();
        var payload = Payloads.Valid(id);
        var first = await (await client.SendAsync(Payloads.PostGzip(id, payload))).Content.ReadFromJsonAsync<IngestResult>();

        payload["distanceM"] = 6000.0;
        var response = await client.SendAsync(Payloads.PostGzip(id, payload));

        var result = await response.Content.ReadFromJsonAsync<IngestResult>();
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("updated", result!.Status);
        Assert.True(long.Parse(result.ServerId!) > long.Parse(first!.ServerId!));
        Assert.Equal(6000.0, (await api.WithUserDbAsync(user.Id, db => db.Workouts.AsNoTracking().SingleAsync(w => w.WorkoutId == id))).DistanceM);
    }

    [Fact]
    public async Task Uncompressed_body_is_accepted_and_stored_compressed()
    {
        var user = await api.CreateUserAsync();
        var id = Guid.NewGuid();
        var json = Payloads.Json(Payloads.Valid(id));

        var response = await api.ClientWith(user.DeviceToken).SendAsync(Payloads.Post(id, json, encoding: null));

        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        var stored = await api.WithUserDbAsync(user.Id, db => db.Workouts.AsNoTracking().SingleAsync(w => w.WorkoutId == id));
        Assert.Equal(json, Payloads.Gunzip(stored.PayloadGzip));
    }

    [Fact]
    public async Task Same_uuid_for_two_users_is_stored_separately()
    {
        var alice = await api.CreateUserAsync();
        var bob = await api.CreateUserAsync();
        var id = Guid.NewGuid();

        var a = await api.ClientWith(alice.DeviceToken).SendAsync(Payloads.PostGzip(id, Payloads.Valid(id)));
        var b = await api.ClientWith(bob.DeviceToken).SendAsync(Payloads.PostGzip(id, Payloads.Valid(id)));

        Assert.Equal(HttpStatusCode.Created, a.StatusCode);
        Assert.Equal(HttpStatusCode.Created, b.StatusCode);
        Assert.Equal(1, await api.WithUserDbAsync(alice.Id, db => db.Workouts.CountAsync(w => w.WorkoutId == id)));
        Assert.Equal(1, await api.WithUserDbAsync(bob.Id, db => db.Workouts.CountAsync(w => w.WorkoutId == id)));
        Assert.NotEqual(api.Store.UserDbPath(alice.Id), api.Store.UserDbPath(bob.Id));
        Assert.True(File.Exists(api.Store.UserDbPath(alice.Id)) && File.Exists(api.Store.UserDbPath(bob.Id)));
    }

    [Fact]
    public async Task Deleting_a_user_deletes_all_their_data()
    {
        var user = await api.CreateUserAsync();
        var id = Guid.NewGuid();
        await api.ClientWith(user.DeviceToken).SendAsync(Payloads.PostGzip(id, Payloads.Valid(id)));

        Assert.True(api.Store.UserDbExists(user.Id));

        var deleted = await api.WithServiceAsync<AccountService, bool>(a => a.DeleteUserAsync(user.Id, CancellationToken.None));

        Assert.True(deleted);
        Assert.False(api.Store.UserDbExists(user.Id));
        Assert.False(File.Exists(api.Store.UserDbPath(user.Id) + "-wal"));
        Assert.Equal(0, await api.WithDirectoryAsync(db => db.ApiTokens.CountAsync(t => t.UserId == user.Id)));
        var again = await api.ClientWith(user.DeviceToken).SendAsync(Payloads.PostGzip(id, Payloads.Valid(id)));
        Assert.Equal(HttpStatusCode.Unauthorized, again.StatusCode);
    }

    // --- Autenticación ---

    [Fact]
    public async Task Missing_token_is_401_problem_json()
    {
        var id = Guid.NewGuid();
        var response = await api.ClientWith(null).SendAsync(Payloads.PostGzip(id, Payloads.Valid(id)));

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        Assert.Equal("application/problem+json", response.Content.Headers.ContentType?.MediaType);
        Assert.Contains("Bearer", response.Headers.WwwAuthenticate.ToString());
    }

    [Fact]
    public async Task Unknown_or_revoked_token_is_401()
    {
        var user = await api.CreateUserAsync();
        await api.WithDirectoryAsync(db => db.ApiTokens.Where(t => t.Id == user.DeviceTokenId)
            .ExecuteUpdateAsync(s => s.SetProperty(t => t.RevokedAt, DateTimeOffset.UtcNow)));
        var id = Guid.NewGuid();

        var revoked = await api.ClientWith(user.DeviceToken).SendAsync(Payloads.PostGzip(id, Payloads.Valid(id)));
        var unknown = await api.ClientWith("zsd_esto-no-existe").SendAsync(Payloads.PostGzip(id, Payloads.Valid(id)));

        Assert.Equal(HttpStatusCode.Unauthorized, revoked.StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, unknown.StatusCode);
    }

    [Fact]
    public async Task Integration_token_cannot_write()
    {
        var user = await api.CreateUserAsync();
        var id = Guid.NewGuid();
        var response = await api.ClientWith(user.IntegrationToken).SendAsync(Payloads.PostGzip(id, Payloads.Valid(id)));
        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
    }

    // --- Validación ---

    [Fact]
    public async Task Missing_idempotency_key_is_400_and_mismatch_is_422()
    {
        var user = await api.CreateUserAsync();
        var client = api.ClientWith(user.DeviceToken);
        var id = Guid.NewGuid();
        var body = Payloads.Gzip(Payloads.Json(Payloads.Valid(id)));

        Assert.Equal(HttpStatusCode.BadRequest, (await client.SendAsync(Payloads.Post(null, body))).StatusCode);
        Assert.Equal((HttpStatusCode)422, (await client.SendAsync(Payloads.Post(Guid.NewGuid(), body))).StatusCode);
    }

    public static TheoryData<string, Action<JsonObject>> InvalidPayloads => new()
    {
        { "sin source", p => p.Remove("source") },
        { "sin series", p => p.Remove("series") },
        { "schemaVersion 2", p => p["schemaVersion"] = 2 },
        { "fin antes que inicio", p => p["endDate"] = "2026-11-20T06:00:00Z" },
        { "fecha no ISO", p => p["startDate"] = "ayer" },
        { "distancia negativa", p => p["distanceM"] = -1 },
        { "indoor no booleano", p => p["indoor"] = "no" },
        { "ruta desalineada", p => p["route"]!["lat"]!.AsArray().RemoveAt(0) },
    };

    [Theory]
    [MemberData(nameof(InvalidPayloads))]
    public async Task Payload_that_breaks_the_contract_is_422(string name, Action<JsonObject> breakIt)
    {
        var user = await api.CreateUserAsync();
        var id = Guid.NewGuid();
        var payload = Payloads.Valid(id);
        breakIt(payload);

        var response = await api.ClientWith(user.DeviceToken).SendAsync(Payloads.PostGzip(id, payload));

        Assert.True(response.StatusCode == (HttpStatusCode)422, $"{name}: {response.StatusCode}");
    }

    [Fact]
    public async Task Unknown_fields_are_tolerated()
    {
        var user = await api.CreateUserAsync();
        var id = Guid.NewGuid();
        var payload = Payloads.Valid(id);
        payload["campoDelFuturo"] = new JsonObject { ["x"] = 1 };

        var response = await api.ClientWith(user.DeviceToken).SendAsync(Payloads.PostGzip(id, payload));

        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
    }

    [Fact]
    public async Task Malformed_json_or_gzip_is_400()
    {
        var user = await api.CreateUserAsync();
        var client = api.ClientWith(user.DeviceToken);
        var id = Guid.NewGuid();

        var badJson = await client.SendAsync(Payloads.Post(id, Payloads.Gzip("{no es json"u8.ToArray())));
        var badGzip = await client.SendAsync(Payloads.Post(id, "esto no es gzip"u8.ToArray()));

        Assert.Equal(HttpStatusCode.BadRequest, badJson.StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, badGzip.StatusCode);
    }

    [Fact]
    public async Task Wrong_content_type_or_encoding_is_415()
    {
        var user = await api.CreateUserAsync();
        var client = api.ClientWith(user.DeviceToken);
        var id = Guid.NewGuid();
        var body = Payloads.Gzip(Payloads.Json(Payloads.Valid(id)));

        Assert.Equal(HttpStatusCode.UnsupportedMediaType,
            (await client.SendAsync(Payloads.Post(id, body, contentType: "text/plain"))).StatusCode);
        Assert.Equal(HttpStatusCode.UnsupportedMediaType,
            (await client.SendAsync(Payloads.Post(id, body, encoding: "br"))).StatusCode);
    }

    [Fact]
    public async Task Gzip_bomb_is_rejected_with_413_without_inflating_it()
    {
        var user = await api.CreateUserAsync();
        var id = Guid.NewGuid();
        // 64 MB de ceros comprimen a ~64 KB: pasa el límite de cuerpo, no el de JSON.
        var bomb = Payloads.Gzip(new byte[64 * 1024 * 1024]);
        Assert.True(bomb.Length < 1024 * 1024);

        var response = await api.ClientWith(user.DeviceToken).SendAsync(Payloads.Post(id, bomb));

        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, response.StatusCode);
    }

    [Fact]
    public async Task Concurrent_uploads_for_one_user_get_distinct_increasing_seqs()
    {
        var user = await api.CreateUserAsync();
        var client = api.ClientWith(user.DeviceToken);
        var ids = Enumerable.Range(0, 20).Select(_ => Guid.NewGuid()).ToArray();

        var responses = await Task.WhenAll(ids.Select(id => client.SendAsync(Payloads.PostGzip(id, Payloads.Valid(id)))));

        Assert.All(responses, r => Assert.Equal(HttpStatusCode.Created, r.StatusCode));
        var seqs = await api.WithUserDbAsync(user.Id, db => db.Workouts.Select(w => w.Seq).OrderBy(s => s).ToListAsync());
        Assert.Equal(Enumerable.Range(1, 20).Select(i => (long)i), seqs);
    }

    [Fact]
    public async Task Healthz_reports_ok()
    {
        var response = await api.CreateClient().GetAsync("/healthz");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }
}

public sealed class RateLimitTests(RateLimitedApiFactory api) : IClassFixture<RateLimitedApiFactory>
{
    [Fact]
    public async Task Over_the_limit_is_429_with_retry_after()
    {
        var user = await api.CreateUserAsync();
        var client = api.ClientWith(user.DeviceToken);

        HttpResponseMessage? last = null;
        for (var i = 0; i < 3; i++)
        {
            var id = Guid.NewGuid();
            last = await client.SendAsync(Payloads.PostGzip(id, Payloads.Valid(id)));
        }

        Assert.Equal(HttpStatusCode.TooManyRequests, last!.StatusCode);
        Assert.True(last.Headers.RetryAfter?.Delta > TimeSpan.Zero);
    }
}
