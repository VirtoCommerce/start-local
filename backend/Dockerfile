# The Docker platform image: the vc-build output in ./publish on the vc-docker platform base
# (VirtoCommerce/vc-docker, branch feat/net10), plus curl for the health check and an entrypoint.
# The listening port and the scheme come from the compose files (ASPNETCORE_URLS).
FROM mcr.microsoft.com/dotnet/aspnet:10.0

COPY publish /opt/virtocommerce/platform

COPY ./entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN apt-get update && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get install -y --no-install-recommends curl wkhtmltopdf && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    wkhtmltopdf --version

RUN find /opt/virtocommerce/platform/modules -path "*/bin/runtimes/linux-x64/**/*" -type f \
    -exec cp "{}" /opt/virtocommerce/platform/app_data/modules/ \; || true

WORKDIR /opt/virtocommerce/platform

ENTRYPOINT ["/entrypoint.sh"]
CMD ["dotnet", "VirtoCommerce.Platform.Web.dll"]
