# E-Voting Trusted Build Script

This repository contains the compile and hash-generation script used by the
Rechtsdienst der Staatskanzlei des Kantons Thurgau to perform the trusted
build verification of the Swiss Post e-voting system on behalf of the
cantons named in each Trusted Build Report.

## Purpose

The script:

1. Installs the required build environment (Docker, Wine)
2. Downloads a project-local JDK, Node.js, and Maven
3. Clones the e-voting source repositories published by Swiss Post at a
   specific release tag
4. Compiles all components in dependency order
5. Computes SHA-256 and SHA-384 checksums of the resulting build artefacts

The resulting hash values are published in the corresponding Trusted Build
Report (PDF, digitally signed), alongside a reference to the exact version
of this script used to produce them.

## Usage

```bash
chmod +x evoting_<version>_compile.sh
./evoting_<version>_compile.sh
```

The script presents an interactive menu to run individual steps or all
steps in sequence. See the comment header inside the script for details.

## Versions

Each release of this script is tagged to match the e-voting release it was
used to verify (e.g. tag `1.5.4.2` corresponds to e-voting release
1.5.4.2). The script version used for a given Trusted Build Report can be
found in section 4 ("Skript") of that report.
