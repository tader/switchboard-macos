# Build an optimized, unsigned app and release archive for this Mac.
host_arch := `uname -m`

release arch=host_arch:
    bash scripts/bundle.sh {{quote(arch)}}
