process WORKDIR_CLEANUP {
    tag "$meta.id"
    executor 'local'

    input:
    tuple val(meta), path(files)

    script:
    """
    work_root=\$(dirname \$(dirname \$PWD))
    for f in \$(find . -maxdepth 1 -type l); do
        real=\$(readlink -f "\$f")
        if [[ "\$real" == "\$work_root"/* ]]; then
            rm -f "\$real"
        fi
    done
    """
}
