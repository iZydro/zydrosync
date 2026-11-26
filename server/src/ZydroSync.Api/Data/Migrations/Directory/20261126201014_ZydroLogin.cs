using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace ZydroSync.Api.Data.Migrations.Directory
{
    /// <inheritdoc />
    public partial class ZydroLogin : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<long>(
                name: "LoginLinkedAt",
                table: "users",
                type: "INTEGER",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "LoginSubject",
                table: "users",
                type: "TEXT",
                maxLength: 255,
                nullable: true);

            migrationBuilder.CreateTable(
                name: "login_sessions",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    UserId = table.Column<Guid>(type: "TEXT", nullable: false),
                    Hash = table.Column<byte[]>(type: "BLOB", nullable: false),
                    Subject = table.Column<string>(type: "TEXT", maxLength: 255, nullable: false),
                    AccessToken = table.Column<string>(type: "TEXT", nullable: false),
                    RefreshToken = table.Column<string>(type: "TEXT", nullable: true),
                    AccessTokenExpiresAt = table.Column<long>(type: "INTEGER", nullable: false),
                    CreatedAt = table.Column<long>(type: "INTEGER", nullable: false),
                    LastSeenAt = table.Column<long>(type: "INTEGER", nullable: false),
                    ExpiresAt = table.Column<long>(type: "INTEGER", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_login_sessions", x => x.Id);
                    table.ForeignKey(
                        name: "FK_login_sessions_users_UserId",
                        column: x => x.UserId,
                        principalTable: "users",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "IX_users_LoginSubject",
                table: "users",
                column: "LoginSubject",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_login_sessions_ExpiresAt",
                table: "login_sessions",
                column: "ExpiresAt");

            migrationBuilder.CreateIndex(
                name: "IX_login_sessions_Hash",
                table: "login_sessions",
                column: "Hash",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_login_sessions_UserId",
                table: "login_sessions",
                column: "UserId");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "login_sessions");

            migrationBuilder.DropIndex(
                name: "IX_users_LoginSubject",
                table: "users");

            migrationBuilder.DropColumn(
                name: "LoginLinkedAt",
                table: "users");

            migrationBuilder.DropColumn(
                name: "LoginSubject",
                table: "users");
        }
    }
}
