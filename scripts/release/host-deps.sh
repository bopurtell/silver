# Shared host prerequisites for the Ubuntu release and native CI containers.
install_ubuntu_build_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    autoconf build-essential bzip2 ca-certificates curl git gzip libgmp-dev libsqlite3-dev \
    opam pkg-config python3 rsync unzip xz-utils zlib1g-dev
}
