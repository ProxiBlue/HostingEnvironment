# PHP patch-release overlay on top of the Jelastic certified nginxphp image.
#
# Jelastic publishes new PHP patch images weeks after php.net. This image takes
# the newest certified image for the minor line and replaces PHP itself with a
# from-source build of the requested patch release, using the same layout,
# configure options and static/shared split as Jelastic's own build.
#
# Bundled extensions are rebuilt. Third-party PECL extensions (redis, imagick,
# apcu, ...) are carried over from the base image: PHP keeps the extension ABI
# (PHP_API / ZEND_EXTENSION_API_NO) fixed for every patch release of a minor line.
#
# Build args:
#   BASE_TAG     jelastic/nginxphp tag to start from (same PHP minor line)
#   PHP_VERSION  php.net release to build
#   PHP_SHA256   sha256 of php-${PHP_VERSION}.tar.xz from php.net/releases

ARG BASE_TAG=1.30.5-php-8.4.26-almalinux-9

FROM jelastic/nginxphp:${BASE_TAG} AS build

ARG PHP_VERSION=8.4.27
ARG PHP_SHA256=

# Builder links against the libraries already in the runtime image; the
# version-locked -devel packages below refuse to upgrade them.
RUN dnf -y install --setopt=install_weak_deps=0 --enablerepo=crb,epel,pgdg14 dnf-plugins-core \
    && dnf -y install --setopt=install_weak_deps=0 --enablerepo=crb,epel,pgdg14 \
        bzip2-devel enchant-devel freetds-devel freetype-devel gettext-devel gmp-devel \
        libargon2-devel libcurl-devel libedit-devel libffi-devel libicu-devel-$(rpm -q --qf '%{VERSION}-%{RELEASE}' libicu) \
        libfbclient2-devel libjpeg-turbo-devel libpng-devel libsodium-devel libtidy-devel \
        libwebp-devel libXpm-devel libxml2-devel libxslt-devel libzip-devel net-snmp-devel \
        oniguruma-devel openldap-devel openssl-devel postgresql14-devel sqlite-devel \
        unixODBC-devel pkgconf-pkg-config gcc gcc-c++ make bison re2c xz \
    && dnf clean all

WORKDIR /usr/src
RUN curl -fsSL -o php.tar.xz "https://www.php.net/distributions/php-${PHP_VERSION}.tar.xz" \
    && if [ -n "${PHP_SHA256}" ]; then echo "${PHP_SHA256}  php.tar.xz" | sha256sum -c -; \
       else echo "PHP_SHA256 build arg is required" >&2; exit 1; fi \
    && tar xJf php.tar.xz && rm php.tar.xz

WORKDIR /usr/src/php-${PHP_VERSION}
RUN ./configure \
        --build=x86_64-redhat-linux-gnu --host=x86_64-redhat-linux-gnu \
        --prefix=/usr --exec-prefix=/usr --bindir=/usr/bin --sbindir=/usr/sbin \
        --libdir=/usr/lib64 --with-libdir=lib64 --with-layout=GNU \
        --with-config-file-path=/etc --with-config-file-scan-dir=/etc/php.d \
        --disable-debug --disable-rpath --with-pic --enable-zts \
        --enable-fpm --enable-cgi --enable-phpdbg \
        --without-pear \
        --enable-ctype --enable-filter --enable-session --enable-sockets --with-libxml --enable-xml \
        --with-password-argon2 --with-mhash \
        --enable-bcmath=shared --with-bz2=shared --enable-calendar=shared \
        --with-curl=shared --enable-dba=shared --enable-dl-test=shared --enable-dom=shared \
        --with-enchant=shared --enable-exif=shared --with-ffi=shared --enable-fileinfo=shared \
        --enable-ftp=shared --enable-gd=shared --with-freetype --with-jpeg --with-webp --with-xpm \
        --with-gettext=shared --with-gmp=shared --with-iconv=shared --enable-intl=shared \
        --with-ldap=shared --enable-mbstring=shared --enable-mysqlnd=shared --with-mysqli=shared \
        --with-unixODBC=shared,/usr --enable-opcache=shared --with-openssl=shared \
        --enable-pcntl=shared --enable-pdo=shared --with-pdo-dblib=shared \
        --with-pdo-firebird=shared --with-pdo-mysql=shared,mysqlnd \
        --with-pdo-pgsql=shared,/usr/pgsql-14 --with-pdo-sqlite=shared \
        --with-pgsql=shared,/usr/pgsql-14 --enable-phar=shared --enable-posix=shared \
        --with-libedit=shared --enable-shmop=shared --enable-simplexml=shared \
        --with-snmp=shared --enable-soap=shared --with-sodium=shared --with-sqlite3=shared \
        --enable-sysvmsg=shared --enable-sysvsem=shared --enable-sysvshm=shared \
        --with-tidy=shared --enable-tokenizer=shared --enable-xmlreader=shared \
        --enable-xmlwriter=shared --with-xsl=shared --with-zip=shared --with-zlib=shared \
        EXTENSION_DIR=/usr/lib64/php/modules \
    && make -j"$(nproc)" \
    && make install INSTALL_ROOT=/root/php/php${PHP_VERSION}


FROM jelastic/nginxphp:${BASE_TAG}

ARG PHP_VERSION=8.4.27

COPY --from=build /root/php/php${PHP_VERSION}/usr /tmp/php-new
COPY rebase-php.sh /usr/local/sbin/rebase-php.sh

RUN /usr/local/sbin/rebase-php.sh "${PHP_VERSION}" /tmp/php-new \
    && rm -rf /tmp/php-new /usr/local/sbin/rebase-php.sh

ENV PHP_VERSION=${PHP_VERSION}
LABEL engineVersion=${PHP_VERSION} \
      org.opencontainers.image.source=https://github.com/ProxiBlue/HostingEnvironment
