# Builds a self-contained NativeAOT kql-guard binary, then ships only the binary
# in a tiny runtime image. Suitable for direct use and for layering into
# super-linter (copy /usr/local/bin/kql-guard into the super-linter image).
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
RUN apt-get update && apt-get install -y --no-install-recommends clang zlib1g-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN dotnet publish -c Release -r linux-x64 -o /out

FROM mcr.microsoft.com/dotnet/runtime-deps:10.0
COPY --from=build /out/kql-guard /usr/local/bin/kql-guard
ENTRYPOINT ["kql-guard"]
