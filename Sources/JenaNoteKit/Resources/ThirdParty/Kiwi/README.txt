JenaNote bundles unmodified Kiwi 0.24.1 and its base CONG model.
https://github.com/bab2min/Kiwi/releases/tag/v0.24.1
Both are Apache-2.0 licensed; LICENSE and NOTICE are included here.
The earlier Kiwi releases through 0.23.2 were LGPL and are not used.

The native framework statically includes third-party code. Its upstream NOTICE
lists the components; their license texts are included alongside this file.
Eigen's MPL-2.0 source is available at the exact upstream revision:
https://gitlab.com/libeigen/eigen/-/tree/3147391d946bb4b6c68edd901f2add6ac1f31f8c
JenaNote makes no modifications to Eigen or Kiwi.

Pinned upstream submodule revisions:
cpp-btree 226ce3aed24702bef1b03dba4b3cb55bc0bf31dd
cpuinfo 05dd959fa26c7e68fa229495a35f55e06a3b9655
eigen 3147391d946bb4b6c68edd901f2add6ac1f31f8c
json 55f93686c01528224f448c19128836e7df245f72
mimalloc fbd8b99c2b828428947d70fdc046bb55609be93e
streamvbyte 862c2e7a4c39717b5a6e590c8a784bcd7924b20b

Native framework: built locally from the vendored source snapshot.
Kiwi source commit: 724d00718f527bac3f8aef2f6ae3b6523b2aae74
Build recipe: scripts/build-kiwi.sh (macOS arm64 + x86_64, mimalloc ON, cpuinfo OFF).
Source/dependency manifest: Vendor/Kiwi/upstream.json.
The cpuinfo license is retained for reference; cpuinfo is not linked in this build.
Model archive SHA-256:
50d163e1af817444ef21f7ec5ea07ef69fb347282d57a6b49260f2039d4dc346
