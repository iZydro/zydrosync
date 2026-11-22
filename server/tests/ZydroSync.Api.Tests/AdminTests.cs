using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using ZydroSync.Api.Admin;
using ZydroSync.Api.Data;

namespace ZydroSync.Api.Tests;

public sealed class AdminTests(AdminApiFactory api) : IClassFixture<AdminApiFactory>
{
    private async Task<(TestUser Owner, HttpClient Admin)> AdminAsync()
    {
        var owner = await api.CreateUserAsync();
        return (owner, api.ClientWith(await api.CreateTokenAsync(owner.Id, TokenKind.Admin)));
    }

    private async Task<Guid> UploadAsync(TestUser user, Guid? id = null)
    {
        var workoutId = id ?? Guid.NewGuid();
        var response = await api.ClientWith(user.DeviceToken).SendAsync(Payloads.PostGzip(workoutId, Payloads.Valid(workoutId)));
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        return workoutId;
    }

    [Fact]
    public async Task Only_admin_tokens_can_use_the_admin_api()
    {
        var user = await api.CreateUserAsync();
        var (_, admin) = await AdminAsync();

        Assert.Equal(HttpStatusCode.Forbidden, (await api.ClientWith(user.DeviceToken).GetAsync("/admin/api/users")).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await api.ClientWith(user.IntegrationToken).GetAsync("/admin/api/users")).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await api.ClientWith(null).GetAsync("/admin/api/users")).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await admin.GetAsync("/admin/api/users")).StatusCode);
    }

    [Fact]
    public async Task Admin_token_cannot_upload_workouts()
    {
        var (_, admin) = await AdminAsync();
        var id = Guid.NewGuid();
        var response = await admin.SendAsync(Payloads.PostGzip(id, Payloads.Valid(id)));
        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
    }

    [Fact]
    public async Task Lists_users_with_counts_and_tokens()
    {
        var runner = await api.CreateUserAsync();
        await UploadAsync(runner);
        await UploadAsync(runner);
        var (_, admin) = await AdminAsync();

        var users = await admin.GetFromJsonAsync<List<AdminUserDto>>("/admin/api/users");

        var row = Assert.Single(users!, u => u.Id == runner.Id);
        Assert.Equal(2, row.Workouts);
        Assert.True(row.DataBytes > 0);
        Assert.Contains(row.Tokens, t => t.Kind == "Device" && t.LastUsedAt is not null);
    }

    [Fact]
    public async Task Lists_workouts_and_serves_the_original_json()
    {
        var runner = await api.CreateUserAsync();
        var id = await UploadAsync(runner);
        var (_, admin) = await AdminAsync();

        var workouts = await admin.GetFromJsonAsync<List<AdminWorkoutDto>>($"/admin/api/users/{runner.Id}/workouts");
        var row = Assert.Single(workouts!);
        Assert.Equal(id, row.WorkoutId);
        Assert.Equal(3, row.RoutePoints);

        // HttpClient de TestServer no descomprime: se pide gzip y se comprueba a mano.
        var request = new HttpRequestMessage(HttpMethod.Get, $"/admin/api/users/{runner.Id}/workouts/{id}");
        request.Headers.AcceptEncoding.ParseAdd("gzip");
        var response = await admin.SendAsync(request);
        Assert.Equal("gzip", response.Content.Headers.ContentEncoding.Single());
        var json = JsonDocument.Parse(Payloads.Gunzip(await response.Content.ReadAsByteArrayAsync()));
        Assert.Equal(id.ToString().ToUpperInvariant(), json.RootElement.GetProperty("workoutId").GetString());
    }

    [Fact]
    public async Task Deleting_a_workout_affects_only_that_user()
    {
        var alice = await api.CreateUserAsync();
        var bob = await api.CreateUserAsync();
        var shared = Guid.NewGuid();
        await UploadAsync(alice, shared);
        await UploadAsync(bob, shared);
        var (_, admin) = await AdminAsync();

        var first = await admin.DeleteAsync($"/admin/api/users/{alice.Id}/workouts/{shared}");
        var again = await admin.DeleteAsync($"/admin/api/users/{alice.Id}/workouts/{shared}");

        Assert.Equal(HttpStatusCode.NoContent, first.StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, again.StatusCode);
        Assert.Empty((await admin.GetFromJsonAsync<List<AdminWorkoutDto>>($"/admin/api/users/{alice.Id}/workouts"))!);
        Assert.Single((await admin.GetFromJsonAsync<List<AdminWorkoutDto>>($"/admin/api/users/{bob.Id}/workouts"))!);

        // Tras borrarla en el servidor, la app puede volver a enviarla.
        var resent = await api.ClientWith(alice.DeviceToken).SendAsync(Payloads.PostGzip(shared, Payloads.Valid(shared)));
        Assert.Equal(HttpStatusCode.Created, resent.StatusCode);
    }

    [Fact]
    public async Task Revoked_token_stops_working()
    {
        var runner = await api.CreateUserAsync();
        var (_, admin) = await AdminAsync();

        var response = await admin.PostAsync($"/admin/api/tokens/{runner.DeviceTokenId}/revoke", null);

        Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
        var id = Guid.NewGuid();
        var upload = await api.ClientWith(runner.DeviceToken).SendAsync(Payloads.PostGzip(id, Payloads.Valid(id)));
        Assert.Equal(HttpStatusCode.Unauthorized, upload.StatusCode);
    }

    [Fact]
    public async Task Panel_is_served_with_security_headers()
    {
        var response = await api.CreateClient().GetAsync("/admin/");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("text/html", response.Content.Headers.ContentType?.MediaType);
        Assert.Contains("script-src 'self'", response.Headers.GetValues("Content-Security-Policy").Single());
        Assert.Equal("DENY", response.Headers.GetValues("X-Frame-Options").Single());
    }
}

public sealed class AdminDisabledTests(ApiFactory api) : IClassFixture<ApiFactory>
{
    [Fact]
    public async Task Admin_routes_do_not_exist_when_disabled()
    {
        var owner = await api.CreateUserAsync();
        var admin = api.ClientWith(await api.CreateTokenAsync(owner.Id, TokenKind.Admin));

        Assert.Equal(HttpStatusCode.NotFound, (await admin.GetAsync("/admin/api/users")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await api.CreateClient().GetAsync("/admin/")).StatusCode);
    }
}
