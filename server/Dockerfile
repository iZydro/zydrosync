# Imagen de producción. Compilación en el SDK; ejecución en la imagen "chiseled" de
# ASP.NET: sin shell ni gestor de paquetes y con usuario sin privilegios (uid 1654) por
# defecto. Menos superficie de ataque para un servicio que guarda datos de salud.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY src/ZydroSync.Api/ZydroSync.Api.csproj src/ZydroSync.Api/
RUN dotnet restore src/ZydroSync.Api/ZydroSync.Api.csproj
COPY src/ src/
RUN dotnet publish src/ZydroSync.Api -c Release -o /app --no-restore /p:UseAppHost=false
# La imagen chiseled no tiene shell para hacer mkdir/chown: el directorio de datos se
# prepara aquí y se copia con el propietario correcto. Un volumen montado en /data hereda
# ese propietario la primera vez.
RUN mkdir -p /data/users

FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled AS runtime
WORKDIR /app
COPY --from=build /app .
COPY --from=build --chown=1654:1654 /data /data
ENV ASPNETCORE_HTTP_PORTS=8080 \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    Storage__DataDirectory=/data
VOLUME /data
EXPOSE 8080
ENTRYPOINT ["dotnet", "ZydroSync.Api.dll"]
