process WORKDIR_CLEANUP {
    tag "$meta.id"
    executor 'local'

    input:
    tuple val(meta), path(files), val(outdir)

    output:
    val(meta), emit: done

    script:
    """
    current_tmp=
    trap '[ -n "\$current_tmp" ] && rm -f "\$current_tmp" 2>/dev/null; exit 1' TERM

    work_root=\$(dirname \$(dirname \$PWD))
    for f in \$(find . -maxdepth 1 -type l); do
        real=\$(readlink -f "\$f")
        if [[ "\$real" != "\$work_root"/* ]]; then
            continue
        fi

        fname=\$(basename "\$real")
        src_size=\$(stat -c%s "\$real")

        while true; do
            pub=\$(find "${outdir}" -name "\$fname" 2>/dev/null | head -1)
            if [ -n "\$pub" ] && [ "\$(stat -c%s "\$pub" 2>/dev/null)" = "\$src_size" ]; then
                current_tmp="\${real}.tmp"
                ln -s "\$pub" "\$current_tmp"
                mv "\$current_tmp" "\$real"
                current_tmp=
                break
            fi
            sleep 10 &
            wait \$!
        done
    done
    """
}
