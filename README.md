# Components for Gershwin

This repository contains several components such as applications and preference panes designed for FreeBSD systems running the Gershwin desktop environment but potentially also useful elsewhere.

See the `README.md` in each respective directory for detailed information.

https://api.cirrus-ci.com/v1/artifact/github/probonopd/gershwin-components/data/packages/FreeBSD:14:amd64/index.html


## Installation

```
su

cat > /usr/local/etc/pkg/repos/Gershwin-components.conf <<\EOF
Gershwin-components: {
  url: "[https://api.cirrus-ci.com/v1/artifact/github/gershwin-desktop/gershwin-unstable-ports/data/packages/FreeBSD:14:amd64](https://api.cirrus-ci.com/v1/artifact/github/probonopd/gershwin-components/data/packages/FreeBSD:14:amd64
)",
  mirror_type: "http",
  enabled: yes
}
EOF
```
