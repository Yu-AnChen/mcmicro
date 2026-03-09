process COMPRESS_PYSED {
    tag "${meta.id}_${meta.cycle_number}"
    label 'process_low'

    storeDir "${params.outdir}/cycle_compressed/${meta.id}"

    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/ashlar:1.18.0--pyhdfd78af_0' :
        'yuanchen12/rcashlar:latest' }"

    input:
    tuple val(meta), path(image_file)

    output:
    tuple val(meta), path("${image_file.name}"), emit: tif
    path "versions.yml"                         , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    """
    python3 << 'PYEOF'
    import os, sys, shutil, logging
    import ome_types, tifffile, tqdm, zarr
    from xsdata.formats.dataclass.parsers.config import ParserConfig

    class MessageFilter(logging.Filter):
        def __init__(self, *substrings):
            self.substrings = substrings
        def filter(self, record):
            return not any(s in record.getMessage() for s in self.substrings)

    logging.getLogger("tifffile").addFilter(
        MessageFilter("OME series contains invalid TiffData index")
    )

    pysed_path = '${image_file}'
    out_path   = '${image_file.name}'

    with tifffile.TiffFile(pysed_path) as tif:
        already_compressed = tif.pages[0].compression.value != 0

    if already_compressed:
        print(f"Already compressed, hardlinking: {pysed_path}", file=sys.stderr)
        try:
            os.link(pysed_path, out_path)
        except OSError:
            shutil.copy2(pysed_path, out_path)
    else:
        print(f"Compressing: {pysed_path}", file=sys.stderr)
        zimg = zarr.open(tifffile.imread(pysed_path, aszarr=True), mode='r')
        with tifffile.TiffWriter(out_path, bigtiff=True) as tif_w:
            for ii in tqdm.trange(len(zimg)):
                tif_w.write(zimg[ii], compression='zlib')
        parser_config = ParserConfig(
            fail_on_unknown_properties=False, fail_on_unknown_attributes=False
        )
        ome = ome_types.from_tiff(pysed_path, parser_kwargs={'config': parser_config})
        tifffile.tiffcomment(out_path, ome.to_xml().encode())
    PYEOF

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python3 --version | sed 's/Python //')
        tifffile: \$(python3 -c "import tifffile; print(tifffile.__version__)")
    END_VERSIONS
    """
}
