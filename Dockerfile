ARG PG_VERSION
ARG PREV_TS_VERSION=1.5.0
ARG PREV_EXTRA
############################
# Build tools binaries in separate image
############################
ARG GO_VERSION=1.12.13
FROM golang:${GO_VERSION}-alpine AS tools

ENV TOOLS_VERSION 0.7.0

RUN apk update && apk add --no-cache git \
    && mkdir -p ${GOPATH}/src/github.com/timescale/ \
    && cd ${GOPATH}/src/github.com/timescale/ \
    && git clone https://github.com/timescale/timescaledb-tune.git \
    && git clone https://github.com/timescale/timescaledb-parallel-copy.git \
    # Build timescaledb-tune
    && cd timescaledb-tune/cmd/timescaledb-tune \
    && git fetch && git checkout --quiet $(git describe --abbrev=0) \
    && go get -d -v \
    && go build -o /go/bin/timescaledb-tune \
    # Build timescaledb-parallel-copy
    && cd ${GOPATH}/src/github.com/timescale/timescaledb-parallel-copy/cmd/timescaledb-parallel-copy \
    && git fetch && git checkout --quiet $(git describe --abbrev=0) \
    && go get -d -v \
    && go build -o /go/bin/timescaledb-parallel-copy

############################
# Grab old versions from previous version
############################
ARG PG_VERSION
FROM timescale/timescaledb:${PREV_TS_VERSION}-pg${PG_VERSION}${PREV_EXTRA} AS oldversions
# Remove update files, mock files, and all but the last 5 .so/.sql files
RUN rm -f $(pg_config --sharedir)/extension/timescaledb--*--*.sql \
    && rm -f $(pg_config --sharedir)/extension/timescaledb*mock*.sql \
    && rm -f $(ls -1 $(pg_config --pkglibdir)/timescaledb-tsl-*.so | head -n -5) \
    && rm -f $(ls -1 $(pg_config --pkglibdir)/timescaledb-1*.so | head -n -5) \
    && rm -f $(ls -1 $(pg_config --sharedir)/extension/timescaledb-*.sql | head -n -5)

############################
# Now build image and copy in tools
############################
ARG PG_VERSION
FROM postgres:${PG_VERSION}-alpine
ARG OSS_ONLY
ARG PG_SERV_VERSION
ARG POSTGIS_VERSION
ENV POSTGIS_VERSION ${POSTGIS_VERSION:-2.5.2}

MAINTAINER Jayaraj Esvar https://www.nxtthinq.com

# Update list above to include previous versions when changing this
ENV TIMESCALEDB_VERSION 1.5.1

COPY docker-entrypoint-initdb.d/* /docker-entrypoint-initdb.d/
COPY --from=tools /go/bin/* /usr/local/bin/
COPY --from=oldversions /usr/local/lib/postgresql/timescaledb-*.so /usr/local/lib/postgresql/
COPY --from=oldversions /usr/local/share/postgresql/extension/timescaledb--*.sql /usr/local/share/postgresql/extension/

RUN set -ex \
          && apk add --no-cache --virtual .fetch-deps ca-certificates openssl tar \
          && wget -O postgresql.tar.bz2 "https://ftp.postgresql.org/pub/source/v${PG_SERV_VERSION}/postgresql-${PG_SERV_VERSION}.tar.bz2" \	
         # && echo "$PG_SHA256 *postgresql.tar.bz2" | sha256sum -c - \ 	
          && mkdir -p /usr/src/postgresql \
          && tar --extract --file postgresql.tar.bz2 --directory /usr/src/postgresql --strip-components 1 \
	  && rm postgresql.tar.bz2 \
          && apk add --no-cache --virtual .build-deps  bison coreutils  dpkg-dev dpkg  flex  gcc  libc-dev libedit-dev libxml2-dev  libxslt-dev make openssl-dev perl-utils perl-ipc-run util-linux-dev zlib-dev icu-dev \
          && cd /usr/src/postgresql \
          && awk '$1 == "#define" \
          && $2 == "DEFAULT_PGSOCKET_DIR" \
          && $3 == "\"/tmp\"" { $3 = "\"/var/run/postgresql\""; print; next } {print}' src/include/pg_config_manual.h > src/include/pg_config_manual.h.new \
          && grep '/var/run/postgresql' src/include/pg_config_manual.h.new \
          && mv src/include/pg_config_manual.h.new src/include/pg_config_manual.h \
          && gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)" \
          && wget -O config/config.guess 'https://git.savannah.gnu.org/cgit/config.git/plain/config.guess?id=7d3d27baf8107b630586c962c057e22149653deb' \
          && wget -O config/config.sub 'https://git.savannah.gnu.org/cgit/config.git/plain/config.sub?id=7d3d27baf8107b630586c962c057e22149653deb' \
          && ./configure  --build="$gnuArch"  --enable-integer-datetimes  --enable-thread-safety  --enable-tap-tests  --disable-rpath 	--with-uuid=e2fs --with-gnu-ld  --with-pgport=5432 --with-system-tzdata=/usr/share/zoneinfo --prefix=/usr/local  --with-includes=/usr/local/include --with-libraries=/usr/local/lib --with-openssl --with-libxml --with-libxslt --with-icu \
          && sed -i 's/#define CUBE_MAX_DIM (100)/#define CUBE_MAX_DIM (2048)/' /usr/src/postgresql/contrib/cube/cubedata.h \
          && make -j "$(nproc)" world \
          && make install-world \	
          && make -C contrib install \
          && runDeps="$(scanelf --needed --nobanner --format '%n#p' --recursive /usr/local | tr ',' '\n' | sort -u | awk 'system("[ -e /usr/local/lib/" $1 " ]")==0{next} { print "so:" $1 }' )" \
          && apk add --no-cache --virtual .postgresql-rundeps $runDeps bash su-exec tzdata \
          && apk del .fetch-deps .build-deps \
          && cd / \
          && rm -rf  /usr/src/postgresql  /usr/local/share/doc /usr/local/share/man && find /usr/local -name '*.a' -delete

RUN set -ex \
    && apk add --no-cache --virtual .fetch-deps \
                ca-certificates \
                git \
                openssl \
                openssl-dev \
                tar \
    && mkdir -p /build/ \
    && git clone https://github.com/timescale/timescaledb /build/timescaledb \
    \
    && apk add --no-cache --virtual .build-deps \
                coreutils \
                dpkg-dev dpkg \
                gcc \
                libc-dev \
                make \
                cmake \
                util-linux-dev \
    \
    # Build current version \
    && cd /build/timescaledb && rm -fr build \
    && git checkout ${TIMESCALEDB_VERSION} \
    && ./bootstrap -DREGRESS_CHECKS=OFF -DPROJECT_INSTALL_METHOD="docker"${OSS_ONLY} \
    && cd build && make install \
    && cd ~ \
    \
    && if [ "${OSS_ONLY}" != "" ]; then rm -f $(pg_config --pkglibdir)/timescaledb-tsl-*.so; fi \
    && apk del .fetch-deps .build-deps \
    && rm -rf /build \
    && sed -r -i "s/[#]*\s*(shared_preload_libraries)\s*=\s*'(.*)'/\1 = 'timescaledb,\2'/;s/,'/'/" /usr/local/share/postgresql/postgresql.conf.sample

