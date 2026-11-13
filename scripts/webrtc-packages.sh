#!/usr/bin/env bash
# Shared package manifest for native APT installs and the rootless sysroot.
# APT must resolve dependencies; apt-get download alone does not do that.
WEBKIT_BUILD_TOOLS=(
  build-essential pkg-config cmake ninja-build python3 perl ruby ruby-dev
  bison flex gperf unifdef gettext libglib2.0-bin libglib2.0-dev-bin
  curl ca-certificates patch xz-utils
)
WEBKIT_DEV_PACKAGES=(
  libgtk-3-dev libsoup-3.0-dev
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
  libgstreamer-plugins-bad1.0-dev
  libgcrypt20-dev libgpg-error-dev
  libharfbuzz-dev libdrm-dev libfontconfig-dev libfreetype-dev libicu-dev
  liblcms2-dev libxslt1-dev libxml2-dev libsqlite3-dev libgudev-1.0-dev
  libjpeg-dev libopenjp2-7-dev libpng-dev libtasn1-6-dev libwebp-dev
  libxt-dev libenchant-2-dev libsecret-1-dev libepoxy-dev
  libegl-dev libgl-dev libgles-dev libgbm-dev libseccomp-dev wayland-protocols
  libssl-dev
)
WEBKIT_MEDIA_PACKAGES=(
  gstreamer1.0-plugins-bad gstreamer1.0-plugins-good gstreamer1.0-nice
  gstreamer1.0-alsa gstreamer1.0-gl gstreamer1.0-pipewire
  gstreamer1.0-pulseaudio bubblewrap xdg-dbus-proxy
)
