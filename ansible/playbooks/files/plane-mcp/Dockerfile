# plane-mcp-server with a patched key validator (PET-882). The upstream image is pinned and
# the OCI registry on 106 is gone, so docker-compose.yml builds this on plane-235.
FROM makeplane/plane-mcp-server:v0.3.0
COPY plane_header_auth_provider.py /tmp/plane_header_auth_provider.py
# Overwrite the upstream module in place and fail the build if it is not where expected.
RUN set -e; \
    target="$(python -c 'import plane_mcp.auth.plane_header_auth_provider as m; print(m.__file__)')"; \
    cp /tmp/plane_header_auth_provider.py "$target"; \
    grep -q PLANE_KEY_CACHE_TTL "$target"; \
    rm /tmp/plane_header_auth_provider.py
