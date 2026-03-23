process WORKDIR_CLEANUP {
    tag "$meta.id"
    executor 'local'

    input:
    tuple val(meta), path(files), val(outdir)

    script:
    """
    work_root=\$(dirname \$(dirname \$PWD))
    for f in \$(find . -maxdepth 1 -type l); do
        real=\$(readlink -f "\$f")
        if [[ "\$real" != "\$work_root"/* ]]; then
            continue
        fi

        fname=\$(basename "\$real")
        src_size=\$(stat -c%s "\$real")
        waited=0

        while true; do
            pub=\$(find "${outdir}" -name "\$fname" 2>/dev/null | head -1)
            if [ -n "\$pub" ] && [ "\$(stat -c%s "\$pub" 2>/dev/null)" = "\$src_size" ]; then
                rm -f "\$real"
                break
            fi
            if [ \$waited -ge 7200 ]; then
                echo "[cleanup] Timed out waiting for \$fname in ${outdir}" >&2
                break
            fi
            sleep 10
            waited=\$((\$waited + 10))
        done
    done
    """
}
