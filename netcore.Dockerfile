FROM mcr.microsoft.com/dotnet/core/sdk:3.1.301-buster as dotnet-sdk
FROM continuumio/miniconda3:4.8.2 as base

# Enable detection of running in a container
ENV DOTNET_RUNNING_IN_CONTAINER=true \
    # Enable correct mode for dotnet watch (only mode supported in a container)
    DOTNET_USE_POLLING_FILE_WATCHER=true \
    # Skip extraction of XML docs - generally not useful within an image/container - helps performance
    NUGET_XMLDOC_MODE=skip \
    # PowerShell telemetry for docker image usage
    POWERSHELL_DISTRIBUTION_CHANNEL=PSDocker-DotnetCoreSDK-Debian-10 \
    # Configure web servers to bind to port 80 when present
    ASPNETCORE_URLS=http://+:80

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        \
# .NET Core dependencies
        libc6 \
        libgcc1 \
        libgssapi-krb5-2 \
        libicu63 \
        libssl1.1 \
        libstdc++6 \
        zlib1g \
    && rm -rf /var/lib/apt/lists/*

COPY --from=dotnet-sdk /usr/share/dotnet /usr/share/dotnet
RUN ln -s /usr/share/dotnet/dotnet /usr/bin/dotnet \
    # Trigger first run experience by running arbitrary cmd
    && dotnet help

COPY --from=dotnet-sdk /usr/share/powershell /usr/share/powershell
RUN ln -s /usr/share/powershell/pwsh /usr/bin/pwsh

# Install .NET Core
# RUN dotnet_version=3.1.5 \
#     && wget -O dotnet.tar.gz https://dotnetcli.azureedge.net/dotnet/Runtime/$dotnet_version/dotnet-runtime-$dotnet_version-linux-musl-x64.tar.gz \
#     && dotnet_sha512='2f98acecc0779dba03fc5ee674d6305dda780f174af47582d80d556002028df0b6a594e5d13dd36f8a1443e5fc6950ef126064ba6c4b3109b490c6d5ebcb9f39' \
#     && echo "$dotnet_sha512  dotnet.tar.gz" | sha512sum -c - \
#     && mkdir -p /usr/share/dotnet \
#     && tar -C /usr/share/dotnet -oxzf dotnet.tar.gz \
#     && ln -s /usr/share/dotnet/dotnet /usr/bin/dotnet \
#     && rm dotnet.tar.gz

# Install PowerShell global tool
# RUN powershell_version=7.0.1 \
#     && curl -SL --output PowerShell.Linux.x64.$powershell_version.nupkg https://pwshtool.blob.core.windows.net/tool/$powershell_version/PowerShell.Linux.x64.$powershell_version.nupkg \
#     && powershell_sha512='b6b67b59233b3ad68e33e49eff16caeb3b1c87641b9a6cd518a19e3ff69491a8a1b3c5026635549c7fd377a902a33ca17f41b7913f66099f316882390448c3f7' \
#     && echo "$powershell_sha512  PowerShell.Linux.x64.$powershell_version.nupkg" | sha512sum -c - \
#     && mkdir -p /usr/share/powershell \
#     && dotnet tool install --add-source / --tool-path /usr/share/powershell --version $powershell_version PowerShell.Linux.x64 \
#     && dotnet nuget locals all --clear \
#     && rm PowerShell.Linux.x64.$powershell_version.nupkg \
#     && ln -s /usr/share/powershell/pwsh /usr/bin/pwsh \
#     && chmod 755 /usr/share/powershell/pwsh \
#     # To reduce image size, remove the copy nupkg that nuget keeps.
#     && find /usr/share/powershell -print | grep -i '.*[.]nupkg$' | xargs rm

# Install Jupyter and extensions
RUN conda update -n base -c defaults conda \
    && conda install -c anaconda jupyter \
    && conda install -c conda-forge \
        ipywidgets \
        jupyter_contrib_nbextensions \
        jupyter_nbextensions_configurator

FROM mcr.microsoft.com/dotnet/core/sdk:3.1.301-buster as build

# By copying just the files required to do a restore, we can skip the restore phase of incremental builds
WORKDIR /IfSharp
COPY build.* fake.* IfSharpNetCore.sln paket.* .config ./
COPY src/IfSharp/*.fsproj src/IfSharp/Paket.* src/IfSharp/paket.* /IfSharp/src/IfSharp/
COPY src/IfSharp.Kernel/*.fsproj src/IfSharp.Kernel/paket.* /IfSharp/src/IfSharp.Kernel/
COPY src/IfSharpNetCore/*.fsproj src/IfSharp.Kernel/Paket.* src/IfSharp.Kernel/paket.* /IfSharp/src/IfSharpNetCore/

# Add user
RUN useradd -ms /bin/bash ifsharp-user \
    && chown -R ifsharp-user:ifsharp-user /IfSharp \
    && chmod +x ./fake.sh \
    && ./fake.sh build --target RestoreNetCore

COPY jupyter-kernel jupyter-kernel
COPY src src

RUN chmod +x ./fake.sh \
    && ./fake.sh build --target BuildNetCore \
    # TODO use a publish or something instead so we can stop installing from the debug/release folders
    && chown -R ifsharp-user /IfSharp

USER ifsharp-user

# puts the files into /home/ifsharp-user/.local/share/jupyter/
RUN dotnet src/IfSharpNetCore/bin/x64/Debug/netcoreapp3.1/IfSharpNetCore.dll --install
# not a mistake - for some reason the copy doesn't work the first time?
RUN dotnet src/IfSharpNetCore/bin/x64/Debug/netcoreapp3.1/IfSharpNetCore.dll --install

FROM base as app

# Add user
RUN useradd -ms /bin/bash ifsharp-user \
    # should this be in the user folder?
    && mkdir -p /notebooks \
    && chown -R ifsharp-user /notebooks

VOLUME notebooks

WORKDIR /home/ifsharp-user/

COPY --from=build /home/ifsharp-user/.local /home/ifsharp-user/.local
# artifact of directly installing from the Debug folder from src
# it would be preferable to use a properly published version so we don't copy the source
COPY --from=build /IfSharp /IfSharp

RUN chown -R ifsharp-user:ifsharp-user /home/ifsharp-user/.local

USER ifsharp-user

# Install extensions and configurator
RUN jupyter contrib nbextension install --user
RUN jupyter nbextensions_configurator enable --user
RUN jupyter nbextension enable --py widgetsnbextension --user

USER ifsharp-user

EXPOSE 8888

# Final entrypoint
ENTRYPOINT ["jupyter", \
            "notebook", \
            "--no-browser", \
            "--ip='0.0.0.0'", \
            "--port=8888", \
            "--notebook-dir=/notebooks" \
            ]
