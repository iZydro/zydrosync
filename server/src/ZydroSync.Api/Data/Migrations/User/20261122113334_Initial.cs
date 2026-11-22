using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace ZydroSync.Api.Data.Migrations.User
{
    /// <inheritdoc />
    public partial class Initial : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "workouts",
                columns: table => new
                {
                    WorkoutId = table.Column<Guid>(type: "TEXT", nullable: false),
                    Seq = table.Column<long>(type: "INTEGER", nullable: false),
                    SchemaVersion = table.Column<int>(type: "INTEGER", nullable: false),
                    Sport = table.Column<string>(type: "TEXT", maxLength: 40, nullable: false),
                    StartDate = table.Column<long>(type: "INTEGER", nullable: false),
                    EndDate = table.Column<long>(type: "INTEGER", nullable: false),
                    DurationSec = table.Column<double>(type: "REAL", nullable: false),
                    DistanceM = table.Column<double>(type: "REAL", nullable: true),
                    Indoor = table.Column<bool>(type: "INTEGER", nullable: false),
                    SourceBundleId = table.Column<string>(type: "TEXT", maxLength: 200, nullable: false),
                    SourceProductType = table.Column<string>(type: "TEXT", maxLength: 40, nullable: true),
                    RoutePoints = table.Column<int>(type: "INTEGER", nullable: false),
                    PayloadGzip = table.Column<byte[]>(type: "BLOB", nullable: false),
                    PayloadSha256 = table.Column<byte[]>(type: "BLOB", nullable: false),
                    PayloadJsonBytes = table.Column<int>(type: "INTEGER", nullable: false),
                    ReceivedAt = table.Column<long>(type: "INTEGER", nullable: false),
                    UpdatedAt = table.Column<long>(type: "INTEGER", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_workouts", x => x.WorkoutId);
                });

            migrationBuilder.CreateIndex(
                name: "IX_workouts_Seq",
                table: "workouts",
                column: "Seq",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_workouts_StartDate",
                table: "workouts",
                column: "StartDate");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "workouts");
        }
    }
}
