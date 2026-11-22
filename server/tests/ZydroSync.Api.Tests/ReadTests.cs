using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using ZydroSync.Api.Data;
using ZydroSync.Api.Workouts;

namespace ZydroSync.Api.Tests;

public sealed class ReadTests(ApiFactory api) : IClassFixture<ApiFactory>
{
    private async Task<Guid> UploadAsync(TestUser user, Guid? id = null, int routePoints = 3)
    {
        var workoutId = id ?? Guid.NewGuid();
        var response = await api.ClientWith(user.DeviceToken)
            .SendAsync(Payloads.PostGzip(workoutId, Payloads.Valid(workoutId, routePoints)));
        Assert.True(response.IsSuccessStatusCode, response.StatusCode.ToString());
        return workoutId;
    }

    private async Task<HttpClient> WebClientAsync(TestUser user) =>
        api.ClientWith(await api.CreateTokenAsync(user.Id, TokenKind.Web));

    [Fact]
    public async Task Device_integration_and_web_tokens_can_read_but_admin_cannot()
    {
        var user = await api.CreateUserAsync();
        await UploadAsync(user);

        foreach (var client in new[] { api.ClientWith(user.DeviceToken), api.ClientWith(user.IntegrationToken), await WebClientAsync(user) })
        {
            var page = await client.GetFromJsonAsync<WorkoutPage>("/v1/workouts");
            Assert.Single(page!.Items);
        }
        var admin = api.ClientWith(await api.CreateTokenAsync(user.Id, TokenKind.Admin));
        Assert.Equal(HttpStatusCode.Forbidden, (await admin.GetAsync("/v1/workouts")).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await api.ClientWith(null).GetAsync("/v1/workouts")).StatusCode);
    }

    [Fact]
    public async Task Web_token_cannot_upload()
    {
        var user = await api.CreateUserAsync();
        var web = await WebClientAsync(user);
        var id = Guid.NewGuid();

        var response = await web.SendAsync(Payloads.PostGzip(id, Payloads.Valid(id)));

        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
    }

    [Fact]
    public async Task Each_token_only_sees_its_own_user()
    {
        var alice = await api.CreateUserAsync();
        var bob = await api.CreateUserAsync();
        var id = await UploadAsync(alice);
        var bobWeb = await WebClientAsync(bob);

        Assert.Empty((await bobWeb.GetFromJsonAsync<WorkoutPage>("/v1/workouts"))!.Items);
        Assert.Equal(HttpStatusCode.NotFound, (await bobWeb.GetAsync($"/v1/workouts/{id}")).StatusCode);
    }

    [Fact]
    public async Task Pages_by_server_id_and_updates_reappear_after_the_cursor()
    {
        var user = await api.CreateUserAsync();
        var first = await UploadAsync(user);
        await UploadAsync(user);
        await UploadAsync(user);
        var web = await WebClientAsync(user);

        var page1 = (await web.GetFromJsonAsync<WorkoutPage>("/v1/workouts?limit=2"))!;
        var page2 = (await web.GetFromJsonAsync<WorkoutPage>($"/v1/workouts?limit=2&after={page1.NextAfter}"))!;

        Assert.Equal(2, page1.Items.Count);
        Assert.Equal(first, page1.Items[0].WorkoutId);
        Assert.Equal(page1.Items[1].ServerId, page1.NextAfter);
        Assert.Single(page2.Items);
        Assert.Null(page2.NextAfter);

        // Un importador que ya lo había leído todo ve la versión nueva de la primera.
        var cursor = page2.Items[0].ServerId;
        await UploadAsync(user, first, routePoints: 5);
        var changes = (await web.GetFromJsonAsync<WorkoutPage>($"/v1/workouts?after={cursor}"))!;
        var updated = Assert.Single(changes.Items);
        Assert.Equal(first, updated.WorkoutId);
        Assert.Equal(5, updated.RoutePoints);
    }

    [Theory]
    [InlineData("?after=abc")]
    [InlineData("?after=-1")]
    [InlineData("?limit=0")]
    [InlineData("?limit=501")]
    public async Task Rejects_bad_paging_parameters(string query)
    {
        var user = await api.CreateUserAsync();
        var response = await (await WebClientAsync(user)).GetAsync($"/v1/workouts{query}");
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task Serves_the_payload_gzipped_only_when_the_client_accepts_it()
    {
        var user = await api.CreateUserAsync();
        var id = await UploadAsync(user);
        var web = await WebClientAsync(user);

        var plain = await web.GetAsync($"/v1/workouts/{id}");
        Assert.Empty(plain.Content.Headers.ContentEncoding);
        Assert.Equal(id.ToString().ToUpperInvariant(),
            JsonDocument.Parse(await plain.Content.ReadAsByteArrayAsync()).RootElement.GetProperty("workoutId").GetString());

        var request = new HttpRequestMessage(HttpMethod.Get, $"/v1/workouts/{id}");
        request.Headers.AcceptEncoding.ParseAdd("gzip, deflate, br");
        var gzipped = await web.SendAsync(request);
        Assert.Equal("gzip", gzipped.Content.Headers.ContentEncoding.Single());
        Assert.Equal(id.ToString().ToUpperInvariant(),
            JsonDocument.Parse(Payloads.Gunzip(await gzipped.Content.ReadAsByteArrayAsync())).RootElement.GetProperty("workoutId").GetString());
    }

    [Theory]
    [InlineData("gzip", true)]
    [InlineData("gzip, deflate, br, zstd", true)]
    [InlineData("gzip;q=0.5", true)]
    [InlineData("*", true)]
    [InlineData("gzip;q=0", false)]
    [InlineData("br", false)]
    [InlineData("", false)]
    public void Parses_accept_encoding(string header, bool expected) =>
        Assert.Equal(expected, WorkoutRead.AcceptsGzip(header));

    [Fact]
    public async Task Serves_the_web_with_security_headers()
    {
        var client = api.CreateClient();

        var page = await client.GetAsync("/");
        var leaflet = await client.GetAsync("/shared/vendor/leaflet/leaflet.js");

        Assert.Equal(HttpStatusCode.OK, page.StatusCode);
        Assert.Equal("text/html", page.Content.Headers.ContentType?.MediaType);
        Assert.Contains("script-src 'self'", page.Headers.GetValues("Content-Security-Policy").Single());
        Assert.Equal(HttpStatusCode.OK, leaflet.StatusCode);
    }
}
