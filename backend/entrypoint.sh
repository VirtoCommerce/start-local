#!/bin/sh
set -eu

# E11: the Elasticsearch setup container (HTTPS mode) writes the CA's SHA-256 next to the CA in the certificates
# volume. The search module trusts the CA through its CertificateFingerprint option.
fingerprint_file=/certs/ca/ca.fingerprint
if [ -f "$fingerprint_file" ] && [ -n "${SEARCH_PROVIDER:-}" ]; then
    export "Search__${SEARCH_PROVIDER}__CertificateFingerprint=$(tr -d '[:space:]' < "$fingerprint_file")"
fi

exec "$@"
