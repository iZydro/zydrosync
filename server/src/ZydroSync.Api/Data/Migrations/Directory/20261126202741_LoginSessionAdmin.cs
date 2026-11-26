using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace ZydroSync.Api.Data.Migrations.Directory
{
    /// <inheritdoc />
    public partial class LoginSessionAdmin : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<bool>(
                name: "Admin",
                table: "login_sessions",
                type: "INTEGER",
                nullable: false,
                defaultValue: false);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "Admin",
                table: "login_sessions");
        }
    }
}
