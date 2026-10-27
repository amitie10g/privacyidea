# privacyIDEA (gunicorn) + FreeRADIUS with the privacyIDEA plugin, in ONE
# container supervised by supervisord. Built from the local repository, which
# must have the FreeRADIUS submodule checked out:
#   git submodule update --init FreeRADIUS

#  Stage 1: build the Angular web UI (the source tree does not ship it built)
FROM node:22-slim AS node-builder

WORKDIR /build/privacyidea/static

# Dependencies first, for better layer caching
COPY privacyidea/static/package.json privacyidea/static/package-lock.json ./
RUN npm ci

COPY privacyidea/static/ ./
RUN npm run build

#  Stage 2: runtime image
FROM python:slim

ENV DEBIAN_FRONTEND=noninteractive

# FreeRADIUS, the Perl modules required by the privacyIDEA plugin, and supervisord
RUN apt-get update && apt-get install -y --no-install-recommends \
        freeradius freeradius-utils supervisor \
        libwww-perl liblwp-protocol-https-perl libconfig-inifiles-perl \
        libdata-dump-perl libtry-tiny-perl libjson-perl liburi-encode-perl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY / /opt/privacyidea
WORKDIR /opt/privacyidea

# Pre-built web UI from the node-builder stage
COPY --from=node-builder /build/privacyidea/static/dist/ /opt/privacyidea/privacyidea/static/dist/

# Fail early if the submodule was not checked out on the host
RUN test -f FreeRADIUS/privacyidea_radius.pm \
    || { echo "ERROR: FreeRADIUS submodule is empty (git submodule update --init FreeRADIUS)" >&2; exit 1; }

RUN python -m venv venv \
    && venv/bin/pip install --no-cache-dir -r requirements.txt \
    && venv/bin/pip install --no-cache-dir gunicorn==23.0.0

# privacyIDEA RADIUS plugin and FreeRADIUS 3 configuration, from the submodule.
# The FreeRADIUS config directory differs between releases (/etc/freeradius or
# /etc/freeradius/3.0), so it is detected and exposed as /etc/freeradius-active.
# Only the privacyIDEA site and the perl module are enabled (no EAP).
RUN set -eux; \
    mkdir -p /usr/share/privacyidea/freeradius /etc/privacyidea; \
    cp FreeRADIUS/privacyidea_radius.pm FreeRADIUS/dictionary.netknights /usr/share/privacyidea/freeradius/; \
    FR="$(dirname "$(find /etc/freeradius -name radiusd.conf | head -n1)")"; \
    ln -s "$FR" /etc/freeradius-active; \
    rm -f "$FR"/sites-enabled/* "$FR"/mods-enabled/eap; \
    cp FreeRADIUS/config/freeradius3/mods-perl-privacyidea "$FR"/mods-available/perl-privacyidea; \
    ln -sf ../mods-available/perl-privacyidea "$FR"/mods-enabled/perl-privacyidea; \
    cp FreeRADIUS/config/freeradius3/privacyidea "$FR"/sites-available/privacyidea; \
    ln -sf ../sites-available/privacyidea "$FR"/sites-enabled/privacyidea; \
    echo '$INCLUDE /usr/share/privacyidea/freeradius/dictionary.netknights' >> "$FR"/dictionary

COPY supervisord.conf /etc/supervisor/conf.d/privacyidea.conf
COPY radius-setup.sh entrypoint /opt/privacyidea/
# CRLF line endings (files edited on Windows) would break the scripts
RUN sed -i 's/\r$//' /opt/privacyidea/entrypoint /opt/privacyidea/radius-setup.sh \
    && chmod +x /opt/privacyidea/entrypoint /opt/privacyidea/radius-setup.sh

# 5000/tcp: privacyIDEA (gunicorn, plain HTTP: put a TLS reverse proxy in front)
# 1812/udp: RADIUS authentication
EXPOSE 5000/tcp 1812/udp

ENTRYPOINT ["/opt/privacyidea/entrypoint"]