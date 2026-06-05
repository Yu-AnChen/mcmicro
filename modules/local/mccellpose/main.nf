process MCCELLPOSE {
    tag "$meta.id"
    label 'process_single'
    label 'process_gpu'

    container "docker.io/labsyspharm/mccellpose:1.0.3"

    input:
    tuple val(meta), path(image)

    output:
    tuple val(meta), path("*_mask.ome.tif"), emit: mask
    path "versions.yml"                    , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    def gpu_args = task.ext.use_gpu ? "--use-gpu --jobs ${task.cpus}" : ''
    """
    export HOME=\$PWD
    export NUMBA_CACHE_DIR=\$PWD

    python3 -c "import urllib.request; urllib.request.urlretrieve('https://gist.githubusercontent.com/Yu-AnChen/6b93cde76ac7c4e73f49b037891197db/raw/4bf879f2525d65e991dd0f3ff04908548eaaa67c/cli.py', 'cli.py')"

    python3 cli.py \
        --input $image \
        --output-cell ${prefix}_mask.ome.tif \
        --channel 1 \
        --expand-size 2 \
        $gpu_args \
        $args

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mccellpose: \$(mccellpose --version | awk '{print \$2}')
        cellpose: \$(cellpose --version | awk 'NR==2 {print \$3}')
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}_mask.ome.tif

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mccellpose: \$(mccellpose --version | awk '{print \$2}')
        cellpose: \$(cellpose --version | awk 'NR==2 {print \$3}')
    END_VERSIONS
    """
}
