#!/bin/bash
# Builds the FreeRADIUS plugin config and the RADIUS client list from environment
# variables / secrets and validates it. FreeRADIUS itself is started by supervisord.
#
#   PI_URL             privacyIDEA validate endpoint
#                      (default: http://127.0.0.1:5000/validate/check)
#   PI_REALM           optional privacyIDEA realm (overrides the RADIUS realm)
#   PI_RESCONF         optional privacyIDEA resolver
#   PI_SSL_CHECK       verify the TLS certificate if PI_URL is https (default: true)
#   PI_SSL_CA_PATH     optional CA path for the TLS check
#   RADIUS_SECRET      shared secret with the RADIUS clients (the firewalls), or
#   RADIUS_SECRET_FILE file that contains it (default: /run/secrets/radius_secret)
#   RADIUS_CLIENTS     comma-separated IPs or networks allowed to send requests
#   RADIUS_INI_EXTRA   optional text appended to rlm_perl.ini (e.g. [Mapping user])
#   PALOALTO_USER_GROUP_ATTR  optional privacyIDEA user attribute returned to the
#                      Palo Alto as PaloAlto-User-Group (e.g. "group")
#   PALOALTO_ADMIN_ROLE_ATTR  optional privacyIDEA user attribute returned as
#                      PaloAlto-Admin-Role (for firewall administrator logins)
#                      Both need the privacyIDEA policy "add_user_in_response".
#                      Do not combine them with a [Mapping user] section in
#                      RADIUS_INI_EXTRA (use one or the other).
#   RADIUS_DEBUG       1 = run FreeRADIUS in debug mode (-X) and enable plugin DEBUG
set -euo pipefail

FR=/etc/freeradius-active
SECRET_FILE="${RADIUS_SECRET_FILE:-/run/secrets/radius_secret}"

if [ -z "${RADIUS_SECRET:-}" ] && [ -f "$SECRET_FILE" ]; then
    RADIUS_SECRET="$(cat "$SECRET_FILE")"
fi
: "${RADIUS_SECRET:?RADIUS_SECRET (or the secret file $SECRET_FILE) is required}"
: "${RADIUS_CLIENTS:?RADIUS_CLIENTS is required (client IPs or networks, comma-separated)}"

# The secret is written between double quotes in clients.conf
case "$RADIUS_SECRET" in
    *\"*|*\\*) echo "ERROR: the RADIUS secret must not contain double quotes or backslashes" >&2; exit 1 ;;
esac

if [ -n "${PALOALTO_USER_GROUP_ATTR:-}${PALOALTO_ADMIN_ROLE_ATTR:-}" ] \
   && printf '%s' "${RADIUS_INI_EXTRA:-}" | grep -qi '^\[Mapping user\]'; then
    echo "ERROR: PALOALTO_* attributes and a [Mapping user] section in RADIUS_INI_EXTRA cannot be combined" >&2
    exit 1
fi

DEBUG=false
[ "${RADIUS_DEBUG:-0}" = 1 ] && DEBUG=true

# --- privacyIDEA plugin configuration ---
{
    echo "[Default]"
    echo "URL = ${PI_URL:-http://127.0.0.1:5000/validate/check}"
    [ -n "${PI_REALM:-}" ]      && echo "REALM = ${PI_REALM}"
    [ -n "${PI_RESCONF:-}" ]    && echo "RESCONF = ${PI_RESCONF}"
    echo "SSL_CHECK = ${PI_SSL_CHECK:-true}"
    [ -n "${PI_SSL_CA_PATH:-}" ] && echo "SSL_CA_PATH = ${PI_SSL_CA_PATH}"
    echo "DEBUG = ${DEBUG}"
    echo "TIMEOUT = 10"
    # Palo Alto vendor-specific attributes (dictionary.paloalto ships with FreeRADIUS)
    if [ -n "${PALOALTO_USER_GROUP_ATTR:-}${PALOALTO_ADMIN_ROLE_ATTR:-}" ]; then
        echo
        echo "[Mapping user]"
        if [ -n "${PALOALTO_USER_GROUP_ATTR:-}" ]; then
            echo "${PALOALTO_USER_GROUP_ATTR} = PaloAlto-User-Group"
        fi
        if [ -n "${PALOALTO_ADMIN_ROLE_ATTR:-}" ]; then
            echo "${PALOALTO_ADMIN_ROLE_ATTR} = PaloAlto-Admin-Role"
        fi
    fi
    if [ -n "${RADIUS_INI_EXTRA:-}" ]; then
        echo
        printf '%s\n' "$RADIUS_INI_EXTRA"
    fi
} > /etc/privacyidea/rlm_perl.ini
# FreeRADIUS (group freerad) must be able to read the plugin config
chown root:freerad /etc/privacyidea/rlm_perl.ini
chmod 640 /etc/privacyidea/rlm_perl.ini

# --- RADIUS clients (the firewalls) ---
{
    # "localhost" allows testing from inside the container with radtest
    printf 'client localhost {\n\tipaddr = 127.0.0.1\n\tsecret = "%s"\n}\n' "$RADIUS_SECRET"
    IFS=',' read -ra ADDRS <<< "$RADIUS_CLIENTS"
    for a in "${ADDRS[@]}"; do
        a="$(echo "$a" | tr -d '[:space:]')"
        [ -n "$a" ] || continue
        name="$(echo "$a" | tr -c 'A-Za-z0-9\n' '_')"
        printf 'client %s {\n\tipaddr = %s\n\tsecret = "%s"\n\tnas_type = other\n}\n' "$name" "$a" "$RADIUS_SECRET"
    done
} > "$FR/clients.conf"
chown root:freerad "$FR/clients.conf"
chmod 640 "$FR/clients.conf"

# Fail early with a readable error if the FreeRADIUS configuration is invalid
/usr/sbin/freeradius -C -l stdout > /dev/null || { /usr/sbin/freeradius -C -l stdout; exit 1; }
